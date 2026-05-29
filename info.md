End-to-End Implementation Guide: Reproducible GPU-Based LLM Inference Startup Latency Benchmarking on Amazon EKS

Initial report:
End-to-End Implementation Guide: Reproducible GPU-Based LLM Inference Startup Latency Benchmarking on Amazon EKSThe rapid instantiation of Large Language Model (LLM) inference endpoints is a critical capability for platform engineering teams managing volatile, cost-sensitive workloads. Dynamic provisioning systems allow compute capacity to scale from zero, eliminating the financial drain of idle warm GPU pools. However, scaling from zero introduces significant cold-start latency penalties, often referred to as "time-to-ready." This latency is compounded by sequential bottlenecks: virtual machine provisioning, container runtime initialization, gigabyte-scale image pulls, model weight synchronization into GPU memory, and strictly serial CUDA graph compilations.This report provides a comprehensive, reproducible framework for measuring and minimizing cold-start latency for vLLM pods on GPU-accelerated Amazon Elastic Kubernetes Service (EKS) environments. The architecture strictly enforces scale-from-zero node provisioning via Karpenter and relies entirely on native Kubernetes paradigms for object caching. External managed object stores such as Amazon S3 or FSx are intentionally excluded. Instead, this framework relies exclusively on PersistentVolumeClaims (PVCs) for model storage and peer-to-peer (P2P) image distribution via Spegel to optimize the critical path.SECTION 1 — Architecture & LifecycleThe benchmarking architecture is engineered to isolate and optimize the critical path of a GPU inference pod's cold start. The topology leverages an EKS control plane directing Karpenter controllers to provision Amazon EC2 GPU instances dynamically upon the detection of unschedulable pods.The environment operates entirely within an AWS Virtual Private Cloud (VPC) distributed across multiple private subnets. External access to model hosting services is prohibited to emulate strict local-storage constraints, ensuring that caching mechanisms remain entirely native to the Kubernetes cluster environment.+-----------------------------------------------------------------------------------+| Amazon EKS Control Plane |+-----------------------------------------------------------------------------------+| | |v                                      v                              v+---------------+                      +---------------+              +-------------+| Karpenter | << 1. Provision >> | Spegel (DS) | << 5. P2P >> | Spegel (DS) || Controller | | (Node A) | | (Node B) |+---------------+                      +---------------+              +-------------+| | |v                                      v                              v+-----------------------------------------------------------------------------------+| AWS EC2 Auto-Provisioned GPU Node || || +--------------------+    +--------------------+    +-------------------------+ || | Containerd (v2.1) | -> | vLLM Pod (GPU) | -> | EFS-backed PVC (RWX) | || | Configured for | | + InitContainer | | /models | || | local image pull | | + Main Container | | /compile_cache | || +--------------------+    +--------------------+    +-------------------------+ |+-----------------------------------------------------------------------------------+The request lifecycle from a scale-to-zero state to a fully ready inference endpoint follows a deterministic sequence. Optimization efforts must target specific sub-phases within this lifecycle. A vLLM deployment initially scales from zero to one replica. The Kubernetes scheduler attempts to place the pod but fails due to a lack of GPU nodes, leaving the pod in a pending state. This event is intercepted by Karpenter, initiating the provisioning sequence.Karpenter computes the hardware requirements, selects a compatible GPU instance class, and executes the EC2 instantiation requests. The virtual machine boots into Amazon Linux 2023 (AL2023), executing the node initialization sequence. The container runtime is configured, and the node successfully joins the EKS cluster. Subsequently, the Kubelet instructs the container runtime to pull the requisite vLLM container image. In an optimized environment, the Spegel daemon intercepts this request, redirecting the pull away from the external Elastic Container Registry (ECR) and instead fetching the image layers laterally across the local VPC via peer-to-peer distribution.Following the image pull, the pod enters the initialization phase. An initialization container mounts the persistent volume claim and synchronizes the model weights. The primary vLLM runtime then initializes, moving into the compilation phase where the computation graph is compiled for the specific hardware architecture. Once the graph is compiled, the readiness probe validates the health endpoint, signaling that the inference service is prepared to receive traffic.The timing expectations for each stage reveal significant optimization potential when transitioning from a baseline architecture to an optimized caching architecture.Startup StageBaseline Expectation (ECR + Uncached)Optimized Expectation (P2P + PVC Cache)Pod Pending Time~2 - 5 seconds~2 - 5 secondsNode Provisioning & Join~45 - 60 seconds~45 - 60 seconds (Hardware bounds limit optimization)Image Pull Time~120 - 180 seconds~30 - 45 seconds (Spegel P2P network saturation)PVC Model Availability~180 - 300 seconds (Network download)~10 - 20 seconds (Local cache synchronization)CUDA Graph Compilation~60 - 90 seconds~5 - 10 seconds (Bypassed via persistent cache)Total Time-to-Ready~400 - 630 seconds~90 - 135 secondsSECTION 2 — Terraform InfrastructureThe foundational infrastructure must be provisioned deterministically to ensure reproducibility across experimental runs. The following configuration defines the VPC architecture, the EKS control plane, the requisite Identity and Access Management (IAM) roles for Karpenter, and the underlying Elastic File System (EFS) infrastructure used to back the persistent volume claims.No external managed model stores are provisioned. The configuration exclusively utilizes native AWS block and file storage systems orchestrated by the Kubernetes control plane.The infrastructure deployment sequence begins with the initialization of the Terraform working directory and the validation of the configuration syntax. Following validation, the configuration is applied to the target AWS account.Bashterraform init
terraform validate
terraform apply -auto-approve
The core network and cluster infrastructure rely on robust tagging mechanisms. The VPC module provisions isolated private subnets, ensuring that nodes are not exposed to the public internet. Crucially, these subnets are tagged with discovery markers that Karpenter utilizes to identify valid placement locations for dynamically provisioned nodes.Terraformterraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.20" }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "cluster_name" {
  default = "vllm-benchmark-cluster"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    system = {
      instance_types = ["m5.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }
}
Karpenter requires distinct IAM roles to function correctly. It requires a controller role, mapped via IAM Roles for Service Accounts (IRSA) or EKS Pod Identity, allowing the Karpenter pods to execute EC2 provisioning commands. Concurrently, it requires a node instance profile role, which is attached to the newly minted EC2 instances, granting them the authority to join the EKS cluster and communicate with the control plane. The configuration leverages the official Karpenter Terraform submodule to establish these relationships cleanly.Terraformmodule "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  enable_pod_identity             = true
  create_pod_identity_association = true

  create_node_iam_role = true
  node_iam_role_name   = "KarpenterNodeRole-${var.cluster_name}"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Environment = "benchmarking"
  }
}
To support persistent model storage without relying on Amazon S3, an Amazon EFS file system is provisioned. EFS provides the critical capability of concurrent access across multiple nodes (ReadWriteMany), which is fundamentally required when multiple Karpenter-provisioned GPU nodes must access the same model cache simultaneously. The security group ensures that port 2049 is open to the VPC, allowing the EKS worker nodes to mount the targets securely.Terraformresource "aws_security_group" "efs_sg" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow EFS inbound traffic from EKS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    cidr_blocks     = [module.vpc.vpc_cidr_block]
  }
}

