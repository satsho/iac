# Windows Server 2025用のパッチベースライン。RHEL用(patch_baseline.tf)とは
# operating_system・分類/深刻度のフィルタキーが異なるため別ファイルに分けている。
# ゲート(gated-patch-baseline)・install-now・日次スキャン・通知はOSを問わない作りなので、
# ここで新しく作る必要はない。

locals {
  # パッチベースラインのキー(tst/stg/prd) => パッチグループ名。インスタンスのPatchGroupタグと一致させる
  patch_groups_windows = { for env in keys(var.windows_patch_baselines) : env => "win2025-${env}" }
}

resource "aws_ssm_patch_baseline" "windows" {
  for_each = var.windows_patch_baselines

  name             = "${local.name}-win2025-${each.key}"
  description      = "Windows Server 2025 ${each.key}: ${each.value.approve_until_date == null ? "approve after ${each.value.approve_after_days} day(s)" : "approve until ${each.value.approve_until_date}"}"
  operating_system = "WINDOWS"

  approved_patches                     = each.value.approved_patches
  approved_patches_enable_non_security = false
  rejected_patches                     = each.value.rejected_patches
  rejected_patches_action              = "BLOCK"

  approval_rule {
    approve_after_days  = each.value.approve_after_days
    approve_until_date  = each.value.approve_until_date
    enable_non_security = false

    patch_filter {
      key    = "CLASSIFICATION"
      values = each.value.classifications
    }

    patch_filter {
      key    = "MSRC_SEVERITY"
      values = each.value.severities
    }

    # WindowsServer2025以外(他バージョン・関連製品)を対象外にする
    patch_filter {
      key    = "PRODUCT"
      values = ["WindowsServer2025"]
    }
  }

  # install-nowがupdate-patch-baseline APIで直接書き換える対象。RHEL側(patch_baseline.tf)と同じ理由。
  lifecycle {
    ignore_changes = [approved_patches]
  }
}

resource "aws_ssm_patch_group" "windows" {
  for_each = var.windows_patch_baselines

  baseline_id = aws_ssm_patch_baseline.windows[each.key].id
  patch_group = local.patch_groups_windows[each.key]
}

# 日次スキャン(Windows分)。RHEL分(patch_baseline.tfのaws_ssm_association.patch_scan)とは
# 別の関連付けにしている。1つのターゲットタグに指定できる値は最大5個(AWSの制限)で、
# RHEL(3個)+Windows(3個)=6個が1つの関連付けには収まらないため。
resource "aws_ssm_association" "patch_scan_windows" {
  name                = "AWS-RunPatchBaseline"
  association_name    = "${local.name}-daily-scan-windows"
  schedule_expression = var.patch_scan_schedule

  apply_only_at_cron_interval = true

  max_concurrency = "100%"
  max_errors      = "100%"

  parameters = {
    Operation    = "Scan"
    RebootOption = "NoReboot"
  }

  targets {
    key    = "tag:PatchGroup"
    values = values(local.patch_groups_windows)
  }
}
