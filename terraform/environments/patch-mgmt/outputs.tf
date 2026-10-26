output "hybrid_node_role_name" {
  description = "VMのHybrid Activationに使うIAMロール名(ansible/patch-mgmt/vars.yml の ssm_hybrid_role に設定する)"
  value       = aws_iam_role.hybrid_node.name
}

output "patch_baseline_ids" {
  description = "パッチグループ名 => パッチベースラインID"
  value       = { for k, b in aws_ssm_patch_baseline.rhel : local.patch_groups[k] => b.id }
}

output "maintenance_window_ids" {
  value = { for k, w in aws_ssm_maintenance_window.this : k => w.id }
}

output "runbook_names" {
  value = local.document_names
}

output "automation_role_arn" {
  description = "Runbookを手動実行するときのAutomationAssumeRole(Runbookのデフォルト値にも設定済み)"
  value       = aws_iam_role.patch_automation.arn
}

output "notification_topic_arn" {
  value = aws_sns_topic.patch.arn
}

output "command_log_group" {
  value = aws_cloudwatch_log_group.patch.name
}

output "dashboard_urls" {
  description = "パッチ適用状況のダッシュボード"
  value = {
    for k, d in { status = aws_cloudwatch_dashboard.status, history = aws_cloudwatch_dashboard.history } :
    k => "${local.console_base}/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${d.dashboard_name}"
  }
}
