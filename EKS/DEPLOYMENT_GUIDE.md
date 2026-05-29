# GPU Cold-Start Latency Benchmark: Deployment Guide

Benchmark GPU cold-start latency for vLLM on EKS using a two-node scale-up pattern.
Node 1 is already running. We measure Node 2's full cold-start time across Baseline vs Optimized configurations.

```
Baseline:
  Node 1 (running) <- vLLM, direct EFS, no compile cache persistence
  Scale to 2 replicas -> Karpenter provisions Node 2
  Measure Node 2: node provision -> image pull (DockerHub) -> model load (EFS) -> compile -> ready

Optimized:
  Node 1 (running) <- vLLM + Spegel seed + compile cache written to EFS
  Scale to 2 replicas -> Karpenter provisions Node 2
  Measure Node 2: node provision -> image pull (Spegel P2P) -> initContainer (EFS->emptyDir)
                   -> model load (emptyDir + fastsafetensors) -> compile cache HIT -> ready
```

---

## Prerequisites

**Tools required:**
- `terraform` >= 1.5.0
- `aws` CLI (configured with credentials)
- `kubectl`
- `helm`
- `eksctl`

**Access required:**
- AWS account with permissions for EKS, EC2, EFS, IAM
- Hugging Face token (for model download)

---

## Phase 1: Deploy Infrastructure

```bash
cd EKS/terraform
terraform init
terraform apply
```

