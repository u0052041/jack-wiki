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

variable "vpc_cidr" {
    description = "CIDR block for the VPC"
    type        = string
    default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
    description = "CIDR block for the public subnet"
    type        = string
    default     = "10.0.1.0/24"
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

variable "jenkins_controller_image" {
    description = "Docker image for Jenkins controller"
    type        = string
    default     = "jenkins/jenkins:2.541.3-lts"
}

variable "jenkins_agent_image" {
    description = "Docker image for Jenkins agent (must match controller version)"
    type        = string
    default     = "jenkins/inbound-agent:3261.v9c670a_4748a_9-8"
}

variable "jenkins_agent_cpu" {
    description = "CPU units for Jenkins agent Fargate task (1024 = 1 vCPU)"
    type        = number
    default     = 512
}

variable "jenkins_agent_memory" {
    description = "Memory (MB) for Jenkins agent Fargate task"
    type        = number
    default     = 1024
}

variable "ssh_public_key_path" {
    description = "Path to SSH public key for EC2 access"
    type        = string
    default     = "~/.ssh/jenkins-key.pub"
}
