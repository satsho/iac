output "vpc_id" {
  value = aws_vpc.this.id
}

output "instance_ids" {
  description = "インスタンス名 => インスタンスID"
  value = merge(
    { for k, i in aws_instance.mirror : k => i.id },
    { for k, i in aws_instance.workload : k => i.id },
  )
}

output "repository_ip" {
  value = local.repository_ip
}

output "infra_mirror_url" {
  description = "業務サーバが参照するミラーのURL"
  value       = "http://${local.infra_ip}/repos/rhel/${local.release_dir}/"
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