This provisions the VPC (4 AZs: us-east-1a/b/c/d), EKS cluster, EFS, Karpenter IAM roles, and the
`eks-pod-identity-agent` addon (required for Karpenter's Pod Identity auth).

> **Note:** The EKS control plane is pinned to the original 2 AZs (us-east-1b/d). The additional
> AZs (us-east-1a/c) are for Karpenter worker nodes only, providing broader GPU capacity availability.

Note the outputs:
```bash
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export EFS_ID=$(terraform output -raw efs_file_system_id)
```

---

## Phase 2: Bootstrap Cluster

### 2.1 Update kubeconfig

```bash
aws eks update-kubeconfig --region us-east-1 --name $CLUSTER_NAME
```

### 2.2 Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### 2.3 Install EFS CSI driver

Associate the IAM OIDC provider (required for IRSA):
```bash
eksctl utils associate-iam-oidc-provider \
    --cluster $CLUSTER_NAME \
    --approve \
    --region us-east-1
```

Create the IAM service account. If redeploying, delete any stale CloudFormation stack first:
```bash
# Check for stale stack from a previous run (skip if first deploy)
STACK_NAME="eksctl-${CLUSTER_NAME}-addon-iamserviceaccount-kube-system-efs-csi-controller-sa"
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region us-east-1 >/dev/null 2>&1; then
  echo "Deleting stale CloudFormation stack..."
  aws cloudformation update-termination-protection \
      --no-enable-termination-protection \
      --stack-name "$STACK_NAME" --region us-east-1
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region us-east-1
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region us-east-1
fi

eksctl create iamserviceaccount \
    --name efs-csi-controller-sa \
    --namespace kube-system \
    --cluster $CLUSTER_NAME \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
    --approve \
    --override-existing-serviceaccounts \
    --region us-east-1
```

Verify the service account was created with an IRSA annotation:
```bash
kubectl get sa efs-csi-controller-sa -n kube-system
# Should exist and show eks.amazonaws.com/role-arn annotation
```

Install the driver:
```bash
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update

helm upgrade -i aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=efs-csi-controller-sa
```

Verify the controller is running (must show 2 pods with 3/3 READY):
```bash
kubectl get pods -n kube-system -l app=efs-csi-controller
```

### 2.4 Install NVIDIA device plugin

The `nodeSelector` restricts DaemonSet pods to Karpenter GPU nodes only, avoiding
Error crashes on the system node (which uses a standard AMI without NVIDIA drivers).

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm upgrade -i nvdp nvdp/nvidia-device-plugin \
    --namespace nvidia-device-plugin \
    --create-namespace \
    --set gfd.enabled=true \
    --set "tolerations[0].key=nvidia.com/gpu" \
    --set "tolerations[0].operator=Exists" \
    --set "tolerations[0].effect=NoSchedule" \
    --set "nodeSelector.karpenter\.sh/nodepool=gpu-inference" \
    --set "gfd.nodeSelector.karpenter\.sh/nodepool=gpu-inference" \
    --set "nfd.worker.nodeSelector.karpenter\.sh/nodepool=gpu-inference" \
    --set "nfd.worker.tolerations[0].key=nvidia.com/gpu" \
    --set "nfd.worker.tolerations[0].operator=Exists" \
    --set "nfd.worker.tolerations[0].effect=NoSchedule"
```

> **Note:** NFD worker tolerations must use `operator: Exists` (not a specific value) because
> the node taint is `nvidia.com/gpu=true:NoSchedule`.

### 2.5 Install Karpenter

Karpenter uses EKS Pod Identity (configured by terraform), so no IRSA role annotation is needed.
The single system node requires `replicas=1` to avoid pod anti-affinity conflicts.

```bash
helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --version 1.12.1 \
    --namespace kube-system \
    --set replicas=1 \
    --set "settings.clusterName=$CLUSTER_NAME" \
    --set "settings.interruptionQueueName=Karpenter-$CLUSTER_NAME"
```

> **Important:** Karpenter v1.12.1 requires additional IAM permissions beyond what the terraform
> module provisions for v1.0.0. After install, add `ec2:DescribeInstanceStatus` and
> `iam:ListInstanceProfiles` to the Karpenter controller IAM policy if you see errors in
> `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter`.

### 2.6 Verify all components

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get pods -n kube-system -l app=efs-csi-controller
kubectl get pods -n nvidia-device-plugin
```

Expected state:
- **Karpenter**: 1/1 Running
- **EFS CSI controller**: 2 pods, 3/3 Running each
- **NVIDIA device plugin**: Only NFD master and GC pods running. The device plugin, GPU feature discovery, and NFD worker DaemonSets have zero pods (no Karpenter GPU nodes exist yet). They will auto-schedule when Karpenter provisions nodes with label `karpenter.sh/nodepool=gpu-inference`.

> **Note:** EC2NodeClass uses `amiSelectorTerms: - alias: al2023@latest` which lets Karpenter
> auto-resolve the correct NVIDIA GPU AMI for GPU instance types. Do **not** use explicit AMI
> name filters like `amazon-eks-node-al2023-x86_64-nvidia-*` as this prevents Karpenter from
> matching AMIs to instance types correctly.

---

## Phase 3: Storage & Model

### 3.1 Substitute EFS ID and apply storage

```bash
sed "s/<EFS_FILE_SYSTEM_ID>/$EFS_ID/g" k8s/storage/efs-storage.yaml | kubectl apply -f -
```

### 3.2 Create HF token secret

```bash
kubectl create secret generic hf-token --from-literal=token=<YOUR_HF_TOKEN>
```

### 3.3 Run model download job

```bash
kubectl apply -f k8s/jobs/model-download-job.yaml

# Wait for download to complete (may take 5-10 min depending on network)
kubectl wait --for=condition=complete job/model-download --timeout=1200s

# Verify download
kubectl logs job/model-download
```

---

## Phase 4: Experiment 1 -- Baseline

### 4.1 Apply Karpenter resources

```bash
kubectl apply -f k8s/karpenter/baseline-nodeclass.yaml
kubectl apply -f k8s/karpenter/gpu-nodepool.yaml
```

### 4.2 Deploy baseline vLLM (replicas: 1)

```bash
kubectl apply -f k8s/deployments/vllm-baseline.yaml
```

### 4.3 Wait for Node 1 + Pod 1 to be ready

This is setup, not measured. Wait until Pod 1 passes its readiness probe.

```bash
kubectl get pods -l app=vllm-baseline -w
# Wait until STATUS shows Running and READY shows 1/1
```

### 4.4 Scale to 2 replicas (this is the measured event)

```bash
kubectl scale deployment vllm-baseline --replicas=2
```

### 4.5 Identify Pod 2

```bash
# Pod 2 is the newer pod (lower AGE)
kubectl get pods -l app=vllm-baseline --sort-by=.metadata.creationTimestamp
export POD2=$(kubectl get pods -l app=vllm-baseline --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "Pod 2: $POD2"
```

### 4.6 Collect timing data for Pod 2

**Kubernetes events (node provision, image pull, scheduling):**
```bash
kubectl get events \
    --field-selector involvedObject.name=$POD2 \
    --sort-by='.metadata.creationTimestamp' \
    -o custom-columns=TIME:.metadata.creationTimestamp,REASON:.reason,MESSAGE:.message
```

**Application logs (model load, graph compile):**
```bash
kubectl logs $POD2 -c vllm --timestamps
```

**Timing extraction:**

| Phase | Start Indicator | End Indicator |
|-------|----------------|---------------|
| Node Provision | Event: `FailedScheduling` | Event: `Scheduled` |
| Image Pull | Event: `Pulling` | Event: `Pulled` |
| Model Load | Log: `Loading model weights` | Log: `Model weights loaded` |
| Graph Compile | Log: `Compiling graph` | Log: `Uvicorn running on` |

### 4.7 Cleanup baseline

```bash
kubectl delete -f k8s/deployments/vllm-baseline.yaml
kubectl delete -f k8s/karpenter/gpu-nodepool.yaml
kubectl delete -f k8s/karpenter/baseline-nodeclass.yaml

# Wait for Karpenter to terminate nodes (watch until all gpu-inference nodes are gone)
watch kubectl get nodes

# If any nodes remain in NotReady state after NodePool/EC2NodeClass deletion,
# Karpenter can no longer manage them. Delete stale node objects manually:
kubectl get nodes | grep NotReady | awk '{print $1}' | xargs -r kubectl delete node
```

---

## Phase 5: Experiment 2 -- Optimized

### 5.1 Fix cross-node networking (security groups)

Karpenter-provisioned nodes use the EKS cluster security group, while managed nodes (running
CoreDNS, etc.) use a separate node group security group. Without cross-SG rules, pods on
Karpenter nodes cannot reach CoreDNS or communicate with pods on managed nodes. This breaks
Spegel P2P bootstrap (DNS timeout) and any cross-node pod networking.

**Identify the security groups:**
```bash
# EKS cluster security group (used by Karpenter nodes)
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region us-east-1 \
    --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Managed node group security group
MANAGED_SG=$(aws ec2 describe-instances --region us-east-1 \
    --filters "Name=tag:eks:nodegroup-name,Values=*" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].SecurityGroups[?!contains(GroupId, `'$CLUSTER_SG'`)].GroupId' \
    --output text)

echo "Cluster SG (Karpenter nodes): $CLUSTER_SG"
echo "Managed node group SG: $MANAGED_SG"
```

**Add bidirectional rules:**
```bash
# Allow Karpenter nodes -> managed nodes
aws ec2 authorize-security-group-ingress --region us-east-1 \
    --group-id $MANAGED_SG \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$CLUSTER_SG,Description=Allow all traffic from Karpenter nodes (cluster SG)}]"

# Allow managed nodes -> Karpenter nodes
aws ec2 authorize-security-group-ingress --region us-east-1 \
    --group-id $CLUSTER_SG \
    --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$MANAGED_SG,Description=Allow all traffic from managed node group SG}]"
```

> **Why is this needed?** EKS assigns the cluster security group to Karpenter nodes and a
> separate security group to managed nodes. Without cross-SG rules, DNS resolution fails from
> Karpenter nodes (CoreDNS runs on managed nodes), which prevents Spegel from bootstrapping
> its P2P overlay network.

### 5.2 Install Spegel (P2P image distribution)

Spegel uses an OCI-based Helm chart (not a traditional Helm repo):

```bash
helm upgrade --install spegel \
    --create-namespace \
    --namespace spegel \
    oci://ghcr.io/spegel-org/helm-charts/spegel \
    --set "tolerations[0].key=nvidia.com/gpu" \
    --set "tolerations[0].operator=Exists" \
    --set "tolerations[0].effect=NoSchedule"
```

### 5.3 Verify Spegel installation

**Check DaemonSet is running:**
```bash
kubectl get ds -n spegel
kubectl get pods -n spegel -o wide
# Should show one pod per node, all Running 1/1
```

**Verify mirror config written to nodes** (after a Karpenter node is provisioned):
```bash
# Spegel writes its mirror config to _default/hosts.toml (the global fallback)
kubectl debug node/<NODE_NAME> -it --image=busybox -- \
    cat /host/etc/containerd/certs.d/_default/hosts.toml
```

Expected output should include:
```toml
[host."http://127.0.0.1:5000"]
  capabilities = ["pull", "resolve"]
```

> **Important:** Do NOT create a `docker.io/hosts.toml` in EC2NodeClass userData. Registry-specific
> configs (`docker.io/hosts.toml`) take priority over the global fallback (`_default/hosts.toml`).
> If you create a `docker.io/hosts.toml` pointing to the upstream registry, it overrides Spegel's
> mirror and all pulls go directly to DockerHub, defeating P2P distribution.

**Check advertised images via metrics:**
```bash
SPEGEL_POD=$(kubectl get pods -n spegel -o jsonpath='{.items[0].metadata.name}')
kubectl --namespace spegel port-forward $SPEGEL_POD 9090 &
curl -s http://localhost:9090/metrics | grep spegel_advertised_images
# Value should be > 0 (number of images this node can serve to peers)
```

**After scale-up, verify P2P cache hits:**
```bash
curl -s http://localhost:9090/metrics | grep spegel_mirror_requests_total
# Look for cache="hit" entries -- these confirm images were pulled via P2P
# cache="miss" means the pull fell back to the upstream registry
```

> **Tip:** Kill the port-forward background process when done: `kill %1`

### 5.4 Apply Karpenter resources (with containerd overrides for Spegel)

The optimized EC2NodeClass configures containerd with:
- `config_path = "/etc/containerd/certs.d"` — enables Spegel's registry mirror interception
- `discard_unpacked_layers = false` — preserves image layers so Spegel can serve them to peers

```bash
kubectl apply -f k8s/karpenter/optimized-nodeclass.yaml
kubectl apply -f k8s/karpenter/gpu-nodepool.yaml
```

### 5.5 Deploy optimized vLLM (replicas: 1)

```bash
kubectl apply -f k8s/deployments/vllm-optimized.yaml
```

### 5.6 Wait for Node 1 + Pod 1 to be ready

Pod 1 on Node 1 serves as the Spegel seed and populates the compile cache on EFS.

```bash
kubectl get pods -l app=vllm-optimized -w
# Wait until STATUS shows Running and READY shows 1/1
```

Verify compile cache was written to EFS:
```bash
kubectl exec $(kubectl get pods -l app=vllm-optimized -o jsonpath='{.items[0].metadata.name}') \
    -c vllm -- ls /shared/compile_cache
```

### 5.7 Scale to 2 replicas (this is the measured event)

```bash
kubectl scale deployment vllm-optimized --replicas=2
```

### 5.8 Identify Pod 2

```bash
kubectl get pods -l app=vllm-optimized --sort-by=.metadata.creationTimestamp
export POD2=$(kubectl get pods -l app=vllm-optimized --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "Pod 2: $POD2"
```

### 5.9 Collect timing data for Pod 2

**Kubernetes events:**
```bash
kubectl get events \
    --field-selector involvedObject.name=$POD2 \
    --sort-by='.metadata.creationTimestamp' \
    -o custom-columns=TIME:.metadata.creationTimestamp,REASON:.reason,MESSAGE:.message
```

**Application logs:**
```bash
# Init container (EFS -> emptyDir copy time)
kubectl logs $POD2 -c model-cache-sync --timestamps

# Main container (model load, compile cache hit)
kubectl logs $POD2 -c vllm --timestamps
```

**Verify Spegel P2P was used for image pull:**
```bash
# Check Spegel metrics on the Node 2 Spegel pod for cache hits
NODE2=$(kubectl get pod $POD2 -o jsonpath='{.spec.nodeName}')
SPEGEL_POD2=$(kubectl get pods -n spegel --field-selector spec.nodeName=$NODE2 -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n spegel $SPEGEL_POD2 -- wget -qO- http://localhost:9090/metrics 2>/dev/null | grep spegel_mirror_requests_total
```

**Expected improvements:**
- Image pull: Fast via Spegel P2P from Node 1
- Init container: EFS to emptyDir copy
- Model load: From emptyDir with fastsafetensors (GPU Direct Storage)
- Graph compile: Near-zero (cache hit from EFS)

### 5.10 Cleanup optimized

```bash
kubectl delete -f k8s/deployments/vllm-optimized.yaml
kubectl delete -f k8s/karpenter/gpu-nodepool.yaml
kubectl delete -f k8s/karpenter/optimized-nodeclass.yaml

# Wait for nodes to terminate, clean up stale nodes if needed
watch kubectl get nodes
kubectl get nodes | grep NotReady | awk '{print $1}' | xargs -r kubectl delete node
```

---

## Phase 6: Compare Results

Fill in the measured values:

```
Phase                  | Baseline  | Optimized | Improvement
-----------------------|-----------|-----------|------------
Node Provisioning      | XXs       | XXs       | ~same
Image Pull             | XXs       | XXs       | Spegel P2P
Model Load             | XXs       | XXs       | emptyDir + fastsafetensors
Graph Compilation      | XXs       | XXs       | EFS cache hit
Total Time-to-Ready    | XXs       | XXs       | XX% faster
```

---

## Phase 7: Teardown

### 7.1 Delete all K8s resources

```bash
kubectl delete job model-download
kubectl delete pvc model-cache-pvc
kubectl delete sc efs-sc
kubectl delete secret hf-token
```

### 7.2 Uninstall Helm releases

```bash
helm uninstall spegel -n spegel
helm uninstall nvdp -n nvidia-device-plugin
helm uninstall karpenter -n kube-system
helm uninstall aws-efs-csi-driver -n kube-system
```

### 7.3 Destroy infrastructure

```bash
cd EKS/terraform
terraform destroy
```

---

## Troubleshooting

### Karpenter "nodepool requirements filtered out all instance types"

This usually means the AMI doesn't match the instance type. Ensure EC2NodeClass uses
`amiSelectorTerms: - alias: al2023@latest` (not an explicit AMI name filter). The alias
lets Karpenter auto-resolve the correct AMI variant (NVIDIA, Neuron, or standard) per
instance type.

### Karpenter IAM errors (ListInstanceProfiles, DescribeInstanceStatus)

Karpenter v1.12.1 requires permissions not included in the terraform module's v1.0.0 policy.
Add these to the Karpenter controller IAM policy:
- `ec2:DescribeInstanceStatus` in the `AllowRegionalReadActions` statement
- `iam:ListInstanceProfiles` in the `AllowInstanceProfileReadActions` statement

### InsufficientInstanceCapacity

GPU instances can be scarce. If a specific instance type is sold out:
- Broaden `instance-size` in the NodePool to allow fallback sizes (e.g., `["xlarge", "2xlarge", "4xlarge", "8xlarge", "16xlarge"]`)
- Check capacity across AZs; the VPC has subnets in 4 AZs for broader availability
- Consider a different instance family (e.g., `g6` vs `g6e`)

> **vCPU quota:** AWS accounts have per-family on-demand vCPU limits (default 32 for G instances).
> Larger sizes (g6.8xlarge=32 vCPU, g6.16xlarge=64 vCPU) may exceed your quota. Request increases
> via the AWS Service Quotas console if needed.

> **g6.xlarge CPU constraint:** g6.xlarge has 4 vCPU total (~3910m allocatable after kubelet
> reservation). If your pod CPU request + DaemonSet overhead exceeds this, Karpenter filters it out.
> Keep pod CPU requests at 2 or below to allow g6.xlarge as a fallback.

### Compile cache not reused across different GPU architectures

The `torch.compile` cache key includes the GPU compute capability. If Node 1 and Node 2 use
different GPU types (e.g., L4 compute 8.9 vs A10G compute 8.6), the cache hash differs and
Node 2 recompiles from scratch. To ensure cache reuse:
- Restrict the NodePool to a single GPU family (e.g., `g6` only for L4)
- Add `karpenter.k8s.aws/instance-gpu-count: "1"` to avoid multi-GPU variants

AOT compilation artifacts are architecture-independent and will be shared even across GPU types.
Only the graph compilation is GPU-specific.

### fastsafetensors GDS not available

fastsafetensors uses GPU Direct Storage (GDS) to load model weights directly to GPU VRAM.
GDS requires hardware support — not all GPU types support it. If you see
`GDS not enabled, setting nogds=True` in logs, the GPU does not support GDS and
fastsafetensors falls back to regular loading. L4 (g6) may support GDS; A10G (g5) does not.

### Spegel P2P not intercepting image pulls

If image pulls take the same time as without Spegel (e.g., 4+ minutes for the 9GB vLLM image),
check that the EC2NodeClass userData does NOT create a `docker.io/hosts.toml` file. Registry-specific
containerd configs override Spegel's global `_default/hosts.toml` mirror. The userData should only
set `config_path` and `discard_unpacked_layers` — Spegel's init container handles the mirror config.

### Spegel bootstrap failure (routing table empty / DNS timeout)

If Spegel pods show `routing table is empty after bootstrapping` or DNS resolution timeouts,
the root cause is usually missing cross-SG rules between Karpenter and managed node security groups.
See Phase 5 Step 5.1 for the fix.

### Stale nodes after NodePool/EC2NodeClass deletion

When you delete Karpenter NodePool/EC2NodeClass resources, the EC2 instances are terminated
but Kubernetes node objects may remain in `NotReady` state with pending DaemonSet pods. Clean up:
```bash
kubectl get nodes | grep NotReady | awk '{print $1}' | xargs -r kubectl delete node
```

### NVIDIA device plugin errors on system node

The system managed node group uses a standard AMI without GPU drivers. Restrict NVIDIA
DaemonSets to Karpenter GPU nodes with `nodeSelector.karpenter.sh/nodepool=gpu-inference`.
