output "patch_automation_role_arn" {
  description = "メンテナンスウィンドウ/Runbookの実行ロール(AutomationAssumeRole)。terraform-work-role側にssm:StartAutomationExecutionのiam:PassRole先として設定する"
  value       = aws_iam_role.patch_automation.arn
}

output "rhel_patch_baseline_ids" {
  description = "環境ごとのRHELパッチベースラインID"
  value       = { for k, b in aws_ssm_patch_baseline.rhel : k => b.id }
}

output "windows_patch_baseline_ids" {
  description = "環境ごとのWindowsパッチベースラインID"
  value       = { for k, b in aws_ssm_patch_baseline.windows : k => b.id }
}

output "maintenance_window_ids" {
  description = "メンテナンスウィンドウID一覧"
  value       = { for k, w in aws_ssm_maintenance_window.this : k => w.id }
}

output "install_now_document_name" {
  description = "手動実行(InstallNow)Automationドキュメント名。aws ssm start-automation-executionの--document-nameに指定する"
  value       = aws_ssm_document.install_now.name
}

output "reboot_and_scan_document_names" {
  description = "手動再起動(RebootAndScan)AutomationドキュメントのOS別の名前"
  value = {
    rhel    = aws_ssm_document.reboot_and_scan_rhel.name
    windows = aws_ssm_document.reboot_and_scan_windows.name
  }
}

output "notification_topic_arn" {
  description = "パッチ結果通知のSNSトピックARN"
  value       = aws_sns_topic.patch.arn
}
