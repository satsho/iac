# API Gatewayの認証はKeycloak(セルフホスト)ではなくCognitoに一元化した。
# 理由: API GatewayのJWTオーソライザーはissuerのJWKS(公開鍵)にAWS側から
# 直接アクセスする(VPC/Tailscale経由ではない)ため、Tailscale限定でしか
# 到達できないセルフホストIdPでは検証できない。CognitoはAWS内部サービス
# なので常に到達可能で、この問題がそもそも発生しない。
resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-user-pool"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }

  tags = {
    Name = "${var.project_name}-user-pool"
  }
}

resource "aws_cognito_user_pool_client" "demo_api" {
  name         = "${var.project_name}-demo-api-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # CLIから直接ユーザー名/パスワードでトークンを取得して動作確認するため、
  # OAuthのホストされたUI(リダイレクトフロー)は使わずADMIN_NO_SRP_AUTH系を使う。
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # public client(SPA/CLI用)なのでシークレットは発行しない。
  generate_secret = false
}
