# パッチ管理基盤(社内AWS環境向け)

> **このフォルダは参考実装であり、このリポジトリの実行対象ではない。**
> `satsho/iac`自体のTerraform state(`terraform/environments/`)には含まれておらず、
> `terraform plan`/`apply`の対象にもならない。社内の別のAWS環境・別のTerraformリポジトリに
> コピーして使うことを前提にしたコード一式(ドキュメント代わり)。

自宅ラボ(`satsho/iac`の`terraform/environments/patch-mgmt`)で動作確認済みの構成を、社内環境向けに
最小構成へ落とし込んだもの。環境名 `tst`/`stg`/`prd`、RHEL 10.2 + Windows Server 2025、
対象インスタンス数10台以上(タグベースなので台数は問わない)を前提にしている。

## 自宅ラボ版との違い

- **対象サーバのSSM通信用IAMロールはこのTerraformでは作らない**。ネイティブEC2のインスタンス
  プロファイルロール、Hybrid Activationで登録するサーバ用のロールのいずれも、既存のものを
  使う前提(どちらも作成済みとのこと)。そのため自宅ラボにあった`aws_iam_role.hybrid_node`や
  アクティベーション作成の仕組みはこの一式には含まれない。混在環境でも、対象サーバがSSMと
  通信できて`PatchGroup`等のタグが付いていれば、このTerraformの他の部分(ベースライン・
  メンテナンスウィンドウ・ゲート等)はネイティブEC2かHAかを区別しない。
- **タグベースのみ**。個別VMをTerraformで列挙する構成要素は無い(自宅ラボにあったVM構築用の
  Terraform/Ansibleはそもそも対象外)。全てのメンテナンスウィンドウ・スキャンは`PatchGroup`/`Env`
  タグで対象を絞り込む。
- **Inventory/Athena/Grafanaダッシュボードは今回は含めていない。** まずコア機能(ベースライン・
  スキャン・メンテナンスウィンドウ・ゲート・InstallNow・RebootAndScan・通知)を動かしてから、
  必要になった時点で追加する想定。
- **変更カレンダー連携は実装済み・有効化は任意。** `gated-patch-baseline.yaml`の
  `ChangeCalendarNames`パラメータ、ゲートのOPEN/CLOSED判定ロジック、`ssm:GetCalendarState`の
  IAM権限、`maintenance_windows`変数の`change_calendars`フィールドは全て組み込まれている。
  ただしデフォルトの`maintenance_windows`はどのウィンドウも`change_calendars`を設定していない
  (=カレンダーチェックをしない)。有効化する手順は下記「変更カレンダーを有効にする」を参照。
- **install-now.yamlをRHEL/Windows両対応に一般化**。自宅ラボ版は`OperatingSystem`を
  `REDHAT_ENTERPRISE_LINUX`に固定していたが、今回は`TargetTagValues`(PatchGroup名)から
  RHEL/Windowsを自動判定する(`automation.tf`の`local.install_now_patch_group_os`)。

## 配置方法

既存のTerraformは環境ごとにフォルダ・状態ファイルが分かれている構成とのことなので、このパッチ管理
リソース一式は **「prd infra」環境のフォルダにのみ** そのまま配置する(対象インスタンスは
prd/stg/tstの3環境に分かれているが、パッチ管理の仕組み自体は1つの状態で集中管理する設計)。

1. このディレクトリの `*.tf` と `documents/` を、prd infra環境のTerraformフォルダに丸ごとコピーする
   (モジュール化はしていない。既存フォルダのフラットなファイル構成に合わせてある)。
2. 既存の`provider`/`backend`設定はそのまま使われる(ここでは定義していない)。
3. `data "aws_caller_identity" "current"`や`local.name`など、既存コードに同名のリソース/ローカル値が
   既にあれば名前を調整する。
4. `variables.tf`のデフォルト値(`project_name`、タグ構造、スケジュール等)を実環境の命名規則・
   カレンダーに合わせて書き換える。

## 事前に必要な準備(Terraform適用前)

- **対象サーバへのタグ付け**: ネイティブEC2・Hybrid Activation登録サーバのどちらでも、以下の
  タグを付ける(Ansible/起動テンプレート/HA登録スクリプト等、既存の構成管理手段で行う。
  本リソース一式はタグを前提にするだけで、タグ付け自体は行わない)。

  | タグキー | 値の例 | 用途 |
  |---|---|---|
  | `PatchGroup` | `rhel10-tst` / `rhel10-stg` / `rhel10-prd` / `win2025-tst` / `win2025-stg` / `win2025-prd` | どのパッチベースラインに属するか(SSMの予約タグ名。これと同名のタグ付けが必須) |
  | `Env` | `tst` / `stg` / `prd` | メンテナンスウィンドウのターゲット絞り込み用。`PatchGroup`と情報は重複するが、環境単位の判定をしたい場面(ゲートの前段確認等)のために分けている |
  | `RebootPolicy` | `auto` / `manual` | そのサーバを自動再起動してよいか(`RebootIfNeeded` / `NoReboot`の切り分け) |
  | `Os` | `Windows-2025` | Windows機にのみ付ける。RHEL機と`Env`/`RebootPolicy`が同じ値になるため、Windows用メンテナンスウィンドウのターゲットをRHEL機と区別するために必要 |

  例(RHELのprdサーバ): `PatchGroup=rhel10-prd, Env=prd, RebootPolicy=manual`
  例(Windowsのstgサーバ): `PatchGroup=win2025-stg, Env=stg, RebootPolicy=auto, Os=Windows-2025`

