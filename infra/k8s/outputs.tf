output "cluster_name" {
    description = "EKS cluster name"
    value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
    description = "EKS cluster API endpoint"
    value       = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
    description = "EKS cluster CA certificate (base64 encoded)"
    value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "node_group_status" {
    description = "EKS node group status"
    value       = aws_eks_node_group.main.status
}

output "alb_controller_role_arn" {
    description = "IAM role ARN for AWS Load Balancer Controller"
    value       = aws_iam_role.alb_controller.arn
}
