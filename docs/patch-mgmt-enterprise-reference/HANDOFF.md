# 引き継ぎ資料: パッチ管理基盤(AWS Systems Manager Patch Manager)の社内環境への導入

この資料は、このZIP同梱のTerraformコード一式(`*.tf` + `documents/*.yaml`)を、社内のAWS環境に
実装してもらうための引き継ぎ資料。実装担当(人間またはAIエージェント)はこのリポジトリの
過去の経緯を参照できないため、必要な文脈をここに全て書く。

## 1. 目的

AWS Systems Manager Patch Managerを使った、RHEL 10.2 + Windows Server 2025向けの
パッチ管理基盤(ベースライン・スケジュール適用・段階的ロールアウト・手動緊急適用・通知)を、
社内AWS環境に実装する。元ネタは個人の自宅ラボ環境(KVM上)で実際に動作確認済みの構成。
今回のコードはそれを社内環境向け(タグベース、既存IAMロール利用)に落とし込んだもの。

## 2. 前提(すでに確定している事実。再確認・再検討は不要)

- 環境名は `tst` / `stg` / `prd` の3つ。
- 対象サーバはRHEL 10.2とWindows Server 2025、それぞれ各環境に10台以上(タグベースで
  対象を絞り込むため、具体的な台数は構成に影響しない)。
- 対象サーバのSSM通信用IAMロールは **既存のものを使う**。本コードでは新規作成しない。
  - ネイティブEC2のインスタンスプロファイルロール(`AmazonSSMManagedInstanceCore`相当)は作成済み。
  - Hybrid Activationで登録するサーバ用のロールも作成済み(社内ではネイティブEC2とHAが混在する)。
  - いずれの方式でサーバが登録されていても、以降のTerraformコード(ベースライン・
    メンテナンスウィンドウ・ゲート等)は区別しない(タグとSSMのマネージドノードとしての
    登録状態だけを見る)。
- 社内の既存Terraformは環境ごとにフォルダ・状態ファイルが分かれている構成で、命名規則は
  `envs/<env>/infra/<resource>/`(例: `envs/prd/infra/ec2/`, `envs/prd/infra/sg/`,
  `envs/prd/infra/keypair/`)。このパッチ管理リソース一式は **`envs/prd/infra/ssm/` に配置する**
  (prd環境のフォルダに1つだけ作る。対象インスタンスはtst/stg/prdの3環境に分かれるが、
  パッチ管理の仕組み自体は1つの状態で集中管理する設計)。
- 社内のIAMは「EC2はAssumeRoleのみの弱いロール(`terraform-ec2-role`)→強い権限の
  `terraform-work-role`に切り替えて作業する」というパターンを使っている。**これは
  Terraformを実行するCI/EC2側の話であり、本コードが作るIAMロール(後述の`patch_automation`)
  とは無関係・無競合**。`patch_automation`ロールは`ssm.amazonaws.com`(AWSのSSMサービス自体)が
  AssumeRoleする相手であり、EC2インスタンスが引き受けるロールではない。

## 3. 同梱しているファイル

```
variables.tf                          # 環境・ベースライン・メンテナンスウィンドウの定義(最も調整が必要)
iam.tf                                 # patch_automationロール(メンテナンスウィンドウ/Runbookの実行ロール)
patch_baseline.tf                      # RHEL用パッチベースライン・パッチグループ・日次スキャン
patch_baseline_windows.tf              # Windows用パッチベースライン・パッチグループ・日次スキャン
automation.tf                          # 4つのAutomation Runbookのaws_ssm_document定義
maintenance_window.tf                  # メンテナンスウィンドウ本体・ターゲット・タスク
notification.tf                        # CloudWatch Logs・SNS・EventBridge通知
outputs.tf                             # ロールARN・ベースラインID・ドキュメント名等の出力
documents/gated-patch-baseline.yaml    # ゲート(前段ステージ確認+変更カレンダー確認)付きInstall実行Runbook
documents/install-now.yaml             # 手動即時実行(RHEL/Windows両対応、承認リストへの緊急追記も可)
documents/reboot-and-scan-rhel.yaml    # 手動再起動パターン(RHEL)
documents/reboot-and-scan-windows.yaml # 手動再起動パターン(Windows)
README.md                              # 配置方法・事前準備・適用後の確認手順(人間向けの詳細説明)
```

モジュール化はしていない(フラットなファイル構成)。`envs/prd/infra/ec2/`等と同じ並びに
`envs/prd/infra/ssm/`としてこのファイル一式(`documents/`フォルダ含む)をそのまま置く。

## 4. 実装手順