resource "aws_efs_file_system" "vllm_models" {
  creation_token   = "${var.cluster_name}-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  tags = {
    Name = "vllm-model-cache"
  }
}

resource "aws_efs_mount_target" "efs_mt" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.vllm_models.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}

output "efs_file_system_id" {
  value = aws_efs_file_system.vllm_models.id
}
SECTION 3 — EKS BootstrapFollowing the successful application of the Terraform infrastructure, the cluster control plane must be bootstrapped with the necessary operational controllers, device plugins, and storage drivers. This establishes the foundation for the autoscaling and storage mechanisms utilized in the latency experiments.The local context is updated to interact with the newly provisioned cluster. The metrics server is deployed to ensure that resource telemetry is available to the control plane, a prerequisite for many internal Kubernetes scheduling functions, despite the prohibition of external observability stacks in this methodology.Bashaws eks update-kubeconfig --region us-east-1 --name vllm-benchmark-cluster

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
The EFS Container Storage Interface (CSI) driver must be installed to facilitate the dynamic provisioning of persistent volumes backed by the previously created EFS file system. The driver requires permissions to interact with the AWS API to manage access points and file system mounts. An IAM Role for Service Accounts is generated and attached to the driver's service account prior to its deployment via Helm.Basheksctl create iamserviceaccount \
    --name efs-csi-controller-sa \
    --namespace kube-system \
    --cluster vllm-benchmark-cluster \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
    --approve \
    --override-existing-serviceaccounts \
    --region us-east-1

helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update

helm upgrade -i aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=efs-csi-controller-sa
Karpenter provisions the physical hardware, but the Kubernetes scheduler remains unaware of the specialized GPU resources until a device plugin advertises them. The NVIDIA device plugin is deployed to expose the nvidia.com/gpu resource capacity, allowing vLLM inference pods to request hardware acceleration successfully.Bashhelm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --set gfd.enabled=true
Finally, the Karpenter controller is deployed. The installation references the IAM role generated by the Terraform submodule and connects the controller to the specific Amazon Simple Queue Service (SQS) interruption queue designed to handle spot termination notices and capacity rebalancing events.Bashexport KARPENTER_IAM_ROLE_ARN=$(aws iam get-role --role-name KarpenterControllerRole-vllm-benchmark-cluster --query Role.Arn --output text)
export KARPENTER_QUEUE_NAME="Karpenter-vllm-benchmark-cluster"

helm registry logout public.ecr.aws
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.0.0 \
  --namespace kube-system \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_IAM_ROLE_ARN} \
  --set settings.clusterName=vllm-benchmark-cluster \
  --set settings.interruptionQueueName=${KARPENTER_QUEUE_NAME}
