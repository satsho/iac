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
  description = "インスタンスのOSタイムゾーン、およびメンテナンスウィンドウ・systemd timerのスケジュールを解釈するタイムゾーン"
  type        = string
  default     = "Asia/Tokyo"
}

# ---------------------------------------------------------------------------
# ネットワーク
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC全体のCIDR"
  type        = string
  default     = "10.20.0.0/16"
}

variable "availability_zone" {
  description = "サブネットを作るAZ(検証用なので1AZ構成)"
  type        = string
  default     = "ap-northeast-1a"
}

variable "public_subnet_cidr" {
  description = "NAT Gateway専用のパブリックサブネット。EC2は置かない"
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_subnet_cidr" {
  description = "5台のEC2(repository/infra/test/stg/prod)を置くプライベートサブネット"
  type        = string
  default     = "10.20.1.0/24"
}

variable "restrict_workload_egress" {
  description = <<-EOT
    true の場合、業務サーバ(test/stg/prod)のアウトバウンドを「infraのミラー(80/tcp)」と
    「VPCエンドポイント(SSM・CloudWatch Logs・S3)」だけに絞る。RHEL 10.1以降のPAYG AMIは
    auto-registration v2 で Red Hat CDN に直接つながるため、ミラーを迂回させないためのガード。
    インターフェイスエンドポイント4つ分の時間課金がかかるので、コストを優先するなら false。
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# EC2
# ---------------------------------------------------------------------------

variable "rhel_ami_id" {
  description = <<-EOT
    RHEL 10.2 のPAYG AMI ID(Red Hat公式、AWS Marketplace / Quick Start)。
    10.1以降のAMIであること(auto-registration v2 でRed Hat CDNを使う前提のため)。
    また業務サーバのミラーはEUS 10.2なので、10.3以降のAMIを使うとダウングレード扱いになり更新できない。
    GitHub VariablesのRHEL_AMI_IDからTF_VAR_rhel_ami_idとして渡す想定。
  EOT
  type        = string
}

variable "instance_type" {
  description = "全サーバ共通のインスタンスタイプ。RHEL 10はx86-64-v3が必須なのでt2より新しい世代を使う"
  type        = string
  default     = "t3.small"
}

variable "mirror_volume_size" {
  description = "repository/infraのミラー用データボリュームのサイズ(GB)。インスタンスとは別リソースなので、作り直してもreposync済みのデータが残る"
  type        = number
  default     = 100
}

variable "workloads" {
  description = <<-EOT
    業務サーバの定義。キーがインスタンス名になる。
    env           : パッチグループ(rhel10-<env>)とメンテナンスウィンドウのターゲット(Envタグ)に使う
    app           : アプリ単位でメンテナンスウィンドウを分けるためのAppタグ
    reboot_policy : auto(パッチ適用後に自動再起動) / manual(再起動は人が行う)。RebootPolicyタグになる
  EOT
  type = map(object({
    env           = string
    app           = string
    reboot_policy = string
  }))
  default = {
    test = { env = "test", app = "sample-app", reboot_policy = "auto" }
    stg  = { env = "stg", app = "sample-app", reboot_policy = "auto" }
    prod = { env = "prod", app = "sample-app", reboot_policy = "manual" }
  }

  validation {
    condition     = alltrue([for w in values(var.workloads) : contains(["auto", "manual"], w.reboot_policy)])
    error_message = "reboot_policy は auto か manual を指定してください。"
  }
}

# ---------------------------------------------------------------------------
# リポジトリ同期
# ---------------------------------------------------------------------------

variable "rhel_release" {
  description = "repository/infraで subscription-manager release --set に渡すマイナーリリース。EUSリポジトリの$releaseverになる。空文字ならリリース固定を解除する"
  type        = string
  default     = "10.2"
}

variable "upstream_repos" {
  description = <<-EOT
    repositoryがreposyncするRed Hat CDNのリポジトリ。
    キーはミラー上のディレクトリ名(業務サーバのrepoファイルのURLにも使う)、値はCDNのリポジトリID。
    EUSが使えない契約の場合は rhel-10-for-x86_64-baseos-rpms のような非EUSのIDに切り替える。
  EOT
  type        = map(string)
  default = {
    baseos    = "rhel-10-for-x86_64-baseos-eus-rpms"
    appstream = "rhel-10-for-x86_64-appstream-eus-rpms"
  }
}

variable "reposync_schedule" {
  description = "repositoryがCDNからreposyncする時刻(systemdのOnCalendar形式、timezone基準)"
  type        = string
  default     = "*-*-* 00:00:00"
}

variable "mirror_sync_schedule" {
  description = "infraがrepositoryからrsyncする時刻(systemdのOnCalendar形式、timezone基準)。reposyncが終わっている時刻にする"
  type        = string
  default     = "*-*-* 01:00:00"
}

# ---------------------------------------------------------------------------
# Patch Manager
# ---------------------------------------------------------------------------

variable "patch_baselines" {
  description = <<-EOT
    環境ごとのパッチベースライン。キーがパッチグループ名(rhel10-<キー>)になる。
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