1. **フォルダを作る**: `envs/prd/infra/ssm/`を作成し、このZIPの`*.tf`と`documents/`をコピーする。
2. **backend/providerを追加する**: このコード一式には`backend`/`provider`/`terraform {}`ブロックが
   **含まれていない**。`envs/prd/infra/ec2/`等、既存の同階層フォルダに入っている`backend.tf`
   (または同等のファイル)を参考に、`ssm/`用の状態ファイル(stateキー)を割り当てて同様のものを作る。
   他の`infra`配下のフォルダと同じ`provider`設定(リージョン、デフォルトタグ等)をそのまま使う。
3. **命名規則を合わせる**: `variables.tf`の`project_name`(デフォルト`"patch-mgmt"`)を、
   社内の既存リソースの命名規則に合わせて変更する。`data "aws_caller_identity" "current"`や
   `local.name`など、同一`provider`設定を共有する他のフォルダ(別state)には影響しないので、
   名前の重複は通常問題にならない(同一フォルダ内でのみ重複を避ければよい)。
4. **タグ付けの実施(Terraformの外側)**: 対象サーバに以下のタグを付与する。既存の構成管理手段
   (Ansible、起動テンプレート、HA登録スクリプト等)側で行う。本Terraformはタグの存在を前提に
   するだけで、タグ付け自体は行わない。

   | タグキー | 値の例 | 用途 |
   |---|---|---|
   | `PatchGroup` | `rhel10-tst` / `rhel10-stg` / `rhel10-prd` / `win2025-tst` / `win2025-stg` / `win2025-prd` | どのパッチベースラインに属するか。**SSMの予約タグ名なので、このキー名は変更できない** |
   | `Env` | `tst` / `stg` / `prd` | メンテナンスウィンドウのターゲット絞り込み用 |
   | `RebootPolicy` | `auto` / `manual` | 自動再起動してよいか(`RebootIfNeeded` / `NoReboot`の切り分け) |
   | `Os` | `Windows-2025` | Windows機にのみ付ける。RHEL機と`Env`/`RebootPolicy`が同じ値になるため、Windows用メンテナンスウィンドウの対象をRHEL機と区別するために必須 |

   **要確認**: このタグ構成は検証環境で使ったものを前提に作られているが、実際の対象サーバに
   同じタグが付いているか(キー名・値の表記ゆれ含め)を実装前に必ず確認すること。異なる場合は
   `variables.tf`の`target_tags`、`patch_baseline.tf`/`patch_baseline_windows.tf`の
   `patch_groups`命名規則を実際のタグに合わせて書き換える。

5. **`terraform init` / `plan`を実行し、差分を確認する**。既存の`envs/prd/infra/ec2/`等と
   provider設定を共有していれば、特別な追加設定は不要なはず。
6. **`terraform apply`**。ただし本番運用前に下記「5. 推奨する立ち上げ順序」に従うこと。
7. **運用者の実行権限を別途付与する**(本Terraformの管理外、下記6章参照)。

## 5. 推奨する立ち上げ順序(いきなり自動Install有効化は危険)

1. `variables.tf`の`maintenance_windows`内、各ウィンドウの`enabled`を**一旦`false`**にして
   `terraform apply`する(ベースライン・パッチグループ・日次スキャンだけ動かす)。
2. 日次スキャン(`aws_ssm_association.patch_scan`/`patch_scan_windows`)が実行されるまで待つか、
   コンソールの「関連付けを今すぐ適用」で手動実行する。
3. `aws ssm describe-instance-patch-states`等で、対象サーバがスキャン結果を正しく報告している
   ことを確認する(ここで対象タグ・PatchGroupの不整合があれば気づける)。
4. 1〜2日程度、スキャンだけで運用しコンプライアンス状況(不足パッチの数等)を確認する。
5. 問題なければ`enabled = true`に戻し、`tst`環境から順に自動Installを有効化する
   (`tst` → `stg` → `prd`の順。`variables.tf`のデフォルトはこの順に`gate`で連動する設計)。

## 6. 本Terraformが作らないもの(別途対応が必要)

- **対象サーバのSSM通信用IAMロール自体**(前提として既存のものを使う。2章参照)。
- **運用者がInstallNow/RebootAndScanを手動実行するための権限**: 社内のAssumeRoleパターン
  (`terraform-ec2-role` → `terraform-work-role`)に合わせ、`terraform-work-role`側に
  `iam.tf`末尾のコメントに記載したIAMステートメント(`ssm:StartAutomationExecution`への
  許可+`iam:PassRole`)を追記する。
- **変更カレンダーそのもの**: AWSコンソールの「変更カレンダー」画面で作成・OPEN/CLOSED運用する。
  連携の仕組み(`ChangeCalendarNames`パラメータ、ゲートのチェックロジック、IAM権限)は
  コード側に実装済みだが、デフォルトではどのメンテナンスウィンドウも使っていない(無効)。
  有効化する場合は、**カレンダーをコンソールで先に作成してから**
  `variables.tf`の対象ウィンドウ(`prd-weekly`/`prd-monthly-win`にコメントアウトの例がある)で
  `change_calendars = ["<カレンダー名>"]`を指定する。**順番を間違え、存在しないカレンダー名を
  指定するとRunbookがエラーで止まり、パッチが一切当たらなくなるので注意**。