- **対象サーバのSSM通信用IAMロール**: ネイティブEC2のインスタンスプロファイルロール、または
  Hybrid Activationで登録するロールのいずれも、既存のもの(`AmazonSSMManagedInstanceCore`相当の
  権限)を使う前提。このTerraformでは作らない。
- **運用者がInstallNow/RebootAndScanを手動実行するための権限**: 社内のAssumeRoleパターン
  (`terraform-ec2-role` → `terraform-work-role`)に合わせ、`terraform-work-role`(または同等の
  強い権限ロール)側に`iam.tf`末尾のコメントに書いたステートメントを追記する。このリソース一式では
  作らない(対象が社内の既存ロールであり、ここで管理すべきものではないため)。

## 適用後の確認

1. `terraform apply`後、`aws_ssm_association`(日次スキャン)が初回実行されるまで待つか、
   コンソールの「関連付けを今すぐ適用」で手動実行する。
2. タグ付けしたインスタンスが`describe-instance-patch-states`等でスキャン結果を報告することを確認する。
3. 最初はメンテナンスウィンドウの`enabled = false`にしておき、スキャンだけで1〜2日運用して
   コンプライアンス状況を確認してから、`enabled = true`にしてInstall(自動実行)を有効化する
   ことを推奨する(自宅ラボでの運用知見: 「承認ルール→ベースライン→スキャン→メンテナンスウィンドウ
   →ゲート」の順に、1つずつ動作確認しながら積み上げるほうが安全)。

## 変更カレンダーを有効にする(任意)

変更カレンダー連携(指定したカレンダーがCLOSEDならInstallを中止する)の仕組み自体は
最初から全ファイルに組み込まれている(`ChangeCalendarNames`パラメータ、ゲートの判定ロジック、
`ssm:GetCalendarState`権限、`maintenance_windows`変数の`change_calendars`フィールド)。
ただしデフォルトではどのウィンドウも使っていない(=カレンダーチェックをしない)ので、使う場合は
以下の手順で有効にする。

1. AWSコンソールの「Systems Manager」→「変更カレンダー」で、カレンダー(例:
   `prd-change-freeze`)を先に作成し、OPEN/CLOSEDの運用を始める。
2. `variables.tf`の`maintenance_windows`内、対象ウィンドウ(例: `prd-weekly`/`prd-monthly-win`)に
   コメントで用意している`change_calendars = ["prd-change-freeze"]`のコメントを外す。
3. `terraform apply`する。

**注意**: カレンダーを作成する前に`change_calendars`を有効化すると、`GetCalendarState`が
存在しないカレンダー名でエラーになり、Runbookがそこで止まってパッチが一切当たらなくなる。
必ず手順1を先に行うこと。

## ファイル一覧

| ファイル | 内容 |
|---|---|
| `variables.tf` | 環境・ベースライン・メンテナンスウィンドウの定義(変更頻度が最も高い) |
| `iam.tf` | `patch_automation`ロール(メンテナンスウィンドウのサービスロール兼Runbook実行ロール) |
| `patch_baseline.tf` | RHEL用パッチベースライン・パッチグループ・日次スキャン |
| `patch_baseline_windows.tf` | Windows用パッチベースライン・パッチグループ・日次スキャン |
| `automation.tf` | 4つのAutomation Runbook(ゲート/InstallNow/RebootAndScan×2)の定義 |
| `maintenance_window.tf` | メンテナンスウィンドウ本体・ターゲット・タスク |
| `notification.tf` | CloudWatch Logs・SNS・EventBridge通知 |
| `outputs.tf` | ロールARN・ベースラインID・ドキュメント名等の出力 |
| `documents/gated-patch-baseline.yaml` | ゲート付きInstall実行Runbook |
| `documents/install-now.yaml` | 手動即時実行(RHEL/Windows両対応) |
| `documents/reboot-and-scan-rhel.yaml` | 手動再起動パターン(RHEL) |
| `documents/reboot-and-scan-windows.yaml` | 手動再起動パターン(Windows) |
