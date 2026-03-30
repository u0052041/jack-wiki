resource "aws_eks_node_group" "main" {
    cluster_name    = aws_eks_cluster.main.name
    node_group_name = "${var.cluster_name}-nodes"
    node_role_arn   = aws_iam_role.eks_node.arn
    subnet_ids      = data.terraform_remote_state.networking.outputs.private_subnet_ids
    instance_types  = [var.node_instance_type]
    tags            = merge(local.common_tags, { Name = "${var.cluster_name}-nodes" })

    scaling_config {
        desired_size = var.node_desired_size
        min_size     = var.node_min_size
        max_size     = var.node_max_size
    }

    update_config {
        max_unavailable = 1
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_worker_node,
        aws_iam_role_policy_attachment.eks_cni,
        aws_iam_role_policy_attachment.eks_ecr_read,
        aws_iam_role_policy_attachment.eks_node_ssm,
    ]
}
