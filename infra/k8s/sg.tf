# Jenkins controller -> EKS API（讓 Jenkins 能呼叫 K8s API 建 agent pods）
resource "aws_security_group_rule" "eks_from_jenkins" {
    type                     = "ingress"
    from_port                = 443
    to_port                  = 443
    protocol                 = "tcp"
    security_group_id        = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
    source_security_group_id = data.aws_security_group.jenkins_controller.id
}
