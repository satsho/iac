moved {
  from = aws_instance.rke2
  to   = aws_instance.k3s
}

resource "aws_instance" "k3s" {
  ami                    = var.rhel_ami_id
  instance_type          = var.rke2_instance_type
  subnet_id              = values(module.network.public_subnet_ids)[0]
  vpc_security_group_ids = [aws_security_group.instance.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  ebs_optimized          = true

  # user_dataはEC2の初回起動時にしか実行されないため、内容が変わったら
  # インスタンスごと作り直して確実に反映させる(RKE2→k3s移行もこれで反映される)。
  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  user_data = templatefile("${path.module}/templates/ansible-bootstrap.sh.tpl", {
    aws_region            = var.aws_region
    rhel_org_id           = var.rhel_org_id
    rhel_activation_key   = var.rhel_activation_key
    ansible_repo_url      = var.ansible_repo_url
    ansible_repo_revision = var.ansible_repo_revision
    argocd_repo_url       = var.argocd_repo_url
    argocd_repo_path      = var.argocd_repo_path
    argocd_repo_revision  = var.argocd_repo_revision
  })

  tags = {
    Name = "${var.project_name}-k3s-server"
    Role = "k3s-server"
  }
}
