data "aws_caller_identity" "current" {}

locals {
  name = "${var.project_name}-patch"
}

# ---------------------------------------------------------------------------
# KVM上のVM用(SSM Hybrid Activation)
# ---------------------------------------------------------------------------

# Hybrid Activationで登録したVM(mi-で始まるマネージドノード)が引き受けるロール。
# 家のサーバ本体用の既存ロール(environments/dnsのssm-hybrid-activation、Route53等の
# 権限付き)とは分けて、パッチ検証のVMにはSSMとログ出力の権限だけを持たせる。
# アクティベーション自体はVMを作るたびにAnsible(ansible/patch-mgmt)が作成する。
resource "aws_iam_role" "hybrid_node" {
  name = "${local.name}-hybrid-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnEquals    = { "aws:SourceArn" = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

# Fleet Manager / Run Command / Patch Manager に必要な最小セット
resource "aws_iam_role_policy_attachment" "hybrid_node_ssm" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Run Commandの出力をCloudWatch Logsへ書き込むのはVM上のSSM Agentなので、
# ノード側のロールにロググループへの書き込み権限が要る。
resource "aws_iam_role_policy" "hybrid_node_command_logs" {
  name = "run-command-output-logs"
  role = aws_iam_role.hybrid_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteCommandOutput"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.patch.arn}:*"
      },
      {
        Sid      = "DescribeLogGroups"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# メンテナンスウィンドウ / Automation(Runbook)用
# ---------------------------------------------------------------------------

# メンテナンスウィンドウのサービスロールと、Runbookの実行ロール(AutomationAssumeRole)を兼ねる。
# 「誰が・何を実行できるか」をこのロール1つに集約しておくと、CloudTrailでの追跡も楽になる。
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
        # 実行できるコマンドはパッチ適用と(手動再起動Runbook用の)シェルだけに絞る
        Sid    = "RunPatchCommands"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunPatchBaseline",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:managed-instance/*",
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
          "ssm:DescribeMaintenanceWindowExecutions",
          "ssm:GetAutomationExecution",
        ]
        Resource = "*"
      },
      {
        # メンテナンスウィンドウのAUTOMATIONタスクから、このスタックのRunbookだけを起動できる
        Sid    = "StartPatchRunbooks"
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          for doc in values(local.document_names) :
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:automation-definition/${doc}:*"
        ]
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
      {
        # 緊急パッチRunbookの承認依頼(aws:approve)の通知
        Sid      = "NotifyApprovers"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.patch.arn
      },
    ]
  })
}
