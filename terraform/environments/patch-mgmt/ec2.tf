locals {
  name = "${var.project_name}-patch"

  # repository/infra は rsyncd の許可設定や業務サーバの repo ファイルから参照するのでIPを固定する
  repository_ip = cidrhost(var.private_subnet_cidr, 10)
  infra_ip      = cidrhost(var.private_subnet_cidr, 11)

  # ミラー上のディレクトリ: /var/www/html/repos/rhel/<release_dir>/<upstream_reposのキー>/
  release_dir = var.rhel_release != "" ? var.rhel_release : "latest"

  user_data_common = templatefile("${path.module}/templates/common.sh.tpl", {
    aws_region = var.aws_region
    timezone   = var.timezone
  })

  user_data_rhsm = templatefile("${path.module}/templates/rhsm.sh.tpl", {
    rhel_release     = var.rhel_release
    repo_enable_args = join(" ", [for id in values(var.upstream_repos) : "--enable=${id}"])
  })

  mirror_servers = {
    repository = {
      private_ip         = local.repository_ip
      security_group_ids = [aws_security_group.repository.id]
      script = templatefile("${path.module}/templates/repository.sh.tpl", {
        upstream_repos    = var.upstream_repos
        release_dir       = local.release_dir
        infra_ip          = local.infra_ip
        reposync_schedule = var.reposync_schedule
      })
    }
    infra = {
      private_ip         = local.infra_ip
      security_group_ids = [aws_security_group.infra.id]
      script = templatefile("${path.module}/templates/infra.sh.tpl", {
        repository_ip        = local.repository_ip
        mirror_sync_schedule = var.mirror_sync_schedule
      })
    }
  }
}

# ---------------------------------------------------------------------------
# repository / infra(リポジトリサーバとミラー)
# ---------------------------------------------------------------------------

# reposync したデータ(数十GB)はインスタンスと別のEBSに置く。user_data を直して
# インスタンスを作り直しても、CDNから全量を取り直さずに済む。
resource "aws_ebs_volume" "mirror" {
  for_each = local.mirror_servers

  availability_zone = var.availability_zone
  size              = var.mirror_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${local.name}-${each.key}-data"
  }
}

resource "aws_instance" "mirror" {
  for_each = local.mirror_servers

  ami                    = var.rhel_ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = each.value.private_ip
  vpc_security_group_ids = each.value.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  ebs_optimized          = true

  # user_dataは初回起動時にしか実行されないため、内容が変わったら作り直して確実に反映させる
  user_data_replace_on_change = true

  user_data = join("\n", [
    local.user_data_common,
    templatefile("${path.module}/templates/data-volume.sh.tpl", {
      volume_serial = replace(aws_ebs_volume.mirror[each.key].id, "-", "")
      mount_point   = "/var/www/html/repos"
    }),
    local.user_data_rhsm,
    each.value.script,
  ])

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = {
    Name         = "${local.name}-${each.key}"
    Role         = each.key
    Env          = "mgmt"
    App          = "repo-mirror"
    PatchGroup   = "rhel10-mgmt"
    RebootPolicy = "manual"
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.patch_baselines), "mgmt")
      error_message = "repository/infra 用に patch_baselines に mgmt を定義してください。"
    }
  }

  depends_on = [aws_route.private_nat]
}

resource "aws_volume_attachment" "mirror" {
  for_each = local.mirror_servers

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mirror[each.key].id
  instance_id = aws_instance.mirror[each.key].id

  # マウント中のまま外すとファイルシステムが壊れうるので、インスタンスを止めてから外す
  stop_instance_before_detaching = true
}

# ---------------------------------------------------------------------------
# 業務サーバ(test / stg / prod)
# ---------------------------------------------------------------------------

resource "aws_instance" "workload" {
  for_each = var.workloads

  ami                    = var.rhel_ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.workload.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  ebs_optimized          = true

  user_data_replace_on_change = true

  user_data = join("\n", [
    local.user_data_common,
    templatefile("${path.module}/templates/workload.sh.tpl", {
      upstream_repos = var.upstream_repos
      release_dir    = local.release_dir
      infra_ip       = local.infra_ip
    }),
  ])

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Patch Manager / メンテナンスウィンドウはこれらのタグでサーバを選ぶ(タグ設計はREADME参照)
  tags = {
    Name         = "${local.name}-${each.key}"
    Role         = "workload"
    Env          = each.value.env
    App          = each.value.app
    PatchGroup   = "rhel10-${each.value.env}"
    RebootPolicy = each.value.reboot_policy
  }

  lifecycle {
    precondition {
      condition     = contains(keys(var.patch_baselines), each.value.env)
      error_message = "env に対応するパッチベースラインが patch_baselines にありません。"
    }
  }

  # SSM Agent が起動直後に SSM へ登録できるよう、出口(NAT/エンドポイント)を先に作っておく
  depends_on = [aws_route.private_nat, aws_vpc_endpoint.interface, aws_vpc_endpoint.s3]
}
