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
- Hugging Face token with access to `meta-llama/Llama-3.1-8B-Instruct`

---

## Phase 1: Deploy Infrastructure

```bash
cd EKS/terraform
terraform init
terraform apply
```

This provisions the VPC, EKS cluster, EFS, Karpenter IAM roles, and the `eks-pod-identity-agent` addon
(required for Karpenter's Pod Identity auth).

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
    --set "nfd.worker.nodeSelector.karpenter\.sh/nodepool=gpu-inference"
```

### 2.5 Install Karpenter

Karpenter uses EKS Pod Identity (configured by terraform), so no IRSA role annotation is needed.
The single system node requires `replicas=1` to avoid pod anti-affinity conflicts.

```bash
helm registry logout public.ecr.aws

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
    --version 1.0.0 \
    --namespace kube-system \
    --set replicas=1 \
    --set settings.clusterName=$CLUSTER_NAME \
    --set settings.interruptionQueueName="Karpenter-$CLUSTER_NAME"
```

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

> **Note:** Karpenter v1.0.0 supports `AL2`, `AL2023`, `Bottlerocket`, `Custom`, `Windows2019`, `Windows2022`. It does **not** support `Ubuntu`. All node classes in this project use `AL2023`.

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

# Wait for download to complete (may take 10-15 min depending on network)
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
kubectl scale deployment vllm-baseline --replicas=0

# Wait for Karpenter to drain and terminate both nodes
kubectl get nodes -l karpenter.sh/nodepool=gpu-inference -w
# Wait until both Karpenter nodes are gone

kubectl delete -f k8s/deployments/vllm-baseline.yaml
kubectl delete -f k8s/karpenter/gpu-nodepool.yaml
kubectl delete -f k8s/karpenter/baseline-nodeclass.yaml
```

---

## Phase 5: Experiment 2 -- Optimized

### 5.1 Install Spegel (P2P image distribution)

```bash
helm repo add spegel https://spegel-org.github.io/helm-charts
helm repo update

helm upgrade --install spegel spegel/spegel \
    --namespace spegel --create-namespace \
    --set "tolerations[0].key=nvidia.com/gpu" \
    --set "tolerations[0].operator=Exists" \
    --set "tolerations[0].effect=NoSchedule"
```

### 5.2 Apply Karpenter resources (with containerd overrides for Spegel)

```bash
kubectl apply -f k8s/karpenter/optimized-nodeclass.yaml
kubectl apply -f k8s/karpenter/gpu-nodepool.yaml
```

### 5.3 Deploy optimized vLLM (replicas: 1)

```bash
kubectl apply -f k8s/deployments/vllm-optimized.yaml
```

### 5.4 Wait for Node 1 + Pod 1 to be ready

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

### 5.5 Scale to 2 replicas (this is the measured event)

```bash
kubectl scale deployment vllm-optimized --replicas=2
```

### 5.6 Identify Pod 2

```bash
kubectl get pods -l app=vllm-optimized --sort-by=.metadata.creationTimestamp
export POD2=$(kubectl get pods -l app=vllm-optimized --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
echo "Pod 2: $POD2"
```

### 5.7 Collect timing data for Pod 2

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

**Expected improvements:**
- Image pull: Fast via Spegel P2P from Node 1
- Init container: EFS to emptyDir copy
- Model load: From emptyDir with fastsafetensors (GPU Direct Storage)
- Graph compile: Near-zero (cache hit from EFS)

### 5.8 Cleanup optimized

```bash
kubectl scale deployment vllm-optimized --replicas=0

# Wait for Karpenter to drain nodes
kubectl get nodes -l karpenter.sh/nodepool=gpu-inference -w

kubectl delete -f k8s/deployments/vllm-optimized.yaml
kubectl delete -f k8s/karpenter/gpu-nodepool.yaml
kubectl delete -f k8s/karpenter/optimized-nodeclass.yaml
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
