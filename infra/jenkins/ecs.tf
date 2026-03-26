resource "aws_ecs_cluster" "jenkins_agents" {
    name = "jenkins-agents"
    tags = merge(local.common_tags, { Name = "jenkins-agents" })
}

resource "aws_ecs_task_definition" "jenkins_agent" {
    family = "jenkins-agent"
    tags   = merge(local.common_tags, { Name = "jenkins-agent" })
    cpu    = var.jenkins_agent_cpu
    memory = var.jenkins_agent_memory
    network_mode = "awsvpc"
    requires_compatibilities = ["FARGATE"]
    execution_role_arn = aws_iam_role.ecs_task_execution.arn

    container_definitions = jsonencode([{
        name  = "jenkins-agent"
        image = var.jenkins_agent_image
        essential = true
        logConfiguration = {
            logDriver = "awslogs"
            options = {
                "awslogs-group" = aws_cloudwatch_log_group.jenkins_agent.name
                "awslogs-region" = var.aws_region
                "awslogs-stream-prefix" = "ecs"
            }
        }
    }])
}
