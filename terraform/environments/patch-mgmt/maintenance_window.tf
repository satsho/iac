locals {
  run_command_windows = { for k, w in var.maintenance_windows : k => w if w.task_type == "RUN_COMMAND" }
  automation_windows  = { for k, w in var.maintenance_windows : k => w if w.task_type == "AUTOMATION" }

  # AUTOMATIONタスクからゲート付きRunbookに渡すパラメータ。
  # {{RESOURCE_ID}} はメンテナンスウィンドウがターゲットのインスタンスIDに置き換える。
  automation_task_parameters = {
    for k, w in local.automation_windows : k => merge(
      {
        InstanceId           = ["{{RESOURCE_ID}}"]
        AutomationAssumeRole = [aws_iam_role.patch_automation.arn]
        RebootOption         = [w.reboot_option]
      },
      w.gate == null ? {} : {
        GateWindowIds   = [join(",", [for name in w.gate.windows : aws_ssm_maintenance_window.this[name].id])]
        GatePatchGroups = [join(",", w.gate.patch_groups)]
        GateMaxAgeHours = [tostring(w.gate.max_age_hours)]
      },
    )
  }
}

resource "aws_ssm_maintenance_window" "this" {
  for_each = var.maintenance_windows

  name              = "${local.name}-${each.key}"
  description       = each.value.description
  schedule          = each.value.schedule
  schedule_timezone = var.timezone
  duration          = each.value.duration_hours
  cutoff            = each.value.cutoff_hours
  enabled           = each.value.enabled

  # ターゲットとして登録したインスタンス以外では実行させない
  allow_unassociated_targets = false
}

resource "aws_ssm_maintenance_window_target" "this" {
  for_each = var.maintenance_windows

  window_id     = aws_ssm_maintenance_window.this[each.key].id
  name          = each.key
  description   = substr("Instances matching all of: ${join(", ", [for k, v in each.value.target_tags : "${k}=${join("|", v)}"])}", 0, 128)
  resource_type = "INSTANCE"

  # targetsブロックを複数書くとAND条件になる(値のリストはOR条件)
  dynamic "targets" {
    for_each = each.value.target_tags
    content {
      key    = "tag:${targets.key}"
      values = targets.value
    }
  }
}

# RUN_COMMAND: AWS-RunPatchBaseline をそのまま実行する。前後処理が要らない環境向け。
resource "aws_ssm_maintenance_window_task" "run_command" {
  for_each = local.run_command_windows

  window_id        = aws_ssm_maintenance_window.this[each.key].id
  name             = "run-patch-baseline"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  priority         = 1
  service_role_arn = aws_iam_role.patch_automation.arn
  max_concurrency  = each.value.max_concurrency
  max_errors       = each.value.max_errors

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.this[each.key].id]
  }

  task_invocation_parameters {
    run_command_parameters {
      cloudwatch_config {
        cloudwatch_log_group_name = aws_cloudwatch_log_group.patch.name
        cloudwatch_output_enabled = true
      }

      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      parameter {
        name   = "RebootOption"
        values = [each.value.reboot_option]
      }
    }
  }
}

# AUTOMATION: ゲート付きRunbookを、ターゲットのインスタンスごとに起動する。
resource "aws_ssm_maintenance_window_task" "automation" {
  for_each = local.automation_windows

  window_id        = aws_ssm_maintenance_window.this[each.key].id
  name             = "gated-patch-baseline"
  task_type        = "AUTOMATION"
  task_arn         = aws_ssm_document.gated_patch.name
  priority         = 1
  service_role_arn = aws_iam_role.patch_automation.arn
  max_concurrency  = each.value.max_concurrency
  max_errors       = each.value.max_errors

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.this[each.key].id]
  }

  task_invocation_parameters {
    automation_parameters {
      document_version = "$DEFAULT"

      dynamic "parameter" {
        for_each = local.automation_task_parameters[each.key]
        content {
          name   = parameter.key
          values = parameter.value
        }
      }
    }
  }
}
