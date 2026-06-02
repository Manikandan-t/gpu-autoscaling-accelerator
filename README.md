# GPU Autoscaling Accelerator

Reproducible framework for measuring and reducing GPU cold-start latency for LLM inference on Kubernetes. Implements a baseline vs optimized benchmarking pattern on EKS to isolate the impact of each optimization: P2P image distribution (Spegel), local storage caching, fastsafetensors (GPUDirect Storage), and persistent torch.compile caching.

## Problem

Scaling a vLLM inference pod from N to N+1 on GPU infrastructure hits a sequential bottleneck chain:

```
Node Provision → Image Pull → Model Weight Load → CUDA Compilation → Ready
  (90-120s)      (3-5 min)      (2-5 min)          (2-5 min)
```

Unoptimized total: **10-15 minutes**. This repo provides the infrastructure and manifests to benchmark each phase independently and apply targeted optimizations.

## What's Implemented

**Baseline experiment** — measures cold-start with no optimizations:
- Direct DockerHub image pull (no P2P)
- Model loaded directly from EFS (slow network filesystem)
- No compile cache persistence (each pod compiles CUDA graphs from scratch)

**Optimized experiment** — applies all optimizations:
- **Spegel P2P** (v0.7.1, tuned timeouts) image distribution from existing cluster nodes
- **containerd 2.1 overrides** (`use_local_image_pull=true`, `discard_unpacked_layers=false`) to make Spegel work on AL2023
- **NVMe instance store** via Karpenter `instanceStorePolicy: RAID0` — emptyDir volumes are automatically NVMe-backed (mounted at `/mnt/k8s-disks/0`); no manual userData formatting needed
- **fastsafetensors** — fast model weight loading via POSIX I/O on NVMe. GDS driver installed best-effort but provides minimal benefit on local NVMe/ext4 (designed for distributed FS)
- **Persistent torch.compile cache** on shared EFS (`VLLM_CACHE_ROOT`) — first pod compiles, subsequent pods skip

Both experiments use the same two-node scale-up pattern: Node 1 runs, scale to 2 replicas, measure Node 2's full cold-start.

## Repository Structure

```
EKS/
├── terraform/
│   ├── main.tf                  # VPC, EKS cluster, managed node group
│   ├── karpenter.tf             # Karpenter IAM (Pod Identity)
│   ├── efs.tf                   # EFS security group
│   └── outputs.tf               # cluster_name, efs_file_system_id
├── k8s/
│   ├── karpenter/
│   │   ├── gpu-nodepool.yaml          # NodePool: g6 (L4), on-demand, GPU taint
│   │   ├── baseline-nodeclass.yaml    # EC2NodeClass: AL2023, no containerd overrides
│   │   └── optimized-nodeclass.yaml   # EC2NodeClass: AL2023 + containerd overrides for Spegel
│   ├── deployments/
│   │   ├── vllm-baseline.yaml         # vLLM direct from EFS, no optimizations
│   │   └── vllm-optimized.yaml        # vLLM with initContainer, fastsafetensors, compile cache
│   ├── storage/
│   │   └── efs-storage.yaml           # StorageClass + PVC (ReadWriteMany)
│   └── jobs/
│       └── model-download-job.yaml    # Downloads Qwen2.5-7B-Instruct to EFS
└── DEPLOYMENT_GUIDE.md          # Step-by-step instructions for running both experiments
```

## Prerequisites

- Terraform >= 1.5.0
- AWS CLI (configured)
- kubectl, helm, eksctl
- AWS account with EKS, EC2, EFS, IAM permissions
- Hugging Face token

## Quick Start

