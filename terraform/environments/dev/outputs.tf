output "vpc_id" {
  value = module.network.vpc_id
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "instance_id" {
  value = aws_instance.k3s.id
}

output "alb_dns_name" {
  value = aws_lb.web.dns_name
}

output "web_url" {
  value = "https://${var.domain_name}"
}

output "api_gateway_url" {
  value = "${aws_apigatewayv2_stage.default.invoke_url}demo"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.demo_api.id
}
