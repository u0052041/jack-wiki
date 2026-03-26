resource "aws_key_pair" "jenkins" {
    key_name   = "jenkins-key"
    public_key = file(var.ssh_public_key_path)
    tags       = merge(local.common_tags, { Name = "jenkins-key" })
}

resource "aws_instance" "jenkins" {
    ami           = var.jenkins_ami
    instance_type = var.jenkins_instance_type
    tags          = merge(local.common_tags, { Name = "jenkins-controller" })
    availability_zone           = var.availability_zone
    subnet_id                   = aws_subnet.public.id
    vpc_security_group_ids      = [aws_security_group.jenkins_controller.id]
    associate_public_ip_address = true
    iam_instance_profile        = aws_iam_instance_profile.jenkins.name
    key_name                    = aws_key_pair.jenkins.key_name
    root_block_device {
        encrypted = true
    }
}

resource "aws_eip" "jenkins" {
    instance = aws_instance.jenkins.id
    domain   = "vpc"
    tags     = merge(local.common_tags, { Name = "jenkins-eip" })
}

resource "aws_ebs_volume" "jenkins" {
    availability_zone = var.availability_zone
    size              = 20
    type              = "gp3"
    encrypted         = true
    tags              = merge(local.common_tags, { Name = "jenkins-data" })

    lifecycle {
        prevent_destroy = true
    }
}

resource "aws_volume_attachment" "jenkins" {
    device_name = "/dev/xvdf"
    volume_id = aws_ebs_volume.jenkins.id
    instance_id = aws_instance.jenkins.id
}
