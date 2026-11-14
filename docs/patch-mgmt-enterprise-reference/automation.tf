locals {
  # IAMポリシー(起動できるRunbookの限定)からも参照するので、リソース属性ではなく名前で持つ
  document_names = {
    gated_patch             = "${local.name}-GatedPatchBaseline"
    reboot_and_scan_rhel    = "${local.name}-RebootAndScanRhel"
    reboot_and_scan_windows = "${local.name}-RebootAndScanWindows"
    install_now             = "${local.name}-InstallNow"
  }

  # install-nowのTargetTagValuesに指定できるPatchGroup一覧と、各PatchGroupのOS
  # (RHEL/Windowsのどちらのパッチベースラインを更新すべきか)の対応表
  install_now_patch_group_os = merge(
    { for g in values(local.patch_groups) : g => "REDHAT_ENTERPRISE_LINUX" },
    { for g in values(local.patch_groups_windows) : g => "WINDOWS" },
  )
}

# メンテナンスウィンドウ(stg/prd)から呼ばれる。前段ステージの成功を確認してからパッチを適用する。
resource "aws_ssm_document" "gated_patch" {
  name            = local.document_names.gated_patch
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/gated-patch-baseline.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
  })
}

# 手動再起動パターン用(RHEL)。運用者が好きなタイミングで実行し、再起動後にスキャンして
# コンプライアンスを更新する。
resource "aws_ssm_document" "reboot_and_scan_rhel" {
  name            = local.document_names.reboot_and_scan_rhel
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/reboot-and-scan-rhel.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
  })
}

# reboot_and_scan_rhelのWindows版(AWS-RunShellScriptではなくAWS-RunPowerShellScriptを使う)。
resource "aws_ssm_document" "reboot_and_scan_windows" {
  name            = local.document_names.reboot_and_scan_windows
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/reboot-and-scan-windows.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
  })
}

# 次の定期ウィンドウを待たず、今すぐInstallしたいとき用。承認リストへの追記(任意)とInstallを
# 1回の実行にまとめている。承認する人と実行する人が同じ想定のため、aws:approveのような
# 人の承認クリックは挟まない(IAM権限を持つ人が実行できること自体が唯一の制御)。
# ゲートチェックも行わない(人が直接判断して実行するため)。RHEL/Windows両対応。
resource "aws_ssm_document" "install_now" {
  name            = local.document_names.install_now
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/install-now.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
    patch_groups        = sort(concat(values(local.patch_groups), values(local.patch_groups_windows)))
    patch_group_os      = local.install_now_patch_group_os
  })
}
