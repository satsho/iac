locals {
  # IAMポリシー(起動できるRunbookの限定)からも参照するので、リソース属性ではなく名前で持つ
  document_names = {
    gated_patch     = "${local.name}-GatedPatchBaseline"
    reboot_and_scan = "${local.name}-RebootAndScan"
    emergency_patch = "${local.name}-EmergencyPatch"
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

# 緊急パッチ用。承認者の承認(aws:approve)を経てから、タグで指定したサーバ群にパッチを適用する。
resource "aws_ssm_document" "emergency_patch" {
  name            = local.document_names.emergency_patch
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/emergency-patch.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    log_group_name      = aws_cloudwatch_log_group.patch.name
    topic_arn           = aws_sns_topic.patch.arn
    approvers           = var.emergency_approvers
  })
}
