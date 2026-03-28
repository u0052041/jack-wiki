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

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
    role = aws_iam_role.jenkins.name
    policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
    name = "jenkins-profile"
    role = aws_iam_role.jenkins.name
}
