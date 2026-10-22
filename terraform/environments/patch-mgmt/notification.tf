# Run Command(AWS-RunPatchBaseline 等)の出力先。どのパッケージが入ったかの証跡として残す。
resource "aws_cloudwatch_log_group" "patch" {
  name              = "/${local.name}/run-command"
  retention_in_days = 30
}

# aws:approve(Runbookの承認ステップ)の通知先にするSNSトピックは、名前が "Automation" で
# 始まっている必要がある(AWS側の制約)。承認依頼とEventBridgeからの結果通知を同じトピックに流す。
resource "aws_sns_topic" "patch" {
  name = "Automation-${local.name}"
}

resource "aws_sns_topic_policy" "patch" {
  arn = aws_sns_topic.patch.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridge"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.patch.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.notification_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.patch.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ---------------------------------------------------------------------------
# EventBridge: パッチ適用の成功・失敗をSNSに通知する
# ---------------------------------------------------------------------------

locals {
  event_notifications = {
    # メンテナンスウィンドウ単位の結果(このスタックのウィンドウだけ)
    maintenance-window = {
      description = "Patch maintenance window finished"
      pattern = jsonencode({
        source        = ["aws.ssm"]
        "detail-type" = ["Maintenance Window Execution State-change Notification"]
        detail = {
          "window-id" = [for w in aws_ssm_maintenance_window.this : w.id]
          status      = ["SUCCESS", "FAILED", "TIMED_OUT", "CANCELLED"]
        }
      })
      input_paths = tomap({
        window    = "$.detail.window-id"
        execution = "$.detail.window-execution-id"
        status    = "$.detail.status"
      })
      template = "\"[${local.name}] メンテナンスウィンドウ <window> の実行 <execution> が <status> で終了しました\""
    }
    # Runbook単位の結果(ゲートで止まった、緊急パッチが終わった、手動再起動が終わった等)
    automation = {
      description = "Patch runbook finished"
      pattern = jsonencode({
        source        = ["aws.ssm"]
        "detail-type" = ["EC2 Automation Execution Status-change Notification"]
        detail = {
          Definition = values(local.document_names)
          Status     = ["Success", "Failed", "TimedOut", "Cancelled"]
        }
      })
      input_paths = tomap({
        runbook   = "$.detail.Definition"
        execution = "$.detail.ExecutionId"
        status    = "$.detail.Status"
      })
      template = "\"[${local.name}] Runbook <runbook> の実行 <execution> が <status> で終了しました\""
    }
    # スキャン/インストールの結果、インスタンスがパッチ非準拠になった(状態が変わった時だけ発火する)
    patch-compliance = {
      description = "Instance became non-compliant for patches"
      pattern = jsonencode({
        source        = ["aws.ssm"]
        "detail-type" = ["Configuration Compliance State Change"]
        detail = {
          "compliance-type"   = ["Patch"]
          "compliance-status" = ["non_compliant"]
        }
      })
      input_paths = tomap({
        instance = "$.detail.resource-id"
        baseline = "$.detail.patch-baseline-id"
      })
      template = "\"[${local.name}] <instance> がパッチ非準拠になりました(ベースライン <baseline>)\""
    }
  }
}

resource "aws_cloudwatch_event_rule" "patch" {
  for_each = local.event_notifications

  name          = "${local.name}-${each.key}"
  description   = each.value.description
  event_pattern = each.value.pattern
}

resource "aws_cloudwatch_event_target" "patch" {
  for_each = local.event_notifications

  rule = aws_cloudwatch_event_rule.patch[each.key].name
  arn  = aws_sns_topic.patch.arn

  input_transformer {
    input_paths    = each.value.input_paths
    input_template = each.value.template
  }
}
