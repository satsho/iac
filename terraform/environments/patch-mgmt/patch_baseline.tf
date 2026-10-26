locals {
  # パッチベースラインのキー(test/stg/prod/mgmt) => パッチグループ名。インスタンスの PatchGroup タグと一致させる
  patch_groups = { for env in keys(var.patch_baselines) : env => "rhel10-${env}" }
}

resource "aws_ssm_patch_baseline" "rhel" {
  for_each = var.patch_baselines

  name             = "${local.name}-rhel10-${each.key}"
  description      = "RHEL 10 ${each.key}: ${each.value.approve_until_date == null ? "approve after ${each.value.approve_after_days} day(s)" : "approve until ${each.value.approve_until_date}"}"
  operating_system = "REDHAT_ENTERPRISE_LINUX"

  # 承認ルールより優先される明示リスト。緊急パッチ(承認待ち日数を飛ばしたい)はapproved_patchesに、
  # 不具合が判明したパッチの除外はrejected_patchesに、アドバイザリID(RHSA-...)などで書く。
  approved_patches                     = each.value.approved_patches
  approved_patches_enable_non_security = false
  rejected_patches                     = each.value.rejected_patches
  # BLOCK: 他パッケージの依存関係として引き込まれる場合も含めてインストールしない
  rejected_patches_action = "BLOCK"

  approval_rule {
    approve_after_days  = each.value.approve_after_days
    approve_until_date  = each.value.approve_until_date
    enable_non_security = false

    patch_filter {
      key    = "CLASSIFICATION"
      values = each.value.classifications
    }

    patch_filter {
      key    = "SEVERITY"
      values = each.value.severities
    }
  }
}

resource "aws_ssm_patch_group" "rhel" {
  for_each = var.patch_baselines

  baseline_id = aws_ssm_patch_baseline.rhel[each.key].id
  patch_group = local.patch_groups[each.key]
}

# スキャン(不足パッチの検出とコンプライアンス報告)は、インストールとは分けてState Managerで毎日行う。
# メンテナンスウィンドウのゲートチェックや、Patch Managerのダッシュボードはこの結果を見る。
resource "aws_ssm_association" "patch_scan" {
  name                = "AWS-RunPatchBaseline"
  association_name    = "${local.name}-daily-scan"
  schedule_expression = var.patch_scan_schedule

  # 作成直後はまだミラーが空でスキャンが失敗するので、スケジュールの時刻まで待たせる
  # (すぐ試したい場合はコンソールの「関連付けを今すぐ適用」で実行する)
  apply_only_at_cron_interval = true

  max_concurrency = "100%"
  max_errors      = "100%"

  parameters = {
    Operation    = "Scan"
    RebootOption = "NoReboot"
  }

  targets {
    key    = "tag:PatchGroup"
    values = values(local.patch_groups)
  }
}