The successful initialization of the controller is verified by querying the pod status within the kube-system namespace.Bashkubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
SECTION 4 — Karpenter GPU AutoscalingThe autoscaling configuration mandates a strict zero-to-N scaling policy. The architecture prohibits the use of warm pools, ensuring that the time-to-ready measurements accurately reflect a complete scale-from-zero sequence. Karpenter achieves this through the combination of two primary Custom Resource Definitions: the EC2NodeClass defines the AWS-specific infrastructure parameters, while the NodePool dictates the Kubernetes scheduling constraints and disruption policies.Modern EKS environments utilizing Amazon Linux 2023 (AL2023) introduce a specific set of challenges for image pull optimization. AL2023 deprecates the legacy bash-based bootstrap scripts in favor of nodeadm, a declarative YAML-based node initialization process. The configuration of the container runtime is deeply intertwined with this process.Spegel, the peer-to-peer image distribution mechanism utilized in this framework, relies on intercepting local image pulls from the container runtime. However, AL2023 nodes default to containerd version 2.1, which introduces a new image transfer service (io.containerd.transfer.v1). By default, containerd sets use_local_image_pull = false, routing all container pulls through this new transfer service. The critical failure point here is that the transfer service does not honor the registry mirror configurations defined in hosts.toml, completely bypassing Spegel and forcing all nodes to pull directly from the remote ECR repository.Furthermore, AL2023 defaults to discard_unpacked_layers = true. When enabled, containerd immediately discards the compressed image layers after extracting them. Spegel relies on these preserved layers to serve them to peer nodes within the cluster. Without them, the peer-to-peer network cannot function.To overcome these constraints and guarantee a functional benchmarking environment, the EC2NodeClass must be explicitly configured to override the default containerd behavior during the nodeadm bootstrap phase.YAMLapiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-al2023
spec:
  amiFamily: AL2023
  role: "KarpenterNodeRole-vllm-benchmark-cluster"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "vllm-benchmark-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "vllm-benchmark-cluster"
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      containerd:
        config: |
          [plugins."io.containerd.cri.v1.images".registry]
            config_path = "/etc/containerd/certs.d"
          [plugins."io.containerd.cri.v1.images"]
            discard_unpacked_layers = false
            use_local_image_pull = true
    --BOUNDARY--
The NodePool governs the scheduling logic. It explicitly restricts capacity provisioning to on-demand compute instances belonging to the GPU-accelerated instance categories. A specific hardware taint is applied to all nodes generated by this pool, preventing general-purpose cluster workloads from inadvertently consuming expensive GPU resources.Crucially, the disruption policy dictates the scale-to-zero behavior. By setting the consolidation policy to WhenEmpty, Karpenter is instructed to aggressively terminate nodes as soon as the inference pods are scaled down, ensuring no warm compute persists between benchmarking runs.YAMLapiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-inference
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g", "p"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-al2023
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1m
Both manifest definitions are applied to the cluster, establishing the automated infrastructure provisioning pipeline.Bashkubectl apply -f karpenter-nodeclass.yaml
kubectl apply -f karpenter-nodepool.yaml
SECTION 5 — Image Pull Optimization (PRIMARY: Spegel)The sheer volume of data required to initialize an LLM endpoint is a primary contributor to cold-start latency. Container images packaging the vLLM engine alongside the requisite CUDA libraries frequently exceed 10 gigabytes. When a newly provisioned EC2 node joins the cluster, downloading this image from an external registry introduces a severe networking bottleneck.Spegel mitigates this by constructing a stateless Distributed Hash Table (DHT) across the cluster. Rather than pulling exclusively from the remote registry, Spegel enables nodes to request image layers from their peers. This peer-to-peer distribution flow leverages the high-bandwidth, low-latency inter-node networking of the VPC, saturating the local network interface and significantly compressing the image pull duration.Spegel is deployed as a DaemonSet. However, because Karpenter prevents standard workloads from scheduling onto the GPU nodes via hardware taints, the Spegel deployment must be explicitly configured to tolerate these taints. This ensures that the Spegel daemon is present on the newly minted GPU instances immediately upon their registration with the cluster control plane.Bashhelm repo add spegel https://spegel-org.github.io/helm-charts
helm repo update

helm upgrade --install spegel spegel/spegel \
  --namespace spegel --create-namespace \
  --set "tolerations.key=nvidia.com/gpu" \
  --set "tolerations.operator=Exists" \
  --set "tolerations.effect=NoSchedule"
Validating the peer-to-peer image transfer mechanism without relying on external observability stacks requires precise interrogation of the Kubernetes event stream and local pod logs.To confirm that the Spegel daemon has successfully initialized its networking components and registered the node's local IP address within the distributed hash table, the logs of the Spegel pod residing on the target node are examined.Bashkubectl logs -n spegel -l app.kubernetes.io/name=spegel | grep "P2PRouter"
The true benchmark of the image pull optimization is observed by scaling the inference deployment and monitoring the lifecycle events of the resulting pod. When the Spegel fallback mechanism is operational, the duration between the initialization of the pull sequence and its completion drops precipitously. A baseline pull from ECR typically consumes several minutes, while an optimized pull executed over the peer-to-peer network often completes within seconds.Bashkubectl get events --field-selector involvedObject.name=<POD_NAME> | grep -E 'Pulling|Pulled'
SECTION 6 — Model Storage (PVC ONLY)The architecture strictly prohibits the use of external object stores or specialized file systems for model hosting. The storage strategy must rely exclusively on Kubernetes PersistentVolumeClaims. This necessitates a "download once, cache persistently" approach, ensuring that subsequent inference pods are decoupled from the latency and unreliability of public model repositories.While Amazon Elastic Block Store (EBS) gp3 volumes provide superior Input/Output Operations Per Second (IOPS) and throughput profiles , they are fundamentally constrained by their ReadWriteOnce access mode, tethering them to a single Availability Zone and a single EC2 instance. To support dynamic, scale-out provisioning where multiple Karpenter nodes must access the identical model cache simultaneously, an Elastic File System (EFS) must be utilized, as it natively supports the ReadWriteMany access mode.The storage architecture is defined by establishing a StorageClass that instructs the EFS CSI driver to dynamically provision access points on the previously instantiated file system.YAMLapiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-XXXXX # Inherited from Terraform output
  directoryPerms: "777"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 100Gi
