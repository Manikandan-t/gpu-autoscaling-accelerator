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