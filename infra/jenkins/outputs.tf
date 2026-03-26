output "elastic_ip" {
    description = "Public IP of Jenkins controller (for Ansible inventory)"
    value       = aws_eip.jenkins.public_ip
}

output "ssh_command" {
    description = "SSH command to connect to Jenkins controller"
    value       = "ssh -i ~/.ssh/jenkins-key ec2-user@${aws_eip.jenkins.public_ip}"
}

output "instance_id" {
    description = "EC2 instance ID"
    value       = aws_instance.jenkins.id
}

output "ecs_cluster_arn" {
    description = "ECS cluster ARN (Jenkins ECS plugin: Cloud > Cluster ARN)"
    value       = aws_ecs_cluster.jenkins_agents.arn
}

output "ecs_task_execution_role_arn" {
    description = "ECS task execution role ARN (Jenkins ECS plugin: Task Execution Role ARN)"
    value       = aws_iam_role.ecs_task_execution.arn
}

output "agent_security_group_id" {
    description = "Agent security group ID (Jenkins ECS plugin: Security Group)"
    value       = aws_security_group.jenkins_agent.id
}

output "agent_subnet_id" {
    description = "Subnet ID for ECS agents (Jenkins ECS plugin: Subnets)"
    value       = aws_subnet.public.id
}
