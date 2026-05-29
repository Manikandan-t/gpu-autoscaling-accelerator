module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"
  cluster_name = module.eks.cluster_name
  enable_pod_identity             = true
  create_pod_identity_association = true
  create_node_iam_role            = true
  node_iam_role_name              = "KarpenterNodeRole-${var.cluster_name}"
  node_iam_role_use_name_prefix   = false

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}