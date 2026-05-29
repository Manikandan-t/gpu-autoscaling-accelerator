output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
#
# output "efs_file_system_id" {
#   value = aws_efs_file_system.vllm_models.id
# }

output "efs_file_system_id" {
  value = aws_efs_file_system.model_cache.id
}