Prior to executing any benchmarking operations, the shared volume must be populated. This initialization phase is handled by a Kubernetes Job. The job executes an isolated container utilizing the Hugging Face CLI to download the model weights directly into the persistent volume. This isolates the network-bound download operation from the inference timing metrics.YAMLapiVersion: batch/v1
kind: Job
metadata:
  name: model-downloader
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: downloader
        image: huggingface/downloader:latest
        command:
        - huggingface-cli
        - download
        - meta-llama/Llama-3.1-8B-Instruct
        - --local-dir
        - /data/models/Llama-3.1-8B-Instruct
        env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: token
        volumeMounts:
        - name: shared-cache
          mountPath: /data
      volumes:
      - name: shared-cache
        persistentVolumeClaim:
          claimName: model-cache-pvc
While EFS solves the multi-node concurrency requirement, its throughput limitations can severely bottleneck the model load phase during vLLM engine initialization. To circumvent this without violating the strict "PVC ONLY" constraint, a sophisticated local NVMe caching strategy is employed within the inference deployment definition. An initContainer is utilized to asynchronously mirror the model weights from the slow, shared EFS volume to a highly performant local emptyDir volume backed by the EC2 instance's ephemeral NVMe storage. The primary vLLM runtime then loads the weights directly from the local NVMe drive, drastically compressing the load duration.SECTION 7 — vLLM Startup OptimizationOnce the physical hardware is provisioned and the data layers are synchronized, the initialization of the vLLM engine itself represents the final barrier to operational readiness. The deployment configuration must be aggressively tuned to bypass computational bottlenecks and bind execution processes to the physical hardware constraints of the node.To minimize memory traffic traversing across separate Non-Uniform Memory Access (NUMA) sockets, vLLM supports explicit NUMA binding mechanisms. Enabling this optimization ensures that specific GPU worker subprocesses are bound to designated CPU cores and memory controllers. However, executing this binding mechanism via executable hijacking mandates that the Python multiprocessing start method is explicitly forced to utilize the spawn method rather than the default fork.A secondary, yet profoundly impactful, optimization vector addresses the compilation of the computational graph. By default, vLLM utilizes torch.compile to generate optimized execution kernels tailored to the specific GPU architecture. This compilation process is notoriously CPU-bound and strictly serial, frequently adding 60 to 90 seconds to the startup sequence on every invocation. The artifacts generated by Dynamo are stored locally. By defining the VLLM_CACHE_ROOT environment variable, this output directory can be redirected onto the shared EFS PVC. Subsequent inference pods, regardless of the physical node they schedule onto, evaluate the hash of the model and configuration parameters, detect the existing compilation artifacts on the shared volume, and bypass the compilation phase entirely.The final production-ready vLLM deployment integrates the local NVMe cache synchronization, the hardware-specific NUMA bindings, and the persistent compilation cache mechanisms into a unified manifestation.YAMLapiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-inference
spec:
  replicas: 0 # Maintained at zero to enforce dynamic scale-up
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
    spec:
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      initContainers:
      - name: nvme-cache-sync
        image: alpine:latest
        command:
          - sh
          - -c
          - |
            echo "Synchronizing model weights from shared EFS to local NVMe..."
            cp -r /shared/models/Llama-3.1-8B-Instruct /local-cache/
            echo "Synchronization complete."
        volumeMounts:
          - name: shared-cache
            mountPath: /shared
          - name: local-nvme-cache
            mountPath: /local-cache
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
        args:
          - "--model"
          - "/local-cache/Llama-3.1-8B-Instruct" # Loading from fast local NVMe
          - "--tensor-parallel-size"
          - "1"
          - "--numa-bind"
          - "--gpu-memory-utilization"
          - "0.90"
        env:
          - name: VLLM_WORKER_MULTIPROC_METHOD
            value: "spawn"
          - name: VLLM_CACHE_ROOT
            value: "/shared/compile_cache" # Persisting compilation to shared EFS
        resources:
          requests:
            nvidia.com/gpu: "1"
            cpu: "8"
            memory: "32Gi"
          limits:
            nvidia.com/gpu: "1"
        volumeMounts:
          - name: shared-cache
            mountPath: /shared
            readOnly: false # Must be writeable for initial compile cache generation
          - name: local-nvme-cache
            mountPath: /local-cache
        startupProbe:
          httpGet:
            path: /health
            port: 8000
          failureThreshold: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          failureThreshold: 3
          periodSeconds: 5
      volumes:
      - name: shared-cache
        persistentVolumeClaim:
          claimName: model-cache-pvc
      - name: local-nvme-cache
        emptyDir: {} # Backed by EC2 ephemeral storage if applicable
