# パッチ適用状況・CVE・メンテナンスウィンドウの結果を見るCloudWatchダッシュボード。
#   status  : いまの状態(VMごとの準拠状況、未適用パッチとCVE)。既定の表示範囲は直近1時間
#   history : 推移と実行履歴(環境ごとの未適用パッチ数、ウィンドウ・Runbookの結果)。既定は直近2週間
# データはCollectPatchCompliance Runbookが1時間ごとに書き出す(EventBridge Scheduler)。

locals {
  metric_namespace = "${var.project_name}/PatchManagement"

  # 表示順は test → stg → prod → その他
  dashboard_envs = concat(
    [for env in ["test", "stg", "prod"] : env if contains(keys(var.patch_baselines), env)],
    [for env in sort(keys(var.patch_baselines)) : env if !contains(["test", "stg", "prod"], env)],
  )

  compliance_source = "SOURCE '${aws_cloudwatch_log_group.compliance.name}'"
  events_source     = "SOURCE '${aws_cloudwatch_log_group.events.name}'"
  console_base      = "https://${var.aws_region}.console.aws.amazon.com"
}

# ---------------------------------------------------------------------------
# データの置き場所
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "compliance" {
  name              = "/${local.name}/compliance"
  retention_in_days = 30
}

# EventBridgeが拾ったウィンドウ・Runbook・コンプライアンスのイベントをそのまま残す(実行履歴の表に使う)
resource "aws_cloudwatch_log_group" "events" {
  name              = "/${local.name}/events"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_resource_policy" "events" {
  policy_name = "${local.name}-eventbridge-to-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"] }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${aws_cloudwatch_log_group.events.arn}:*"
    }]
  })
}

resource "aws_cloudwatch_event_target" "patch_log" {
  for_each = local.event_notifications

  rule = aws_cloudwatch_event_rule.patch[each.key].name
  arn  = aws_cloudwatch_log_group.events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.events]
}

# ---------------------------------------------------------------------------
# 収集(1時間ごと)
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "collect_compliance" {
  name            = local.document_names.collect_compliance
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/documents/collect-patch-compliance.yaml", {
    automation_role_arn = aws_iam_role.patch_automation.arn
    patch_groups        = join(",", values(local.patch_groups))
    log_group_name      = aws_cloudwatch_log_group.compliance.name
    metric_namespace    = local.metric_namespace
  })
}

resource "aws_iam_role" "scheduler" {
  name = "${local.name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start-collect-compliance"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartCollector"
        Effect   = "Allow"
        Action   = "ssm:StartAutomationExecution"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${local.document_names.collect_compliance}:*"
      },
      {
        Sid      = "PassAutomationRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.patch_automation.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" }
        }
      },
    ]
  })
}

# 毎時10分。スキャン(01:30)やメンテナンスウィンドウ(02:00〜)の結果も、次の回でダッシュボードに出る
resource "aws_scheduler_schedule" "collect_compliance" {
  name                         = "${local.name}-collect-compliance"
  description                  = "Collect patch compliance and CVEs for the dashboard"
  schedule_expression          = "cron(10 * * * ? *)"
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ssm:startAutomationExecution"
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ DocumentName = aws_ssm_document.collect_compliance.name })
  }
}

# ---------------------------------------------------------------------------
# ダッシュボード
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "status" {
  dashboard_name = "${local.name}-status"

  dashboard_body = jsonencode({
    start = "-PT1H"
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = join("\n", [
            "## パッチ適用状況(いまの状態)",
            "1時間ごと(毎時10分)に集計している。表示範囲は「直近1時間」のまま見る(範囲を広げると、適用済みになったパッチも古い行として残って見える)。",
            "推移とメンテナンスウィンドウの結果は [${local.name}-history](#dashboards:name=${local.name}-history)、パッチごとの詳細は [Patch Manager](${local.console_base}/systems-manager/patch-manager?region=${var.aws_region})。",
          ])
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 3
        width  = 24
        height = 7
        properties = {
          title  = "VMごとの準拠状況"
          region = var.aws_region
          view   = "table"
          query = join("\n", [
            local.compliance_source,
            "| filter record = 'node'",
            "| stats latest(compliant) as Compliant, latest(missing) as Missing, latest(failed) as Failed, latest(pending_reboot) as PendingReboot, latest(security_noncompliant) as SecurityNonCompliant, latest(installed) as Installed, latest(last_operation) as LastOperation, latest(last_operation_end) as LastOperationEnd, latest(agent) as Agent, latest(collected_at) as CollectedAt by env, name",
            "| sort env, name",
          ])
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 10
        width  = 24
        height = 10
        properties = {
          title  = "未適用・失敗・再起動待ちのパッチとCVE"
          region = var.aws_region
          view   = "table"
          query = join("\n", [
            local.compliance_source,
            "| filter record = 'patch'",
            "| stats latest(state) as State, latest(severity) as Severity, latest(classification) as Classification, latest(cves) as CVEs, latest(collected_at) as CollectedAt by env, name, title",
            "| sort Severity, env, name",
          ])
        }
      },
    ]
  })
}

resource "aws_cloudwatch_dashboard" "history" {
  dashboard_name = "${local.name}-history"

  dashboard_body = jsonencode({
    start = "-P14D"
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 4
          properties = {
            markdown = join("\n", concat(
              [
                "## パッチ適用の推移と実行履歴",
                "いまの状態は [${local.name}-status](#dashboards:name=${local.name}-status)。実行履歴の Target に出るメンテナンスウィンドウIDは次のとおり。",
                "",
                "| ウィンドウ | ID | 内容 |",
                "|---|---|---|",
              ],
              [for k, w in aws_ssm_maintenance_window.this : "| ${k} | ${w.id} | ${var.maintenance_windows[k].description} |"],
            ))
          }
        },
      ],
      [
        for i, metric in ["MissingPatches", "PendingRebootPatches", "FailedPatches"] : {
          type   = "metric"
          x      = i * 8
          y      = 4
          width  = 8
          height = 6
          properties = {
            title   = { MissingPatches = "未適用パッチ数(環境別)", PendingRebootPatches = "再起動待ちパッチ数(環境別)", FailedPatches = "適用失敗パッチ数(環境別)" }[metric]
            region  = var.aws_region
            view    = "timeSeries"
            stat    = "Maximum"
            period  = 3600
            metrics = [for env in local.dashboard_envs : [local.metric_namespace, metric, "Env", env]]
          }
        }
      ],
      [
        {
          type   = "log"
          x      = 0
          y      = 10
          width  = 24
          height = 9
          properties = {
            title  = "メンテナンスウィンドウ・Runbook・コンプライアンスのイベント"
            region = var.aws_region
            view   = "table"
            query = join("\n", [
              local.events_source,
              "| fields @timestamp, `detail-type` as Event, coalesce(`detail.window-id`, detail.Definition, `detail.resource-id`) as Target, coalesce(detail.status, detail.Status, `detail.compliance-status`) as Status, coalesce(`detail.window-execution-id`, detail.ExecutionId, `detail.patch-baseline-id`) as Detail",
              "| sort @timestamp desc",
              "| limit 200",
            ])
          }
        },
      ],
    )
  })
}
