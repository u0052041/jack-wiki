variable "environment" {
    description = "Deployment environment (e.g. prod, staging)"
    type        = string
    default     = "prod"
}

variable "aws_region" {
    description = "AWS region"
    type        = string
    default     = "ap-northeast-1"
}

variable "cluster_name" {
    description = "EKS cluster name"
    type        = string
    default     = "main-eks"
}

variable "cluster_version" {
    description = "Kubernetes version"
    type        = string
    default     = "1.30"
}

variable "node_instance_type" {
    description = "EC2 instance type for EKS worker nodes"
    type        = string
    default     = "t3.medium"
}

variable "node_desired_size" {
    description = "Desired number of worker nodes"
    type        = number
    default     = 2
}

variable "node_min_size" {
    description = "Minimum number of worker nodes"
    type        = number
    default     = 2
}

variable "node_max_size" {
    description = "Maximum number of worker nodes"
    type        = number
    default     = 2
}