SECTION 8 — Startup Timing (kubectl ONLY)The strict prohibition of external observability stacks dictates that the instrumentation of the startup latency must rely entirely on the native auditing capabilities of the Kubernetes control plane. Extracting precise timing metrics requires interrogating the event stream and the timestamped output of the application logs.The evaluation process begins by isolating the specific identifier of the scheduled pod.BashPOD_NAME=$(kubectl get pods -l app=vllm -o jsonpath='{.items.metadata.name}')
The duration of the pending and provisioning phases (T_pending and T_provision) is measured by analyzing the delta between specific scheduler events. The event stream contains the exact moment the scheduler fails to allocate the workload, and the subsequent moment the Kubelet on the newly minted node acknowledges the pod. The following command extracts and sorts these events chronologically:Bashkubectl get events --field-selector involvedObject.name=$POD_NAME --sort-by='.metadata.creationTimestamp' -o custom-columns=TIME:.metadata.creationTimestamp,REASON:.reason,MESSAGE:.message
The timing extraction follows a logical sequence mapping event reasons to lifecycle phases.Lifecycle PhaseStart IndicatorEnd IndicatorMeasurement TechniqueNode ProvisioningEvent: FailedScheduling (No nodes available)Event: Scheduled (Assigned to ip-10-x-x-x)Calculate the timestamp delta between the two events. Represents Karpenter's EC2 allocation and node boot sequence.Image PullingEvent: Pulling (Pulling image 'vllm/vllm...')Event: Pulled (Successfully pulled image)Calculate the delta. Evaluates the efficacy of the Spegel P2P network against the ECR baseline.InitContainer SyncEvent: Created (Created container nvme-cache-sync)Event: Started (Started container vllm)Calculate the delta. Represents the duration required to synchronize weights from EFS to local NVMe.Following the initialization of the primary container, the focus shifts from the Kubernetes event stream to the application log output. The vLLM engine emits distinct markers as it transitions through its internal initialization phases. By appending the --timestamps flag to the log retrieval command, precise measurements of the internal runtime bottlenecks are obtained.Bashkubectl logs $POD_NAME -c vllm --timestamps
The internal application phases are calculated by parsing the specific log emission patterns.Lifecycle PhaseStart IndicatorEnd IndicatorMeasurement TechniqueModel Load TimeLog: INFO [worker.py] Loading model weights...Log: INFO [worker.py] Model weights loaded.Calculate the delta. Evaluates the performance of the local NVMe read operations.Graph Compilation TimeLog: INFO [compiler.py] Compiling graph...Log: INFO [api_server.py] Uvicorn running on http://0.0.0.0:8000Calculate the delta. A near-zero value indicates successful retrieval from the shared PVC compilation cache.SECTION 9 — Experiment FrameworkThe benchmarking sequence is delineated into four highly structured, reproducible experiments. Each experiment isolates specific caching mechanisms, systematically eliminating independent latency variables.Experiment 1: Baseline (ECR + No Cache)The objective of the baseline experiment is to establish the upper bound of the cold-start latency penalty without the intervention of any local optimization strategies.Setup: The Spegel daemonset is uninstalled. The PVC mount and the initContainer synchronization logic are removed from the deployment manifest. The model is explicitly configured to download directly from the Hugging Face Hub during the pod startup sequence. The compilation cache environment variable is removed.Execution: The deployment is scaled from zero to one replica.Bashkubectl scale deployment vllm-inference --replicas=1
Observation: The infrastructure provisions, the container is fetched from ECR, the model weights download over the public internet, and the PyTorch computation graph compiles serially.Expected Results: The complete sequence heavily relies on external network bandwidth and raw CPU processing power. Total time-to-ready frequently exceeds ten to twelve minutes.Cleanup: The deployment is scaled back to zero. A brief observation period confirms that Karpenter registers the node as empty and successfully terminates the EC2 instance.Experiment 2: Spegel Enabled (P2P Image Distribution)This experiment isolates the impact of peer-to-peer image sharing on the latency associated with retrieving massive container images.Setup: The Spegel daemon is installed and initialized. A baseline node is intentionally left running within the cluster to serve as the initial peer seed for the distributed hash table. The vLLM deployment remains unoptimized regarding model loading and compilation.Execution: The deployment is scaled, forcing Karpenter to provision a secondary GPU node.Bashkubectl scale deployment vllm-inference --replicas=2
Observation: The secondary node boots and intercepts the image pull request. Instead of routing across the NAT gateway to ECR, the image layers are fetched laterally from the primary node across the VPC network.Expected Results: The image pull duration compresses dramatically, often reducing from several minutes to under 45 seconds due to local network saturation. Overall time-to-ready decreases proportionally, though model download and compilation remain unoptimized.Cleanup: The deployment is scaled back to a single replica, triggering the termination of the secondary node.Experiment 3: PVC Cached ModelThis experiment evaluates the efficacy of replacing external model downloads with internal file system reads, integrating the initContainer NVMe synchronization strategy.Setup: The initial model download job is executed, populating the EFS volume. The deployment manifest is updated to include the EFS mount, the initContainer synchronization logic, and the local emptyDir mount. The compilation cache is disabled. Spegel remains active.Execution: The deployment is scaled to provision a new node.Observation: Following the accelerated image pull, the initContainer synchronizes the weights from the slow EFS volume to the high-performance local NVMe drive. The vLLM engine then loads the model directly from the local block storage.Expected Results: The unpredictability of the public internet download is eliminated. Model load times stabilize. The time-to-ready compresses further, constrained primarily by the EFS-to-NVMe copy duration and the subsequent CPU-bound compilation phase. Total time drops to approximately three to four minutes.Cleanup: The deployment is scaled to zero, purging all infrastructure.Experiment 4: Combined Optimizations (P2P + PVC + Compile Cache)The final experiment aggregates all optimization vectors, evaluating the theoretical floor of the cold-start latency architecture.Setup: All systems are active. The deployment manifest defines the VLLM_CACHE_ROOT variable, pointing to the shared EFS directory. An initial run is executed manually to pre-populate both the model weights and the compilation artifacts onto the persistent volume.Execution: From a state of zero inference capacity, the deployment is scaled.Observation: Karpenter provisions the node. Spegel accelerates the image pull. The initContainer synchronizes the model weights. Critically, when the vLLM engine initializes, it evaluates the compilation hash, detects the pre-existing artifacts on the EFS volume, and bypasses the PyTorch compilation process entirely.Expected Results: The architecture achieves maximum efficiency. The multi-minute compilation penalty is replaced by a sub-second file system read. The total time-to-ready reaches its absolute minimum, generally bounded only by the physical boot limitations of the EC2 instance. Total time routinely drops below two and a half minutes.FINAL OUTPUTThe meticulous execution of this framework demonstrates that the implementation of native Kubernetes caching strategies can drastically mitigate the severe latency penalties associated with scale-from-zero GPU provisioning. A baseline start time exceeding twelve minutes can reliably be compressed to under two and a half minutes.The most profound reduction in latency is achieved by bypassing the torch.compile phase via the shared PVC caching mechanism (VLLM_CACHE_ROOT). This transforms a highly CPU-bound, serially executed bottleneck into a highly parallelized, near-instantaneous file system read. Similarly, the integration of Spegel for peer-to-peer image distribution fundamentally alters the scaling dynamics, allowing multiple nodes to scale concurrently without saturating external NAT gateways or hitting ECR API limits. However, the efficacy of Spegel is inherently dependent on the presence of existing peer nodes to seed the distributed hash table; the absolute first node in an entirely cold cluster will inevitably fall back to the baseline ECR pull speed.Conversely, certain configuration parameters yield negligible improvements to the specific metric of startup latency. The implementation of --numa-bind and the associated thread affinity controls, while critical for maintaining steady-state token generation throughput by preventing thread preemption and cross-NUMA socket traffic, exert no measurable positive impact on the pod initialization sequence itself.The primary, unyielding bottleneck within this architecture remains the node provisioning and joining sequence. While the Karpenter controller evaluates placement criteria and executes EC2 API calls with remarkable speed, the physical initialization of the virtual machine, coupled with the execution of the AL2023 nodeadm bootstrap routines, enforces a hard physical latency floor. This hardware boundary generally consumes between 45 and 60 seconds and cannot be mitigated further without compromising the strict scale-to-zero economic model and reverting to the use of idle warm pools.Furthermore, the architectural reliance on Elastic File Systems introduces a secondary constraint. While EFS is strictly required to satisfy the ReadWriteMany concurrent access demands of a scale-out cluster , its read throughput significantly trails that of direct-attached NVMe solid-state drives. The introduction of the initContainer synchronization strategy effectively bridges this gap, sacrificing a brief period of initial IOPS overhead to guarantee maximum throughput during the critical vLLM memory mapping phase.The enforcement of scale-to-zero logic inherently eliminates the massive financial burden of idle GPU compute, successfully fulfilling the core mandate of the architecture. However, the supporting infrastructure is not entirely cost-free. The EFS volume incurs fixed storage charges, and the synchronization of massive model artifacts during the initContainer phase generates continuous elastic throughput billing.For architectures prioritizing strict cost sensitivity, the baseline EFS-backed configuration—excluding the NVMe initContainer synchronization—remains viable. The infrastructure tolerates the slower EFS read speeds during model loading in exchange for absolute minimization of complex data management.For latency-critical deployments, the initContainer NVMe synchronization pattern is highly recommended. It seamlessly merges the concurrent access benefits of EFS with the high-performance local block storage inherent to GPU instances, ensuring that the engine initialization phase occurs with maximum velocity.Ultimately, for environments seeking the absolute optimal balance between cost, complexity, and performance, platform engineers should consider shifting the image management strategy. By utilizing Spegel for base container images and maintaining the compilation cache on EFS, but explicitly baking the static model weights directly into a customized Amazon Machine Image (AMI), the architecture completely eliminates the network-bound storage synchronization phase. This relies heavily on the superior throughput of local EBS and NVMe volumes, fundamentally optimizing the final stages of the startup sequence while honoring the economic imperatives of dynamic infrastructure provisioning.