```bash
# 1. Provision infrastructure
cd EKS/terraform
terraform init && terraform apply
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export EFS_ID=$(terraform output -raw efs_file_system_id)

# 2. Bootstrap cluster (kubeconfig, EFS CSI, NVIDIA plugin, Karpenter)
aws eks update-kubeconfig --region us-east-1 --name $CLUSTER_NAME
# See DEPLOYMENT_GUIDE.md Phase 2 for full bootstrap commands

# 3. Setup storage and download model
cd ../k8s
sed "s/<EFS_FILE_SYSTEM_ID>/$EFS_ID/g" storage/efs-storage.yaml | kubectl apply -f -
kubectl create secret generic hf-token --from-literal=token=<YOUR_HF_TOKEN>
kubectl apply -f jobs/model-download-job.yaml

# 4. Run baseline experiment
kubectl apply -f karpenter/baseline-nodeclass.yaml -f karpenter/gpu-nodepool.yaml
kubectl apply -f deployments/vllm-baseline.yaml
# Wait for Pod 1, then: kubectl scale deployment vllm-baseline --replicas=2
# Measure Pod 2 timing via events + logs

# 5. Run optimized experiment (after baseline cleanup)
kubectl apply -f karpenter/optimized-nodeclass.yaml -f karpenter/gpu-nodepool.yaml
kubectl apply -f deployments/vllm-optimized.yaml
# Wait for Pod 1, then: kubectl scale deployment vllm-optimized --replicas=2
# Measure Pod 2 timing via events + logs
```

See [`EKS/DEPLOYMENT_GUIDE.md`](EKS/DEPLOYMENT_GUIDE.md) for complete step-by-step instructions including Spegel installation, security group fixes, timing extraction commands, and troubleshooting.

## Key Findings

| Phase | Baseline | Optimized | Technique |
|-------|----------|-----------|-----------|
| Image Pull | 3-5 min | 30-60s | Spegel P2P (requires containerd 2.1 overrides) |
| Model Load | 2-5 min (EFS direct) | ~60-90s (copy) + fast read | NVMe emptyDir (instanceStorePolicy) + fastsafetensors |
| CUDA Compilation | 20-30s (7B) | ~8s | Shared compile cache on EFS (`VLLM_CACHE_ROOT`) |
| Node Provisioning | 90-120s | 90-120s | Hardware bound (not optimizable) |

## Critical Issues Documented

- **containerd 2.1 silently breaks Spegel** — `use_local_image_pull=false` (default) bypasses all registry mirrors; `discard_unpacked_layers=true` (default) prevents P2P layer serving. Both must be overridden in EC2NodeClass userData.
- **Cross-SG networking** — Karpenter nodes use the cluster SG, managed nodes use a separate SG. Without bidirectional rules, Spegel DNS resolution fails.
- **GDS on local NVMe is a no-op** — NVIDIA GPUDirect Storage is designed for distributed filesystems (Lustre, WekaFS). On local NVMe with ext4, `nvidia_fs.ko` runs in compatibility mode or doesn't engage. fastsafetensors falls back to POSIX I/O (`nogds=True`), which is still fast on NVMe. The real performance gain is NVMe vs EFS, not GDS.
- **Spegel default `mirrorResolveTimeout` of 20ms is too aggressive** — Kademlia DHT lookups exceeding 20ms fall back to upstream. Tuning to 5s with 5 retries significantly improves cache hit rates.
- **Compile cache is GPU-specific** — A100 (compute 8.0) and L4 (compute 8.9) produce different cache hashes. NodePool must restrict to a single GPU family.

## Hardware

The EKS implementation uses:
- **GPU instances:** g6 family (NVIDIA L4, 24GB VRAM) via Karpenter
- **System nodes:** m5.large (managed node group)
- **Model:** Qwen2.5-7B-Instruct
- **Storage:** EFS (ReadWriteMany) for shared model cache and compile cache; NVMe instance store (Karpenter `instanceStorePolicy: RAID0`) for fast local model reads via emptyDir

## Teardown

```bash
# Delete K8s resources
kubectl delete job model-download
kubectl delete pvc model-cache-pvc
kubectl delete sc efs-sc

# Uninstall Helm releases
helm uninstall spegel -n spegel
helm uninstall nvdp -n nvidia-device-plugin
helm uninstall karpenter -n kube-system
helm uninstall aws-efs-csi-driver -n kube-system

# Destroy infrastructure
cd EKS/terraform && terraform destroy
```