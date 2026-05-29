terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.20" }
  }
}

provider "aws" { region = "us-east-1" }

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

variable "cluster_name" { default = "gpu-accelerator" }

# 1. VPC Configuration
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name    = "${var.cluster_name}-vpc"
  cidr    = "10.0.0.0/16"
  azs             = ["us-east-1d", "us-east-1b", "us-east-1a", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24", "10.0.104.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
  private_subnet_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# 2. EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
  cluster_name    = var.cluster_name
  cluster_version = "1.35"
  vpc_id          = module.vpc.vpc_id
  # EKS control plane is locked to original AZs; worker subnets are tagged for Karpenter
  subnet_ids      = slice(module.vpc.private_subnets, 0, 2)
  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    eks-pod-identity-agent = {}
  }

  eks_managed_node_groups = {
    system = {
      instance_types = ["g6.xlarge"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
    }
  }
}

# 3. Karpenter IAM

# 4. Amazon EFS (No S3)


resource "aws_efs_file_system" "model_cache" {
  creation_token = "${var.cluster_name}-efs"
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
}

resource "aws_efs_mount_target" "efs_mt" {
  count           = length(module.vpc.private_subnets)
  file_system_id  = aws_efs_file_system.model_cache.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs_sg.id]
}
