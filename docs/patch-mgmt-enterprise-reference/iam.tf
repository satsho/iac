data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-patch"
}

# ---------------------------------------------------------------------------
# メンテナンスウィンドウ / Automation(Runbook)用
#
# 対象EC2フリート自体のSSM通信用の権限(AmazonSSMManagedInstanceCore)は、
# 既存のインスタンスプロファイルロールに付与済みであることを前提とし、ここでは作らない。
# このファイルで作るのは「誰が・何を実行できるか」を集約する、メンテナンスウィンドウの
# サービスロール兼Runbookの実行ロール(AutomationAssumeRole)だけ。
#
# 社内の「EC2はAssumeRoleのみ→強い権限のロールに切り替える」というIAM方針とは別軸の
# 権限であり競合しない。これはあくまでSSMサービス(ssm.amazonaws.com)がAssumeRoleする
# 相手であり、EC2インスタンス自体が引き受けるロールではない。
# ---------------------------------------------------------------------------

resource "aws_iam_role" "patch_automation" {
  name = "${local.name}-automation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "patch_automation" {
  name = "patch-automation"
  role = aws_iam_role.patch_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 実行できるコマンドはパッチ適用と(手動再起動Runbook用の)シェル/PowerShellだけに絞る
        Sid    = "RunPatchCommands"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunPatchBaseline",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunPowerShellScript",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:managed-instance/*",
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
        ]
      },
      {
        # ゲートチェック(前段ステージの成否確認)と、コマンドの進捗確認に使う読み取り系
        Sid    = "ReadPatchAndCommandState"
        Effect = "Allow"
        Action = [
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation",
          "ssm:CancelCommand",
          "ssm:DescribeInstanceInformation",
          "ssm:DescribeInstancePatchStates",
          "ssm:DescribeInstancePatchStatesForPatchGroup",
          "ssm:DescribeInstancePatches",
          "ssm:DescribeMaintenanceWindowExecutions",
          "ssm:GetAutomationExecution",
          "ssm:ListTagsForResource",
          "ssm:GetCalendarState",
        ]
        Resource = "*"
      },
      {
        # install-now(早く当てたい/緊急時)が、承認リストへ個別に追記するための権限
        Sid    = "UpdateApprovedPatches"
        Effect = "Allow"
        Action = [
          "ssm:GetPatchBaseline",
          "ssm:GetPatchBaselineForPatchGroup",
          "ssm:UpdatePatchBaseline",
        ]
        Resource = "*"
      },
      {
        Sid      = "WriteCommandOutputLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.patch.arn}:*"
      },
      {
        # メンテナンスウィンドウのAUTOMATIONタスクから、このスタックのRunbookだけを起動できる。
        # 実際の認可はdocument/とautomation-execution/のARNに対しても行われるので、
        # automation-definition/だけでは拒否される。起動できるRunbookはdocument/の指定で絞られる。
        Sid    = "StartPatchRunbooks"
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = concat(
          flatten([
            for doc in values(local.document_names) : [
              "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${doc}:*",
              "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/${doc}",
            ]
          ]),
          ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-execution/*"],
        )
      },
      {
        Sid      = "PassSelfToAutomation"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-automation-role"
        Condition = {
          StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# InstallNow/RebootAndScanを手動実行する運用者向けの権限は、ここでは作らない。
# 社内の既存パターン(terraform-ec2-role → terraform-work-role へのAssumeRole)に合わせ、
# terraform-work-role(または同等の強い権限ロール)側に、下記のようなステートメントを
# 追記する形で付与すること:
#   {
#     "Effect": "Allow",
#     "Action": "ssm:StartAutomationExecution",
#     "Resource": [
#       "arn:aws:ssm:<region>:<account>:document/<project_name>-patch-InstallNow",
#       "arn:aws:ssm:<region>:<account>:document/<project_name>-patch-RebootAndScanRhel",
#       "arn:aws:ssm:<region>:<account>:document/<project_name>-patch-RebootAndScanWindows",
#       "arn:aws:ssm:<region>:<account>:automation-execution/*"
#     ]
#   },
#   {
#     "Effect": "Allow",
#     "Action": "iam:PassRole",
#     "Resource": "<aws_iam_role.patch_automation.arn>",
#     "Condition": { "StringEquals": { "iam:PassedToService": "ssm.amazonaws.com" } }
#   }
# ---------------------------------------------------------------------------
