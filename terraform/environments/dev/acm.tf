# Route53ゾーンはenvironments/dns側のstateで管理しているため、
# zone_idはremote_stateデータソース経由で参照する(このstateからは作成しない)。
data "terraform_remote_state" "dns" {
  backend = "s3"

  config = {
    bucket = "satsho-iac-tfstate"
    key    = "dns/terraform.tfstate"
    region = var.aws_region
  }
}

resource "aws_acm_certificate" "web" {
  domain_name = var.domain_name
  # subject_alternative_namesはProvider側でComputed属性のため、この引数自体を
  # 省略すると「値の決定をProviderに委ねる」扱いになり、以前keycloakのSANを
  # 追加した際の値が残ったまま差分が検知されない。明示的に空リストを指定して
  # 確実にSANなしの状態へ収束させる。
  subject_alternative_names = []
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-web-cert"
  }
}

resource "aws_route53_record" "web_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.web.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.terraform_remote_state.dns.outputs.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "web" {
  certificate_arn         = aws_acm_certificate.web.arn
  validation_record_fqdns = [for r in aws_route53_record.web_cert_validation : r.fqdn]
}

# ALBの公開名(iac-poc-web-alb-xxxx.elb.amazonaws.com)ではなく
# 独自ドメインでアクセスできるようにするエイリアスレコード。
resource "aws_route53_record" "web_alias" {
  zone_id = data.terraform_remote_state.dns.outputs.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.web.dns_name
    zone_id                = aws_lb.web.zone_id
    evaluate_target_health = true
  }
}
