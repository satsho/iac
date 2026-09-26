resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "cognito"

  jwt_configuration {
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    audience = [aws_cognito_user_pool_client.demo_api.id]
  }
}

# VPC Linkが使うENIをVPC内に作成する(パブリックサブネットでもよい、
# ENI自体がインターネットに出る必要はない)。
resource "aws_apigatewayv2_vpc_link" "main" {
  name               = "${var.project_name}-vpc-link"
  security_group_ids = [aws_security_group.vpc_link.id]
  subnet_ids         = values(module.network.public_subnet_ids)
}

# HTTP_PROXY + VPC_LINKの場合、integration_uriはALBの「リスナー」ARNを
# 指定する(ターゲットグループではない)。8081番の内部限定リスナー経由で
# demo-nginxのターゲットグループに転送される。
resource "aws_apigatewayv2_integration" "demo" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.main.id
  integration_uri    = aws_lb_listener.api_internal.arn
}

resource "aws_apigatewayv2_route" "demo" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /demo"
  target             = "integrations/${aws_apigatewayv2_integration.demo.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}