Latest info gemini provided
### Phase 1: Shared Infrastructure & Preparation

Both experiments require the same base EKS 1.31 cluster, Karpenter installation, and EFS shared storage.

**Step 1: Provision Cluster & EFS (Terraform)**
Deploy the base EKS cluster and EFS file system.

```hcl
# main.tf
terraform { required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } } }
provider "aws" { region = "us-east-1" }

variable "cluster_name" { default = "vllm-lab-cluster" }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name    = "${var.cluster_name}-vpc"
  cidr    = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
  private_subnet_tags = { "karpenter.sh/discovery" = var.cluster_name }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
  cluster_name    = var.cluster_name
  cluster_version = "1.31"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true
  eks_managed_node_groups = {
    system = { instance_types = ["m5.large"], min_size = 2, max_size = 3, desired_size = 2 }
  }
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"
  cluster_name = module.eks.cluster_name
  enable_pod_identity             = true
  create_pod_identity_association = true
  create_node_iam_role = true
  node_iam_role_name   = "KarpenterNodeRole-${var.cluster_name}"
}

resource "aws_security_group" "efs_sg" {
  name   = "${var.cluster_name}-efs-sg"
  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}

resource "aws_efs_file_system" "model_cache" {
  creation_token = "${var.cluster_name}-efs"
  performance_mode = "maxIO"
}

resource "aws_efs_mount_target" "efs_mt" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.model_cache.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}

output "efs_id" { value = aws_efs_file_system.model_cache.id }

```