- **Inventory/Athena/Grafanaダッシュボード**: スコープ外(まずコア機能を安定させてから別途検討)。

## 7. 実装・運用上の既知の注意点(踏むと分かりにくい落とし穴)

- **`GetPatchBaselineForPatchGroup`のOS省略デフォルト問題**: `OperatingSystem`パラメータを
  省略すると`WINDOWS`扱いになる。RHELのパッチグループに対してこれをやると、該当パッチグループの
  登録が無いため、アカウント外(別アカウント所有)のWindowsデフォルトベースラインにフォールバック
  してしまい、後続の`UpdatePatchBaseline`が`AccessDeniedException`で失敗する。
  `install-now.yaml`は`TargetTagValues`(PatchGroup名)から自動でRHEL/Windowsを判定して
  `OperatingSystem`を明示するようにしてあるので、これ自体は対応済みだが、**今後似た処理を
  追加する場合は必ず`OperatingSystem`を明示すること**。
- **`UpdatePatchBaseline`の`ApprovedPatches`は全置き換えAPI**: 追記ではなく上書きなので、
  既存の承認リストを一度読んでから追記して書き戻す必要がある(`install-now.yaml`で対応済み)。
- **`aws_ssm_patch_baseline`の`approved_patches`は`lifecycle { ignore_changes }`にしている**:
  `InstallNow`が実行時にAPIで直接書き換えるため、Terraformが`variables.tf`の初期値に
  巻き戻してしまわないようにする意図的な設定。これを外すと、緊急追加した承認パッチが
  次の`terraform apply`で消えてしまう。
- **再起動の継続判定は終了コードベース**: RHEL(`AWS-RunShellScript`)は終了コード`194`、
  Windows(`AWS-RunPowerShellScript`)は終了コード`3010`を返すと、SSM Agentがインスタンスを
  再起動し、起動後に同じスクリプトを再実行する(AWS側の仕組み。Automationドキュメント側では
  何もしていない)。目印ファイル(マーカー)を置いて2回目の実行では再起動しないようにしている。
- **1つのタグ値リストは最大5個まで(AWSの制限)**: このためRHEL用とWindows用の日次スキャン
  関連付け(`aws_ssm_association`)を分けている。環境が増えて片方が5個を超える場合は
  さらに分割が必要。
- **SNSトピック名の制約**: `aws:approve`(人の承認クリック)ステップを将来追加する場合、
  その通知先に使うSNSトピック名は`Automation`で始まっている必要がある(AWS側の制約。
  今回のコードでは使っていないが、拡張時に注意)。

## 8. 動作確認(Acceptance Criteria)

- [ ] `terraform plan`/`apply`がエラーなく完了する。
- [ ] 日次スキャンの関連付け(`patch_scan`/`patch_scan_windows`)が、タグ付けした全対象サーバに
      対して実行され、`describe-instance-patch-states`でスキャン結果(Missing/Installed等の件数)
      が報告される。
- [ ] `tst`環境のメンテナンスウィンドウを`enabled = true`にして、スケジュール通りに
      `GatedPatchBaseline`(AUTOMATION)が起動し、`AWS-RunPatchBaseline`(Install)が実行される。
- [ ] `stg`環境のウィンドウが、`tst`の成功を確認してから実行される(ゲートが機能している)。
      `tst`を失敗させた状態で`stg`のウィンドウ実行時刻を迎えると、ゲートチェックで中止される
      ことも確認できるとより安全。
- [ ] `InstallNow`(手動即時実行)を1台に対して実行し、承認済みパッチのみInstallされることを
      確認する。
- [ ] 通知用SNSトピックへのメール購読(`notification_email`)を設定した場合、メンテナンス
      ウィンドウ実行完了時に通知メールが届く。

## 9. まだ決まっていないこと(実装前に確認・決定が必要)

- 実際の対象サーバのタグ構成が4章の表と一致しているか(要確認、最重要)。
- `envs/prd/infra/ssm/`に置く際の`backend`/`provider`設定の具体的な中身(社内の既存フォルダを
  参照して作る必要があり、このZIPには含まれていない)。
- `project_name`変数の命名(社内の命名規則に合わせる)。
- 変更カレンダーを使うかどうか、使う場合のカレンダー名。
- 通知メールの送付先アドレス。
- 運用者(InstallNow/RebootAndScanを手動実行する人)の範囲と、`terraform-work-role`側への
  権限追記の実施者・実施タイミング。
