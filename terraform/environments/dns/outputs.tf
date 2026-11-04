output "zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "name_servers" {
  value = aws_route53_zone.main.name_servers
}

output "cert_manager_access_key_id" {
  value = aws_iam_access_key.cert_manager.id
}

output "cert_manager_secret_access_key" {
  value     = aws_iam_access_key.cert_manager.secret
  sensitive = true
}

output "ssm_hybrid_activation_role_name" {
  description = "aws ssm create-activation --iam-role に渡すロール名"
  value       = aws_iam_role.ssm_hybrid_activation.name
}
