variable "aws_region" {
  description = "リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "リソース名のプレフィックス"
  type        = string
  default     = "iac-poc"
}

variable "timezone" {
  description = "メンテナンスウィンドウのスケジュールを解釈するタイムゾーン(VM側のタイムゾーンはansible/patch-mgmt/vars.ymlで設定)"
  type        = string
  default     = "Asia/Tokyo"
}

# ---------------------------------------------------------------------------
# Patch Manager
# ---------------------------------------------------------------------------

variable "patch_baselines" {
  description = <<-EOT
    環境ごとのパッチベースライン。キーがパッチグループ名(rhel10-<キー>)になる。
    VMのPatchGroupタグ(ansible/patch-mgmt/vars.yml)と一致させること。
    承認方式はどちらか一方を指定する:
      approve_after_days : アドバイザリの日付から N 日経ったパッチを自動承認(0〜360)
      approve_until_date : この日付(YYYY-MM-DD)以前のパッチだけを承認(「testで検証した日付」まで、のように使う)
    approved_patches / rejected_patches には RHSA-2026:1234 のようなアドバイザリIDやCVE ID、パッケージ名を書ける。
  EOT
  type = map(object({
    approve_after_days = optional(number)
    approve_until_date = optional(string)
    classifications    = optional(list(string), ["Security"])
    severities         = optional(list(string), ["Critical", "Important", "Moderate", "Low"])
    approved_patches   = optional(list(string), [])
    rejected_patches   = optional(list(string), [])
  }))
  default = {
    test = { approve_after_days = 0 }
    stg  = { approve_after_days = 1 }
    prod = { approve_after_days = 2 }
    # repository/infra用。スキャン(可視化)だけでインストールのウィンドウは置いていない
    mgmt = { approve_after_days = 0 }
  }

  validation {
    condition     = alltrue([for b in values(var.patch_baselines) : (b.approve_after_days == null) != (b.approve_until_date == null)])
    error_message = "approve_after_days と approve_until_date はどちらか一方だけを指定してください。"
  }
}

variable "patch_scan_schedule" {
  description = "全サーバのパッチスキャン(State Managerの関連付け)のスケジュール。関連付けのcron式はUTC固定なので注意(デフォルトはJST 01:30)"
  type        = string
  default     = "cron(30 16 * * ? *)"
}

variable "maintenance_windows" {
  description = <<-EOT
    パッチ適用(Install)のメンテナンスウィンドウ。キーがウィンドウ名になる。
    schedule        : cron(分 時 日 月 曜日 年)。timezone変数のタイムゾーンで解釈される
    target_tags     : タグキー => 値リスト。キー同士はAND、値リスト内はOR
                      例: { Env = ["prod"], App = ["app-a", "app-b"] } → Env=prod かつ App が app-a か app-b
    task_type       : RUN_COMMAND(AWS-RunPatchBaselineを直接実行) / AUTOMATION(ゲート付きRunbookを実行)
    reboot_option   : RebootIfNeeded(自動再起動) / NoReboot(再起動は手動)
    gate            : AUTOMATIONのみ。前段ステージのウィンドウが直近 max_age_hours 以内に成功しており、
                      前段パッチグループに失敗・再起動待ちが残っていなければ実行する
  EOT
  type = map(object({
    description     = string
    schedule        = string
    duration_hours  = optional(number, 3)
    cutoff_hours    = optional(number, 1)
    enabled         = optional(bool, true)
    target_tags     = map(list(string))
    task_type       = string
    reboot_option   = optional(string, "RebootIfNeeded")
    max_concurrency = optional(string, "1")
    max_errors      = optional(string, "0")
    gate = optional(object({
      windows       = list(string)
      patch_groups  = list(string)
      max_age_hours = optional(number, 72)
    }))
  }))
  default = {
    test-weekly = {
      description   = "test: 毎週火曜 02:00。承認0日、自動再起動"
      schedule      = "cron(0 2 ? * TUE *)"
      target_tags   = { Env = ["test"], RebootPolicy = ["auto"] }
      task_type     = "RUN_COMMAND"
      reboot_option = "RebootIfNeeded"
    }
    stg-weekly = {
      description   = "stg: 毎週水曜 02:00(testの1日後)。承認1日、testの成功が前提、自動再起動"
      schedule      = "cron(0 2 ? * WED *)"
      target_tags   = { Env = ["stg"], RebootPolicy = ["auto"] }
      task_type     = "AUTOMATION"
      reboot_option = "RebootIfNeeded"
      gate = {
        windows       = ["test-weekly"]
        patch_groups  = ["rhel10-test"]
        max_age_hours = 48
      }
    }
    prod-weekly = {
      description   = "prod: 毎週金曜 02:00(stgの2日後)。承認2日、stgの成功が前提、再起動は手動"
      schedule      = "cron(0 2 ? * FRI *)"
      target_tags   = { Env = ["prod"], RebootPolicy = ["manual"] }
      task_type     = "AUTOMATION"
      reboot_option = "NoReboot"
      gate = {
        windows       = ["stg-weekly"]
        patch_groups  = ["rhel10-stg"]
        max_age_hours = 72
      }
    }
  }

  validation {
    condition     = alltrue([for w in values(var.maintenance_windows) : contains(["RUN_COMMAND", "AUTOMATION"], w.task_type)])
    error_message = "task_type は RUN_COMMAND か AUTOMATION を指定してください。"
  }

  validation {
    condition     = alltrue([for w in values(var.maintenance_windows) : contains(["RebootIfNeeded", "NoReboot"], w.reboot_option)])
    error_message = "reboot_option は RebootIfNeeded か NoReboot を指定してください。"
  }

  validation {
    condition     = alltrue([for w in values(var.maintenance_windows) : w.gate == null || w.task_type == "AUTOMATION"])
    error_message = "gate は task_type = AUTOMATION のウィンドウでのみ使えます。"
  }
}

# ---------------------------------------------------------------------------
# 通知・承認
# ---------------------------------------------------------------------------

variable "notification_email" {
  description = "パッチ結果の通知と緊急パッチの承認依頼を受け取るメールアドレス。空なら購読を作らない(作成後に届く確認メールのリンクを踏む必要がある)"
  type        = string
  default     = ""
}

variable "emergency_approvers" {
  description = "緊急パッチRunbookの承認者(IAMユーザー/ロールのARN)のデフォルト値。空の場合は実行時に指定する"
  type        = list(string)
  default     = []
}
