variable "aws_region" {
  description = "リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "リソース名のプレフィックス。既存のTerraformの命名規則に合わせて変更すること"
  type        = string
  default     = "patch-mgmt"
}

variable "timezone" {
  description = "メンテナンスウィンドウのスケジュールを解釈するタイムゾーン"
  type        = string
  default     = "Asia/Tokyo"
}

# ---------------------------------------------------------------------------
# Patch Manager
# ---------------------------------------------------------------------------

variable "patch_baselines" {
  description = <<-EOT
    環境ごとのRHEL用パッチベースライン。キーがパッチグループ名(rhel10-<キー>)になる。
    対象インスタンスのPatchGroupタグをこの値に一致させること(例: PatchGroup=rhel10-stg)。
    承認方式はどちらか一方を指定する:
      approve_after_days : アドバイザリの日付から N 日経ったパッチを自動承認(0〜360)
      approve_until_date : この日付(YYYY-MM-DD)以前のパッチだけを承認(「stgで検証した日付」まで、のように使う)
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
    tst = { approve_after_days = 0 }
    stg = { approve_after_days = 1 }
    prd = { approve_after_days = 2 }
  }

  validation {
    condition     = alltrue([for b in values(var.patch_baselines) : (b.approve_after_days == null) != (b.approve_until_date == null)])
    error_message = "approve_after_days と approve_until_date はどちらか一方だけを指定してください。"
  }
}

