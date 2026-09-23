moved {
  from = aws_instance.test
  to   = aws_instance.rke2
}

resource "aws_instance" "rke2" {
  ami                    = var.rhel_ami_id
  instance_type          = var.rke2_instance_type
  subnet_id              = values(module.network.public_subnet_ids)[0]
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  ebs_optimized          = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/templates/rke2-user-data.sh.tpl", {
    rhel_org_id         = var.rhel_org_id
    rhel_activation_key = var.rhel_activation_key
  })

  tags = {
    Name = "${var.project_name}-rke2-server"
    Role = "rke2-server"
  }
}
