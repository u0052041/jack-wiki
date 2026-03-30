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

variable "availability_zone" {
    description = "Availability zone for EC2 and EBS"
    type        = string
    default     = "ap-northeast-1a"
}

variable "jenkins_ami" {
    description = "AMI ID for Jenkins EC2 (Amazon Linux 2023)"
    type        = string
    default     = "ami-088b486f20fab3f0e"
}

variable "jenkins_instance_type" {
    description = "EC2 instance type for Jenkins controller"
    type        = string
    default     = "t3.small"
}

variable "jenkins_domain" {
    description = "Domain for Jenkins (e.g. jenkins.example.com)"
    type        = string
    default     = "jenkins.u0052041.com"
}

variable "enable_alb" {
    description = "開關 ALB（約 $16/月）。開啟：-var='enable_alb=true'，關閉：-var='enable_alb=false'"
    type        = bool
    default     = true
}
