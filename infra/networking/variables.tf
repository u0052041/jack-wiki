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

variable "vpc_cidr" {
    description = "CIDR block for the VPC"
    type        = string
    default     = "10.0.0.0/16"
}

variable "enable_nat_gateway" {
    description = "開關 NAT Gateway（約 $32/月）。開啟：-var='enable_nat_gateway=true'，關閉：-var='enable_nat_gateway=false'"
    type        = bool
    default     = true
}

variable "wildcard_domain" {
    description = "Wildcard domain for ACM certificate (e.g. *.example.com)"
    type        = string
    default     = "*.u0052041.com"
}