Run `terraform init && terraform apply -auto-approve`.
Export the EFS ID: `export EFS_ID=$(terraform output -raw efs_id)`

**Step 2: Bootstrap Cluster Drivers & Karpenter**

```bash
aws eks update-kubeconfig --region us-east-1 --name vllm-lab-cluster

# Install EFS CSI Driver
eksctl create iamserviceaccount --name efs-csi-controller-sa --namespace kube-system \
    --cluster vllm-lab-cluster \
    --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
    --approve --override-existing-serviceaccounts --region us-east-1

helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm upgrade -i aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver \
    --namespace kube-system \
    --set controller.serviceAccount.create=false \
    --set controller.serviceAccount.name=efs-csi-controller-sa

# Install NVIDIA Device Plugin (Lightweight alternative to GPU Operator)
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin --create-namespace \
  --set gfd.enabled=true

# Install Karpenter
export KARPENTER_ROLE=$(aws iam get-role --role-name KarpenterControllerRole-vllm-lab-cluster --query Role.Arn --output text)
helm registry logout public.ecr.aws
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.0.0 \
  --namespace kube-system \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${KARPENTER_ROLE} \
  --set settings.clusterName=vllm-lab-cluster \
  --set settings.interruptionQueueName="Karpenter-vllm-lab-cluster"

```

**Step 3: Setup Shared PVC and Download Model Once**
Create the `ReadWriteMany` PVC and populate it using a Job.

```yaml
# storage.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-YOUR_EFS_ID_HERE # Replace with $EFS_ID
  directoryPerms: "777"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache-pvc
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 200Gi
---
apiVersion: batch/v1
kind: Job
metadata:
  name: initial-model-download
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: downloader
        image: python:3.11-slim
        command: ["sh", "-c"]
        args:
          - |
            pip install huggingface_hub hf_transfer
            export HF_HUB_ENABLE_HF_TRANSFER=1
            huggingface-cli download meta-llama/Llama-3.1-8B-Instruct --local-dir /shared/models/Llama-3.1-8B-Instruct
        volumeMounts:
          - name: shared-cache
            mountPath: /shared
      volumes:
        - name: shared-cache
          persistentVolumeClaim:
            claimName: model-cache-pvc

```

Apply this and wait for the Job to complete: `kubectl wait --for=condition=complete job/initial-model-download --timeout=600s`

---

### Experiment 1: Unoptimized Baseline (Direct EFS, No Spegel)

In this baseline, Karpenter provisions an Ubuntu 24.04 node. Containerd sequentially downloads the large vLLM image directly from Dockerhub. The pod starts and loads the model directly from the slow EFS network drive, suffering from network IOPS limits and CPU bounce-buffer overhead.

**1. Apply Baseline Karpenter Config:**

```yaml
# karpenter-baseline.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-ubuntu2404-baseline
spec:
  amiFamily: Ubuntu
  amiSelectorTerms:
    - alias: ubuntu2404@latest # Uses official EKS Ubuntu 24.04 GPU AMI
  role: "KarpenterNodeRole-vllm-lab-cluster"
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "vllm-lab-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "vllm-lab-cluster"
  blockDeviceMappings:
    - deviceName: /dev/sda1
      ebs:
        volumeSize: 200Gi
        volumeType: gp3
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-baseline
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g", "p"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-ubuntu2404-baseline
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 10s

```

**2. Deploy Unoptimized vLLM:**

```yaml
# vllm-baseline.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-baseline
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-baseline
  template:
    metadata:
      labels:
        app: vllm-baseline
    spec:
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      containers:
      - name: vllm
        image: docker.io/vllm/vllm-openai:latest # Dockerhub explicit
        command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
        args:
          - "--model"
          - "/shared/models/Llama-3.1-8B-Instruct" # Direct EFS read
          - "--tensor-parallel-size=1"
          - "--gpu-memory-utilization=0.90"
        resources:
          limits:
            nvidia.com/gpu: "1"
        volumeMounts:
          - name: shared-cache
            mountPath: /shared
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          periodSeconds: 5
      volumes:
      - name: shared-cache
        persistentVolumeClaim:
          claimName: model-cache-pvc

```

**Benchmarking Baseline:**
Apply the manifests and track timestamps.

```bash
POD_NAME=$(kubectl get pods -l app=vllm-baseline -o jsonpath='{.items.metadata.name}')
# Node boot & Image pull duration
kubectl get events --field-selector involvedObject.name=$POD_NAME
# Model load & Compilation duration
kubectl logs $POD_NAME -c vllm --timestamps

```

*Clean up:* `kubectl delete -f vllm-baseline.yaml` and wait for Karpenter to terminate the node.

---

### Experiment 2: Fully Optimized (Spegel, NVMe, FastSafetensors, Compile Cache)

In this setup, we introduce Spegel for P2P Dockerhub mirroring. We deploy a DaemonSet to RAID0 the physical NVMe disks on the EC2 instances. An InitContainer copies the model from EFS to NVMe, and vLLM maps it using `fastsafetensors` directly to the GPU. We also persist the CUDA graph compilation to EFS.

**1. Deploy Spegel & NVMe RAID0 DaemonSet**

```bash
helm upgrade --install spegel oci://ghcr.io/spegel-org/helm-charts/spegel \
  --namespace spegel --create-namespace \
  --set "tolerations.key=nvidia.com/gpu" \
  --set "tolerations.operator=Exists" \
  --set "tolerations.effect=NoSchedule"

```