variable "windows_patch_baselines" {
  description = <<-EOT
    patch_baselinesのWindows Server 2025版。キーがパッチグループ名(win2025-<キー>)になる。
    RHELとは分類・深刻度のフィルタキーが異なる(CLASSIFICATION: CriticalUpdates/
    SecurityUpdates等、MSRC_SEVERITY: Critical/Important/Moderate/Low。SEVERITYという
    キーはWindowsには無い)。承認方式・approved_patches/rejected_patchesの考え方はRHELと同じ
    (ただしWindowsはKB番号で指定する。例: KB5099999)。
  EOT
  type = map(object({
    approve_after_days = optional(number)
    approve_until_date = optional(string)
    classifications    = optional(list(string), ["CriticalUpdates", "SecurityUpdates"])
    severities         = optional(list(string), ["Critical", "Important", "Moderate", "Low"])
    approved_patches   = optional(list(string), [])
    rejected_patches   = optional(list(string), [])
  }))
  default = {
    tst = { approve_after_days = 0 }
    stg = { approve_after_days = 1 }
    prd = { approve_after_days = 2 }
  }

  validation {
    condition     = alltrue([for b in values(var.windows_patch_baselines) : (b.approve_after_days == null) != (b.approve_until_date == null)])
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
                      例: { Env = ["prd"], App = ["app-a", "app-b"] } → Env=prd かつ App が app-a か app-b
    task_type       : RUN_COMMAND(AWS-RunPatchBaselineを直接実行) / AUTOMATION(ゲート付きRunbookを実行)
    reboot_option   : RebootIfNeeded(自動再起動) / NoReboot(再起動は手動)
    gate            : AUTOMATIONのみ。前段ステージのウィンドウが直近 max_age_hours 以内に成功しており、
                      前段パッチグループに失敗・再起動待ちが残っていなければ実行する
    change_calendars: AUTOMATIONのみ。指定した変更カレンダー(AWSコンソールの「変更カレンダー」画面で
                      作成・編集する運用)が1つでもCLOSEDなら実行しない。省略すれば確認しない
  EOT
  type = map(object({
    description      = string
    schedule         = string
    duration_hours   = optional(number, 3)
    cutoff_hours     = optional(number, 1)
    enabled          = optional(bool, true)
    target_tags      = map(list(string))
    task_type        = string
    reboot_option    = optional(string, "RebootIfNeeded")
    max_concurrency  = optional(string, "1")
    max_errors       = optional(string, "0")
    change_calendars = optional(list(string))
    gate = optional(object({
      windows       = list(string)
      patch_groups  = list(string)
      max_age_hours = optional(number, 72)
    }))
  }))
  default = {
    # RHEL(週次)
    tst-weekly = {
      description   = "tst: 毎週火曜 02:00。承認0日、自動再起動"
      schedule      = "cron(0 2 ? * TUE *)"
      target_tags   = { Env = ["tst"], RebootPolicy = ["auto"] }
      task_type     = "AUTOMATION" # ゲートは無いが、変更カレンダーチェックのためAUTOMATIONを使う
      reboot_option = "RebootIfNeeded"
    }
    stg-weekly = {
      description   = "stg: 毎週水曜 02:00(tstの1日後)。承認1日、tstの成功が前提、自動再起動"
      schedule      = "cron(0 2 ? * WED *)"
      target_tags   = { Env = ["stg"], RebootPolicy = ["auto"] }
      task_type     = "AUTOMATION"
      reboot_option = "RebootIfNeeded"
      gate = {
        windows       = ["tst-weekly"]
        patch_groups  = ["rhel10-tst"]
        max_age_hours = 48
      }
    }
    prd-weekly = {
      description   = "prd: 毎週金曜 02:00(stgの2日後)。承認2日、stgの成功が前提、再起動は手動"
      schedule      = "cron(0 2 ? * FRI *)"
      target_tags   = { Env = ["prd"], RebootPolicy = ["manual"] }
      task_type     = "AUTOMATION"
      reboot_option = "NoReboot"
      gate = {
        windows       = ["stg-weekly"]
        patch_groups  = ["rhel10-stg"]
        max_age_hours = 72
      }
      # 変更カレンダーで止めたい場合はコメントを外す(先にAWSコンソールで
      # 同名のカレンダーを作成し、OPEN/CLOSEDを運用してから有効にすること。
      # 存在しないカレンダー名を指定するとRunbookがエラーで止まり、patchが一切当たらなくなる)
      # change_calendars = ["prd-change-freeze"]
    }
    # Windows(Patch Tuesday起点の月次サイクル。RHELの週次とは別系統)
    tst-monthly-win = {
      description   = "Windows tst: 第3火曜 02:00(Patch Tuesday=第2火曜の1週間後)。承認0日、自動再起動"
      schedule      = "cron(0 2 ? * TUE#3 *)"
      target_tags   = { Env = ["tst"], Os = ["Windows-2025"], RebootPolicy = ["auto"] }
      task_type     = "AUTOMATION"
      reboot_option = "RebootIfNeeded"
    }
    stg-monthly-win = {
      description   = "Windows stg: 第4火曜 02:00(tstの1週間後)。承認1日、tstの成功が前提、自動再起動"
      schedule      = "cron(0 2 ? * TUE#4 *)"
      target_tags   = { Env = ["stg"], Os = ["Windows-2025"], RebootPolicy = ["auto"] }
      task_type     = "AUTOMATION"
      reboot_option = "RebootIfNeeded"
      gate = {
        windows       = ["tst-monthly-win"]
        patch_groups  = ["win2025-tst"]
        max_age_hours = 240 # 月次サイクルなので週次より余裕を持たせる(約10日)
      }
    }
    prd-monthly-win = {
      description   = "Windows prd: 翌月第1火曜 02:00。承認2日、stgの成功が前提、再起動は手動"
      schedule      = "cron(0 2 ? * TUE#1 *)"
      target_tags   = { Env = ["prd"], Os = ["Windows-2025"], RebootPolicy = ["manual"] }
      task_type     = "AUTOMATION"
      reboot_option = "NoReboot"
      gate = {
        windows       = ["stg-monthly-win"]
        patch_groups  = ["win2025-stg"]
        max_age_hours = 336 # 月によってstg(第4火曜)から翌月第1火曜までの間隔が変わるため、最長ケース(約14日)に余裕を持たせる
      }
      # prd-weeklyと同じカレンダーで止めたい場合はコメントを外す(有効化の前提条件は同上)
      # change_calendars = ["prd-change-freeze"]
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

  validation {
    condition     = alltrue([for w in values(var.maintenance_windows) : w.change_calendars == null || w.task_type == "AUTOMATION"])
    error_message = "change_calendars は task_type = AUTOMATION のウィンドウでのみ使えます。"
  }
}

# ---------------------------------------------------------------------------
# 通知・承認
# ---------------------------------------------------------------------------

variable "notification_email" {
  description = "パッチ結果の通知を受け取るメールアドレス。空なら購読を作らない(作成後に届く確認メールのリンクを踏む必要がある)"
  type        = string
  default     = ""
}
