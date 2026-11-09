# パッチ管理基盤 基本設計書

## 目次

1. [概要・目的](#1-概要目的)
2. [全体アーキテクチャ](#2-全体アーキテクチャ)
3. [ネットワーク構成](#3-ネットワーク構成)
4. [VM構成](#4-vm構成)
5. [パッチ承認の考え方(3軸モデル)](#5-パッチ承認の考え方3軸モデル)
6. [パッチベースライン設計](#6-パッチベースライン設計)
7. [メンテナンスウィンドウ設計](#7-メンテナンスウィンドウ設計)
8. [早く当てたい・緊急パッチ対応(InstallNow)](#8-早く当てたい緊急パッチ対応installnow)
9. [手動再起動パターン(RebootAndScan)](#9-手動再起動パターンrebootandscan)
10. [Change Calendar](#10-change-calendar)
11. [可視性・通知](#11-可視性通知)
12. [IAM設計](#12-iam設計)
13. [運用フロー例](#13-運用フロー例)
14. [今後の課題・TODO](#14-今後の課題todo)

---

## 1. 概要・目的

自宅の KVM ホスト(rancher)上に RHEL 10 / Windows Server 2025 の VM を立て、
AWS Systems Manager の Patch Manager を使った段階的パッチ適用(test → stg → prod)
を検証する。目的は以下の3点:

- **パッチ適用の自動化**と、**段階的ロールアウト(ゲート)** の仕組みを実際に動かして理解する
- 「早く当てたい」「緊急」のような例外フローを、**人の承認クリックを挟まずIAM権限だけで制御する**
  設計が成立するか検証する
- RHEL / Windows という**異なるOSの差異**(パッチの分類・深刻度、再起動の仕組み、リポジトリの
  取得経路)を同じ枠組みでどこまで共通化できるか確認する

AWS側(パッチベースライン・メンテナンスウィンドウ・Runbook・通知・可視化)は
Terraform(`terraform/environments/patch-mgmt`)で管理し、VM自体は家のサーバで
Ansible(`ansible/patch-mgmt/`)・手動構築(Windows)で作る。VMはSSM Hybrid Activationで
AWSに登録し、SSH/RDPを外部に公開せずSSM経由で操作する。

## 2. 全体アーキテクチャ

```
┌─────────────────────────── AWS (ap-northeast-1) ───────────────────────────┐
│                                                                              │
│  Patch Baseline(RHEL/Windows) ── 承認ルール・個別承認/拒否リスト            │
│  Maintenance Window(週次/月次) ── スケジュール                             │
│  Automation(GatedPatchBaseline) ── ゲート(前段ステージの成否確認)          │
│  Automation(InstallNow) ── 早く当てたい・緊急                              │
│  Automation(RebootAndScan[Rhel|Windows]) ── 手動再起動パターン             │
│  EventBridge → SNS ── 結果通知                                             │
│  EventBridge Scheduler → Automation(CollectPatchCompliance、毎時)          │
│  CloudWatch Dashboard / Logs ── 今の状態・推移                             │
│  SSM Inventory → S3 → Glue/Athena ── パッケージ一覧の横断検索              │
│                                                                              │
└───────────────────────────────┬──────────────────────────────────────────┘
                                  │ SSM Hybrid Activation(SSM Agent)
┌─────────────────────────────── KVMホスト(rancher, RHEL) ───────────────────┐
│                                                                              │
│  [patch-mgmt network]                                                      │
│    patch-repository ── Red Hat CDNからreposync                            │
│    patch-infra       ── repositoryからrsync、業務VM向けミラー兼ゲートウェイ │
│                                                                              │
│  [patch-workload network(仮想FW付き)]                                      │
│    patch-test / patch-stg / patch-prod (RHEL)                              │
│    patch-test-win (Windows Server 2025)                                    │
│                                                                              │
│  Grafana(rancher本体に直接インストール) → Athena(Assume Role) ── Inventory可視化 │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────┘
```

パッケージの流れ(RHEL): `Red Hat CDN → patch-repository(reposync) →
patch-infra(rsync) → 業務VM(dnf)`。業務VMは直接CDNに出ず、ミラー経由でのみ
取得する(`patch-workload`ネットワークの仮想FWで、業務VMが到達できる宛先を
SSMのエンドポイント等に限定している)。

Windowsは対応するローカルミラーの仕組みが無く、Microsoft Updateの
エンドポイントに直接到達する前提(ファイアウォール許可リストへの追加は
[14. 今後の課題](#14-今後の課題todo)参照)。

## 3. ネットワーク構成

| ネットワーク | 用途 | 仮想FW |
|---|---|---|
| `patch-mgmt`(`192.168.150.0/24`) | repository/infraがRed Hat CDNとAWS(SSM)に出るため | 無し(NAT) |
| `patch-workload`(`192.168.151.0/24`) | test/stg/prod/Windows業務VMと、infraの2枚目のNIC | KVMホストのnftablesで許可リスト制御(RHELは有効、詳細は[14.](#14-今後の課題todo)) |

DHCPは使わず、VMクローン直後・起動前に静的IP(NetworkManager設定/Windows
TCPIP設定)を書き込む方式(`dnsmasq`の`--bind-dynamic`バグでホストのLAN側
DHCPと競合するため)。IP割当はMACアドレスベースで固定。

| VM | IP | MAC(末尾) |
|---|---|---|
| patch-repository | 192.168.150.10 | ...10 |
| patch-infra | 192.168.150.11 / 192.168.151.11 | ...11 |
| patch-test | 192.168.151.21 | ...21 |
| patch-stg | 192.168.151.22 | ...22 |
| patch-prod | 192.168.151.23 | ...23 |
| patch-test-win | 192.168.151.24 | ...24 |

## 4. VM構成

### RHEL

`packer/rhel10-golden.pkr.hcl`で1回だけフルインストールしたゴールデン
イメージ(qcow2)を、各VM作成時に`qemu-img create -b`でbacking fileとして
クローンする(copy-on-write)。クローン後はディスクコピーのみなのでVM作成が速い。
ホスト名・SSH鍵・SSM登録・ロール別設定は`ansible/patch-mgmt/`がクローン後に
SSH経由で行う。

### Windows

専用のゴールデンイメージは作らず(現状1台のみ)、`autounattend.xml`による
無人インストールで直接構築する(`ansible/patch-mgmt/packer/windows2025-autounattend.xml`)。
将来複数台(stg/prod相当)が必要になった場合は、このVMをゴールデンイメージ化し
RHELと同じクローン方式に切り替える想定。

- Index=2(Standard Edition, Desktop Experience)を選択
- ディスクはSATA(ドライバ不要)、NICのみvirtio(virtio-win.isoからNetKVM
  ドライバを読み込み)
- `FirstLogonCommands`でOpenSSH Server・RDPを自動有効化(SSH鍵配布の代わりに
  パスワード認証、将来的な改善余地あり)
- 固定IP・固定ホスト名をunattend内で設定

### タグ設計

| タグ | 値の例 | 用途 |
|---|---|---|
| `Env` | `test`/`stg`/`prod`/`mgmt` | メンテナンスウィンドウのターゲット |
| `App` | `sample-app` | アプリ単位のメンテナンスウィンドウ(将来の拡張余地) |
| `Os` | `Windows-2025` | RHEL/Windowsの切り分け(RHELは付与なし) |
| `RebootPolicy` | `auto`/`manual` | 自動再起動か手動再起動か |
| `PatchGroup` | `rhel10-test`/`win2025-test`等 | **パッチベースラインとの紐付け**(Patch Managerが見る) |
| `Role` | `repository`/`infra`/`workload` | Run Commandの対象指定など |

## 5. パッチ承認の考え方(3軸モデル)

パッチが「いつ・どのように」適用されるかは、独立した3つの軸で決まる。

| 軸 | 何を制御するか | 省略できるか |
|---|---|---|
| **承認(Approval)** | パッチベースラインの`approve_after_days`等により、そのパッチを「入れてよい」と判定すること | **不可**(ベースラインに無いパッチは絶対にインストールされない) |
| **ゲート(Gate)** | 直前のステージのメンテナンスウィンドウが成功しているか、Failed/PendingRebootが残っていないかの確認 | 可(`InstallNow`は確認しない) |
| **スケジュール(Schedule)** | メンテナンスウィンドウのcronタイミング | 可(`InstallNow`は即時実行) |

通常の自動フローは3軸すべてが揃って初めて動く。「早く当てたい」
「緊急」は常にスケジュールとゲートを省略するが、承認だけは省略できない
(`InstallNow`の`AddApprovedPatches`で個別承認リストに追記することで、
承認日数という「待ち時間」だけを省略する)。

## 6. パッチベースライン設計

パッチベースラインには2つの独立した仕組みがある。

- **承認ルール(`approval_rule`)**: 分類・深刻度でフィルタし、`approve_after_days`
  (アドバイザリの日付からN日後に自動承認)または`approve_until_date`
  (指定日以前のみ承認)で判定する。**スキャン/インストールのたびに動的に評価
  される**(ベースラインに一覧として保存されるわけではない)。
- **個別承認/拒否リスト(`approved_patches`/`rejected_patches`)**: 明示的な
  アドバイザリID/CVE ID/パッケージ名のリスト。承認ルールより優先され、
  **ベースライン本体に保存される**。`install-now`が緊急時にここへ追記する。

| 環境 | `approve_after_days` | 備考 |
|---|---|---|
| test | 0 | 即日承認 |
| stg | 1 | testの1日後相当 |
| prod | 2 | stgの1日後相当 |
| mgmt(RHELのみ) | 0 | repository/infra自身。スキャンのみでウィンドウ無し |

RHELとWindowsでは分類・深刻度のフィルタキーが異なるため、
`patch_baseline.tf`(RHEL)と`patch_baseline_windows.tf`(Windows)でファイルを
分けている。

| | RHEL | Windows |
|---|---|---|
| `CLASSIFICATION`の値 | `Security`等 | `CriticalUpdates`/`SecurityUpdates`等(`Security`という値自体が無い) |
| 深刻度キー | `SEVERITY` | `MSRC_SEVERITY`(`SEVERITY`というキー自体が無い) |
| 深刻度の値 | `Critical`/`Important`/`Moderate`/`Low` | 同じ4値 |
| 追加フィルタ | なし | `PRODUCT=WindowsServer2025`(他バージョンを除外) |

`approved_patches`は`install-now`が`UpdatePatchBaseline` APIで直接書き換える
対象のため、Terraformの`lifecycle { ignore_changes = [approved_patches] }`で
差分検知から除外している(Terraform apply時に元のvariables.tfの値へ
巻き戻されるのを防ぐ)。この結果、個別承認の追加はTerraform/PRの記録に残らず
CloudTrailのみに残る(トレードオフとして許容)。

毎日のスキャン(`aws_ssm_association`、OSごとに関連付けを分割。1つの
関連付けのタグ値は最大5個までというAWS制限のため)が、全VMのMissing/Failed/
PendingReboot状態をPatch Managerに報告する。

## 7. メンテナンスウィンドウ設計

| ウィンドウ | スケジュール | task_type | ゲート条件 |
|---|---|---|---|
| test-weekly | 火曜 02:00 | RUN_COMMAND | なし |
| stg-weekly | 水曜 02:00 | AUTOMATION | test-weeklyが48時間以内にSUCCESS |
| prod-weekly | 金曜 02:00 | AUTOMATION | stg-weeklyが72時間以内にSUCCESS |
| test-monthly-win | 第3火曜 02:00 | RUN_COMMAND | なし |
| stg-monthly-win | 第4火曜 02:00 | AUTOMATION | test-monthly-winが240時間以内にSUCCESS |
| prod-monthly-win | 翌月第1火曜 02:00 | AUTOMATION | stg-monthly-winが336時間以内にSUCCESS |

- `RUN_COMMAND`は`AWS-RunPatchBaseline`を直接実行(ゲート不要な最初のステージ向け)
- `AUTOMATION`は`GatedPatchBaseline` Runbookをターゲットインスタンスごとに起動
- Windowsは**Patch Tuesday(第2火曜)起点**の月次サイクルで、RHELの週次とは
  別系統。「5番目の火曜」は毎月存在するとは限らないため、prodは
  「翌月第1火曜」として安定させている
- `reboot_option`は自動系(test/stg、Windowsも同様)が`RebootIfNeeded`、
  prodのみ`NoReboot`(再起動は[9.](#9-手動再起動パターンrebootandscan)参照)

ゲートの実体は`gated-patch-baseline.yaml`の`CheckPreviousStage`ステップ
(`aws:executeScript`)で、以下2条件をPython(boto3)で判定する。

1. 前段のメンテナンスウィンドウが、直近`GateMaxAgeHours`時間以内に`SUCCESS`
   で終わっている(`describe_maintenance_window_executions`)
2. 前段パッチグループのインスタンスに、`FailedCount`/`InstalledPendingRebootCount`
   が残っていない(`describe_instance_patch_states_for_patch_group`)

注意点: 条件1は**そのウィンドウ自身の実行履歴**を見るため、`install-now`で
前段を手動修復しても、ウィンドウ自体が実行されていなければ条件1は満たせない
(条件2のみ満たされる)。

## 8. 早く当てたい・緊急パッチ対応(InstallNow)

`iac-poc-patch-InstallNow` の1つのRunbookが、以下2ケースを兼ねる。

- **承認済みパッチを今すぐ当てたい** → `AddApprovedPatches`を空のまま実行
- **未承認パッチを緊急で当てたい** → `AddApprovedPatches`にRHSA ID等を指定
  (個別承認リストへ追記してからInstall)

承認する人と実行する人が同じという想定のため、`aws:approve`のような人の
承認クリックは挟まない。**IAM権限を持つ人が実行できること自体が唯一の制御**。
ゲートチェックも行わない(人が直接判断して実行するため)。

対象の指定は2通り:

- `TargetTagValues`(PatchGroup全体、RHELのみ対応)
- `InstanceId`(特定の1台だけ。指定するとTargetTagValuesより優先される。
  カナリア的に1台だけ先に当てたい場合に使う。`AddApprovedPatches`と
  併用する場合は、承認がPatchGroup=ベースライン単位の概念のため
  `TargetTagValues`も必須)

```
Step 1: AddApprovedPatchesIfNeeded (aws:executeScript)
  - AddApprovedPatchesが空ならスキップ
  - 指定があれば、既存のApprovedPatchesを読み→追記→書き戻し
    (UpdatePatchBaselineは全置き換えAPIのため、読み出しが必須)
  - GetPatchBaselineForPatchGroupは必ずOperatingSystemを明示する
    (省略するとWINDOWS扱いになり、別アカウント所有のデフォルト
    ベースラインにフォールバックしてしまう実機確認済みの落とし穴)
Step 2: RunPatchBaseline (aws:executeScript)
  - InstanceIdが指定されていればその1台、無ければTargetTagValuesの
    PatchGroup全体にSendCommand(AWS-RunPatchBaseline, Operation=Install)
Step 3: WaitForPatchCommand
Step 4: AssertPatchCommandSucceeded
```

コンソールから実行する場合、「シンプルな実行」で`InstanceId`に直接入力すれば
1台に絞れる。複数台へ同時実行数・失敗許容数を制御しながら流したい場合は
「レート制御実行」でターゲットパラメータ名に`InstanceId`を指定する。

## 9. 手動再起動パターン(RebootAndScan)

prod(`RebootPolicy: manual`)は`RebootOption: NoReboot`でパッチを適用する
ため、再起動が必要なパッチが入ると`InstalledPendingReboot`のまま残る。
`virsh reboot`やVM内から直接再起動しただけでは、次のスキャンまでPatch
Manager上は再起動待ちのまま残り、次ステージのゲートも通らない。
`RebootAndScan`系Runbookは「再起動 → スキャン」までまとめて行う。

RHEL版(`RebootAndScanRhel`)とWindows版(`RebootAndScanWindows`)は、
Automationの構造は同一で、以下の2点だけが異なる。

| | RHEL(`AWS-RunShellScript`) | Windows(`AWS-RunPowerShellScript`) |
|---|---|---|
| 再起動を継続扱いにする終了コード | 194 | 3010(`ERROR_SUCCESS_REBOOT_REQUIRED`) |
| マーカーファイル | `/var/tmp/patch-reboot.marker` | `$env:SystemRoot\Temp\patch-reboot.marker` |

**仕組み**: Step「Reboot」は、`AWS-RunShellScript`/`AWS-RunPowerShellScript`
(「渡されたコマンドをそのまま実行するだけ」の汎用ドキュメント)に、マーカー
ファイル+特定終了コードを返すスクリプトを渡す。SSM Agentはこの終了コードを
検知すると、インスタンスを再起動した上で**同じコマンド(Agentがローカルに
保持しているスクリプト)をもう一度実行する**(AWS-RunPatchBaselineの
`RebootOption`のような専用機能とは異なり、汎用ドキュメントには再起動の
概念が無いため、終了コードによる間接的なトリガーが必要)。

1回目の実行: マーカー無し → 作成 → 終了コードで終了(再起動)
2回目の実行(再起動後): マーカー有り → 削除 → 正常終了(無限ループしない)

Step「ScanAfterReboot」は別のRun Command(`AWS-RunPatchBaseline`、
Operation=Scan)で、マーカーファイルのロジックとは無関係。

## 10. Change Calendar

年末年始などの変更凍結期間を定義する仕組み。**Terraform/APIで作成した
カレンダーはAWSコンソールのGUIビルダーで編集できない**ことを実機で確認した
ため、Terraformでは管理せず、**運用者がコンソールから直接作成・編集する**
運用に決定した(「コンソールからじゃないと運用者が使うの難しい」という
操作性要件を優先)。

## 11. 可視性・通知

| 手段 | 内容 |
|---|---|
| SNS(メール) | メンテナンスウィンドウ/Runbookの結果(SUCCESS/FAILED等)、パッチ非準拠への変化(EventBridge経由) |
| CloudWatch Dashboard `iac-poc-patch-status` | 今の状態(VMごとの準拠状況、未適用パッチとCVE)。`CollectPatchCompliance` Runbookが毎時10分に集計 |
| CloudWatch Dashboard `iac-poc-patch-history` | 推移(環境別の未適用/再起動待ち/失敗パッチ数の時系列)と実行履歴 |
| SSM Inventory → S3 → Glue/Athena | 全VMのインストール済みパッケージ一覧をSQLで横断検索(「このkernelが入っているVMは?」等) |
| **Grafana(rancher本体に直接インストール)** | Athena(Assume Role経由)をデータソースに、Inventoryをグラフ表示。専用VMは作らず軽量構成 |
| trivy脆弱性スキャン | 仕込み済みだが**停止中**(RHEL 10未対応のため) |

Grafanaは新しい長期アクセスキーを作らず、rancher自身が持つSSM Hybrid
Activationロールから`sts:AssumeRole`する専用IAMロール
(`iac-poc-patch-grafana-athena-role`)を使う。Grafanaはセキュリティ上の
理由でプラグイン子プロセスにホスト環境変数を転送しないため、Athena
データソースの認証方式は「AWS SDK Default」ではなく「Credentials file」
(`$HOME/.aws/credentials`、`grafana`ユーザーのホーム`/usr/share/grafana`配下)
を使っている。

## 12. IAM設計

| ロール | 用途 |
|---|---|
| `iac-poc-patch-hybrid-node-role` | ラボVM(Hybrid Activation)が引き受ける。SSM Core + ログ出力 + Inventory/trivy用 |
| `iac-poc-patch-automation-role` | メンテナンスウィンドウのサービスロール兼Runbookの`AutomationAssumeRole`。実行できるコマンドは`AWS-RunPatchBaseline`/`AWS-RunShellScript`/`AWS-RunPowerShellScript`のみに限定。起動できるRunbookもdocument ARNで限定 |
| `iac-poc-patch-grafana-athena-role` | Grafana専用。rancher自身のHybrid ActivationロールからのみAssumeRole可。Athena/Glue/S3の読み取りのみ |
| `github-actions-terraform`(CloudFormation管理、`terraform/iam/terraform-role.yaml`) | GitHub Actions(OIDC)がTerraform applyに使う。トライアル段階のため広め(`ec2:*`/`iam:*`等サービス単位)に許可 |

`StartAutomationExecution`の認可は`document/`と`automation-execution/*`の
両方のARNに対して行われるため、`automation-definition/*`+`document/*`
だけでは不十分(実機で踏んだ落とし穴)。

## 13. 運用フロー例

```
月曜      RHSAがリリースされる(例: RHSA-2026:95367)
火曜02:00 test-weekly: 承認0日なので即承認・自動適用・自動再起動
水曜02:00 stg-weekly: ゲート「test-weeklyが48時間以内にSUCCESS?」→OK
                       stg(1日)も承認済み → インストール・自動再起動
金曜02:00 prod-weekly: ゲート「stg-weeklyが72時間以内にSUCCESS?」→OK
                       prod(2日)も承認済み → インストール(再起動はしない)
金曜日中   運用者が都合の良いタイミングでRebootAndScanRhelを実行
```

早めたい場合は`InstallNow`でスケジュール・ゲートを省略(承認は必須のまま)。
緊急の場合も同じ`InstallNow`で、`AddApprovedPatches`を併用する。

## 14. 今後の課題・TODO

- Windows業務VMの`patch-workload`仮想FW許可リストへのMicrosoft Updateエンドポイント追加(現状RHELの許可リストのみ運用中、Windows側はegress_firewallが無効なままの可能性があるため要確認)
- Windows VMのAnsible構成管理への組み込み(現状手動構築のまま。WinRM/OpenSSHベースの接続方式を検討)
- trivy脆弱性スキャンのRHEL 10対応待ち(現状停止中)
- QuickSight等によるInventoryデータの本格的な可視化(現状GrafanaのPoC止まり。Grafanaの認証情報更新を定期ジョブ化するかも検討)
- Windows VMを複数台(stg/prod相当)構成にする場合、ゴールデンイメージ+クローン方式への切り替え
- `admin-longterm` IAMユーザーの長期アクセスキーのローテーション(チャットに一時的に露出した経緯があるため要確認)