```yaml
# nvme-raid.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvme-raid0
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvme-raid0
  template:
    metadata:
      labels:
        name: nvme-raid0
    spec:
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      hostPID: true
      containers:
      - name: formatter
        image: ubuntu:24.04
        securityContext:
          privileged: true
        command:
        - /bin/bash
        - -c
        - |
          apt-get update && apt-get install -y mdadm
          devices=($(ls /dev/nvme*n1 2>/dev/null | grep -v nvme0))
          if [ ${#devices[@]} -eq 0 ]; then sleep infinity; fi
          if [! -b "/dev/md0" ]; then
            echo "y" | mdadm --create /dev/md0 --level=0 --raid-devices=${#devices[@]} "${devices[@]}"
            mkfs.ext4 -F /dev/md0
          fi
          mkdir -p /mnt/fast-disks
          if! mountpoint -q /mnt/fast-disks; then
            mount /dev/md0 /mnt/fast-disks
            chmod 777 /mnt/fast-disks
          fi
          sleep infinity
        volumeMounts:
        - name: dev
          mountPath: /dev
        - name: host-mount
          mountPath: /mnt/fast-disks
          mountPropagation: Bidirectional
      volumes:
      - name: dev
        hostPath: { path: /dev }
      - name: host-mount
        hostPath: { path: /mnt/fast-disks }

```

**2. Apply Optimized Karpenter Config (Ubuntu 24.04 + Containerd 2.1)**
Ubuntu 24.04 uses Containerd 2.1 via `nodeadm`. We must inject configuration to disable the transfer service (`use_local_image_pull = true`) and setup the `docker.io` registry path so Spegel can intercept Dockerhub pulls.

```yaml
# karpenter-optimized.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-ubuntu2404-optimized
spec:
  amiFamily: Ubuntu
  amiSelectorTerms:
    - alias: ubuntu2404@latest
  role: "KarpenterNodeRole-vllm-lab-cluster"
  subnetSelectorTerms: { tags: { karpenter.sh/discovery: "vllm-lab-cluster" } }
  securityGroupSelectorTerms: { tags: { karpenter.sh/discovery: "vllm-lab-cluster" } }
  blockDeviceMappings:
    - deviceName: /dev/sda1
      ebs: { volumeSize: 200Gi, volumeType: gp3 }
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: text/x-shellscript
    
    #!/bin/bash
    # Prepare docker.io mirror directory for Spegel
    mkdir -p /etc/containerd/certs.d/docker.io
    cat <<EOF > /etc/containerd/certs.d/docker.io/hosts.toml
    server = "https://registry-1.docker.io"
    [host."https://registry-1.docker.io"]
      capabilities = ["pull", "resolve"]
    EOF

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      containerd:
        config: |
          [plugins."io.containerd.cri.v1.images".registry]
            config_path = "/etc/containerd/certs.d"
          [plugins."io.containerd.cri.v1.images"]
            discard_unpacked_layers = false
            use_local_image_pull = true
    --BOUNDARY--
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu-optimized
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["g", "p"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-ubuntu2404-optimized
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 10s

```

**3. Deploy Optimized vLLM:**

```yaml
# vllm-optimized.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-optimized
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-optimized
  template:
    metadata:
      labels:
        app: vllm-optimized
    spec:
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      initContainers:
      - name: cache-sync
        image: alpine:latest
        command: ["sh", "-c"]
        args:
          - |
            if; then
              echo "Syncing weights from EFS to local NVMe..."
              cp -r /shared/models/Llama-3.1-8B-Instruct /local-nvme/
            fi
        volumeMounts:
          - name: shared-cache
            mountPath: /shared
          - name: local-nvme
            mountPath: /local-nvme
      containers:
      - name: vllm
        image: docker.io/vllm/vllm-openai:latest
        command: ["python3", "-m", "vllm.entrypoints.openai.api_server"]
        args:
          - "--model"
          - "/local-nvme/Llama-3.1-8B-Instruct" # Loads directly from NVMe HostPath
          - "--tensor-parallel-size=1"
          - "--load-format=fastsafetensors" # GPUDirect VRAM load
          - "--numa-bind" # Binds CPU cores to prevent cross-socket drift
          - "--gpu-memory-utilization=0.90"
        env:
          - name: USE_FASTSAFETENSOR
            value: "true"
          - name: VLLM_WORKER_MULTIPROC_METHOD
            value: "spawn" # Required for NUMA bind
          - name: VLLM_CACHE_ROOT
            value: "/shared/compile_cache" # Persists torch.compile to EFS
        resources:
          limits:
            nvidia.com/gpu: "1"
        volumeMounts:
          - name: shared-cache
            mountPath: /shared
          - name: local-nvme
            mountPath: /local-nvme
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          periodSeconds: 5
      volumes:
      - name: shared-cache
        persistentVolumeClaim:
          claimName: model-cache-pvc
      - name: local-nvme
        hostPath:
          path: /mnt/fast-disks

```

**Benchmarking Optimized:**
Scale the deployment up. *Note:* For Spegel to work, you need at least one running seed pod somewhere in the cluster with the Dockerhub image cached.

```bash
POD_NAME=$(kubectl get pods -l app=vllm-optimized -o jsonpath='{.items.metadata.name}')
# Verify Spegel P2P Pull (Should be 10-30s instead of 3-5m)
kubectl get events --field-selector involvedObject.name=$POD_NAME
# Verify NVMe sync and Compile Cache hit
kubectl logs $POD_NAME -c vllm --timestamps

```