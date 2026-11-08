locals {
  # IAMポリシー(起動できるRunbookの限定)からも参照するので、リソース属性ではなく名前で持つ
  document_names = {
    gated_patch             = "${local.name}-GatedPatchBaseline"
    reboot_and_scan         = "${local.name}-RebootAndScan"
    reboot_and_scan_windows = "${local.name}-RebootAndScanWindows"
    install_now             = "${local.name}-InstallNow"
    # ダッシュボード用の集計(1時間ごと)。結果の通知は不要なのでEventBridgeの通知対象からは外す
    collect_compliance = "${local.name}-CollectPatchCompliance"
  }
}

# メンテナンスウィンドウ(stg/prod)から呼ばれる。前段ステージの成功を確認してからパッチを適用する。
resource "aws_ssm_document" "gated_patch" {
  name            = local.document_names.gated_patch
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/gated-patch-baseline.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
  })
}

# 手動再起動パターン用。運用者が好きなタイミングで実行し、再起動後にスキャンしてコンプライアンスを更新する。
resource "aws_ssm_document" "reboot_and_scan" {
  name            = local.document_names.reboot_and_scan
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/reboot-and-scan.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
  })
}

# reboot_and_scanのWindows版(AWS-RunShellScriptではなくAWS-RunPowerShellScriptを使う)。
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
# ゲートチェックも行わない(人が直接判断して実行するため)。
resource "aws_ssm_document" "install_now" {
  name            = local.document_names.install_now
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/install-now.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
    patch_groups        = sort(values(local.patch_groups))
  })
}
