data "aws_caller_identity" "current" {}

resource "aws_iam_role" "jenkins" {
    name = "jenkins-role"
    tags = merge(local.common_tags, { Name = "jenkins-role" })

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
        Effect = "Allow"
        Principal = {Service = "ec2.amazonaws.com"}
        Action = "sts:AssumeRole"
        }]
    })
}

resource "aws_iam_role_policy" "jenkins_ecs" {
    name = "jenkins-ecs-policy"
    role = aws_iam_role.jenkins.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
            # 這幾個動作 AWS 不支援 resource-level 限縮，只能填 *
            {
                Effect = "Allow"
                Action = [
                    "ecs:RegisterTaskDefinition",
                    "ecs:DeregisterTaskDefinition",
                    "ecs:ListTaskDefinitions",
                    "ecs:DescribeTaskDefinition",
                    "ecs:ListClusters",
                    "ecs:DescribeClusters",
                    "ecs:TagResource",
                    "ecs:ListTagsForResource"
                ]
                Resource = "*"
            },
            # RunTask 需要 task definition ARN 和 cluster ARN
            {
                Effect   = "Allow"
                Action   = ["ecs:RunTask"]
                Resource = [
                    "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/*",
                    aws_ecs_cluster.jenkins_agents.arn
                ]
            },
            # StopTask / DescribeTasks 的 resource 是 task ARN
            {
                Effect = "Allow"
                Action = [
                    "ecs:StopTask",
                    "ecs:DescribeTasks"
                ]
                Resource = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/*"
            },
            {
                Effect   = "Allow"
                Action   = ["iam:PassRole"]
                Resource = [aws_iam_role.ecs_task_execution.arn]
            }
        ]
    })
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
    role = aws_iam_role.jenkins.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "jenkins_ssm_params" {
    name = "jenkins-ssm-params"
    role = aws_iam_role.jenkins.id

    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect   = "Allow"
            Action   = ["ssm:GetParameter"]
            Resource = aws_ssm_parameter.cloudflare_tunnel_token.arn
        }]
    })
}

resource "aws_iam_instance_profile" "jenkins" {
    name = "jenkins-profile"
    role = aws_iam_role.jenkins.name
}

resource "aws_iam_role" "ecs_task_execution" {
    name = "jenkins-ecs-task-execution-role"
    tags = merge(local.common_tags, { Name = "jenkins-ecs-task-execution-role" })

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
        Effect = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action = "sts:AssumeRole"
        }]
    })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
    role = aws_iam_role.ecs_task_execution.name
    policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
