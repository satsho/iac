# パッチ管理基盤 移植ガイド(社内AWS環境向け)

自宅ラボ(KVM + SSM Hybrid Activation)で検証したPatch Manager基盤のうち、
**AWS側のパッチ管理関連リソース**(IAM・パッチベースライン・メンテナンス
ウィンドウ・Automation Runbook・通知・可視化)を、社内の実AWS環境
(IAMはAssumeRoleチェーン、環境ごとにフォルダ/state分割、prd infra環境の
みにデプロイ)へ移植するためのガイド。

**対象外**(自宅ラボ固有のため、このガイドでは扱わない):
VM構築(Packer/Ansible/`autounattend.xml`)、KVMの仮想ネットワーク・
nftables仮想FW。EC2側は既存のプロビジョニングフロー・ネットワークに
乗る前提とし、本ガイドは「VMが既にSSM管理対象になっている」ところから
AWS側に作るリソースだけを扱う。

参照元: `satsho/iac`リポジトリ `terraform/environments/patch-mgmt/`
(設計の全体像は同リポジトリ `docs/patch-mgmt-design.md` も参照)

---

## 1. 前提の違い

| | 自宅ラボ | 社内環境 |
|---|---|---|
| IAM | 用途ごとに新規ロールを作成 | インスタンスロールはAssumeRoleのみ許可 → 特定の強い権限ロールへ切り替え |
| Terraform構成 | 1環境1tfディレクトリ(`patch-mgmt`のみ) | 環境(prd/stg/dev等)ごとにフォルダ分割、各フォルダに個別tf/state |
| デプロイ対象 | 唯一の環境 | **prd infra環境のみ**にデプロイ |
| ノードのSSM登録 | Hybrid Activation(Terraform側でも`hybrid_node`ロールを作成) | 対象外(社内側で登録済みの前提。[3.1](#31-ノード登録のiamだけは要確認)で権限面のみ触れる) |

**結論**: パッチ管理の「仕組み(ロジック)」はOS/実行基盤に依存しないので
Terraformリソースはほぼそのまま移植できる。移植が必要なのは
「IAMロールの組み方」と「Terraformのフォルダへの当てはめ方」の2点。

---

## 2. そのまま持っていける設計(コンセプト層)

### 2.1 承認・ゲート・スケジュールの3軸モデル

- **承認(Approval)**: パッチベースラインの`approve_after_days`(または
  `approve_until_date`)で機械的に判定。省略不可。
- **ゲート(Gate)**: 直前ステージのメンテナンスウィンドウが直近N時間以内に
  成功しているか、かつ前段パッチグループにFailed/PendingRebootが残って
  いないかを確認。省略可。
- **スケジュール(Schedule)**: メンテナンスウィンドウのcron。省略可。

通常フローは3軸すべてを使い、「早く当てたい/緊急」はスケジュールと
ゲートだけを省略する(`InstallNow`)。この整理自体はAWS Patch Manager
共通の概念なので、実行基盤がEC2でもそのまま通用する。

### 2.2 パッチベースライン: 承認ルール vs 個別リスト

- `approval_rule`(分類・深刻度でフィルタ、日数/日付で判定)は**動的評価**
  (スキャン/インストールの都度評価、保存されない)
- `approved_patches`/`rejected_patches`(明示的なID列挙)は**ベースラインに
  保存される**、承認ルールより優先

RHEL/Windowsでフィルタキーが異なる点(RHEL: `SEVERITY`、Windows:
`MSRC_SEVERITY`。Windowsは`PRODUCT`で製品を絞る必要あり)もAWS側の仕様
なのでそのまま。実機で確認済みの値は下記。

| | RHEL | Windows |
|---|---|---|
| `CLASSIFICATION` | `Security`等 | `CriticalUpdates`/`SecurityUpdates`等 |
| 深刻度キー | `SEVERITY` | `MSRC_SEVERITY` |
| 深刻度の値 | `Critical`/`Important`/`Moderate`/`Low` | 同じ4値 |
| 製品指定 | 不要 | `PRODUCT=WindowsServerXXXX`必須 |

### 2.3 ゲートRunbook(`gated-patch-baseline.yaml`)

`aws:executeScript`(Python/boto3)で以下2条件を判定するロジックは、
EC2/オンプレを問わず同じAPI(`describe_maintenance_window_executions`、
`describe_instance_patch_states_for_patch_group`)で動く。**そのまま移植可**。

1. 前段ウィンドウが直近N時間以内にSUCCESSで終わっている
2. 前段パッチグループにFailed/PendingRebootが残っていない

### 2.4 InstallNow(緊急・早く当てたい)

`AddApprovedPatches`(個別承認リストへの追記、read-merge-write)、
`InstanceId`(単体指定、`TargetTagValues`より優先)という設計、
「承認する人と実行する人が同じなので`aws:approve`を挟まずIAM権限だけで
制御する」という考え方もそのまま使える。**ただし社内のAssumeRoleチェーンに
どう組み込むかは[3.2](#32-iamロール-assumeroleチェーンへの組み込み)で要検討**。

実機で踏んだ落とし穴(`GetPatchBaselineForPatchGroup`はOS省略時WINDOWS扱い
になる等)も同じAWS API仕様なので、EC2環境でも同様に発生しうる。
`documents/install-now.yaml`はほぼそのままコピーして使える。

### 2.5 RebootAndScan(手動再起動パターン)

`AWS-RunShellScript`/`AWS-RunPowerShellScript`に「マーカーファイル+特定
終了コード(RHEL: 194、Windows: 3010)」を返すスクリプトを渡し、SSM Agentに
再起動→再実行させる仕組みはSSM Agent自体の機能なので、EC2でもオンプレでも
同じ。**そのまま移植可**。

### 2.6 通知・可視化のパターン

- EventBridge → SNSでメンテナンスウィンドウ/Runbook結果・非準拠化を通知
- `CollectPatchCompliance`(1時間ごと)→ CloudWatch Logs → ダッシュボード
- SSM Inventory → S3 Resource Data Sync → Glue/Athena でパッケージ一覧を
  横断検索

これらもAWS標準機能の組み合わせなので、EC2環境でもそのまま使える。
(Grafana部分は自宅ラボ固有のPoCなので、社内では既存のBIツール/
QuickSight等に差し替えるのが自然)

---

## 3. 移植が必要な部分

### 3.1 ノード登録のIAMだけは要確認(対象外領域との接点)

VM/EC2のSSM登録自体はこのガイドの対象外だが、1点だけAWS側のIAM設計に
影響するため触れておく。自宅ラボは`aws_iam_role.hybrid_node`という
Hybrid Activation専用ロールを作っているが、これは**移植不要**
(対象側のインスタンスは既にSSM管理対象になっている前提のため)。

ただし、そのインスタンスが使っているロールの権限(`AmazonSSMManagedInstanceCore`
相当)が「AssumeRoleのみ許可」という社内方針の中でどう確保されているかは、
パッチ管理リソース側からは制御できない部分なので、基盤/セキュリティ担当
側で解決済みであることを前提にする(未解決なら先にそちらを確認)。

### 3.2 IAMロール: AssumeRoleチェーンへの組み込み

自宅ラボの`aws_iam_role.patch_automation`(メンテナンスウィンドウの
サービスロール兼Runbookの`AutomationAssumeRole`)は、信頼ポリシーが
`ssm.amazonaws.com`(SSMサービス自身)になっている。これは**人やEC2が
AssumeRoleする対象ではなく、AWSのSSMサービスが内部的に引き受ける
ロール**なので、「EC2ロール→強い権限ロールへの切り替え」という社内
パターンとは**層が異なる**(衝突しない)。

実際に気にすべきAssumeRoleチェーンは2つ。

1. **誰が`InstallNow`/`RebootAndScan`等のRunbookを起動できるか**
   (`ssm:StartAutomationExecution`+`iam:PassRole`で`patch_automation`
   ロールを渡す権限)。これを「強い権限ロール」側にのみ許可し、
   EC2の基礎ロールには持たせない、という設計にすれば社内方針と整合する。
2. **CI/CD(Terraform apply)がこれらのリソースを作る権限**
   (自宅ラボでは`github-actions-terraform`ロールが相当)。社内の
   Terraform実行用ロール構成に合わせて権限を追加する。

```
[人 or CI] --sts:AssumeRole--> [強い権限ロール] --ssm:StartAutomationExecution--> Automation実行
                                                   (iam:PassRole で patch_automation を渡す)
                                                        │
                                                        ▼
                                          [patch_automation ロール]
                                          (ssm.amazonaws.com が引き受ける)
                                          --sts:AssumeRole(実行時)--> Runbookの処理
```

### 3.3 Terraformのフォルダ構成への当てはめ

自宅ラボは`terraform/environments/patch-mgmt/`という単一ディレクトリ・
単一stateだが、社内は「環境ごとにフォルダ分割、各フォルダ内でさらに
機能ごとに分割、tf/stateも個別」という構成。**prd infra環境にのみ
デプロイする**という制約があるため、イメージとしては:

```
<リポジトリルート>/
└── environments/
    └── prd/
        └── infra/
            ├── patch-mgmt/          ← ここに今回のリソース一式を配置
            │   ├── patch_baseline.tf
            │   ├── patch_baseline_windows.tf
            │   ├── maintenance_window.tf
            │   ├── automation.tf
            │   ├── documents/
            │   │   ├── gated-patch-baseline.yaml
            │   │   ├── install-now.yaml
            │   │   ├── reboot-and-scan.yaml
            │   │   └── reboot-and-scan-windows.yaml
            │   ├── iam.tf            ← hybrid_node関連は削除、EC2向けに書き換え
            │   ├── notification.tf
            │   ├── dashboard.tf
            │   ├── inventory.tf
            │   ├── variables.tf
            │   ├── outputs.tf
            │   └── backend.tf        ← 社内のstate管理方式に合わせる
            └── (他の既存機能フォルダ)
```

既存の他環境(stg/dev等)には**展開しない**ことを明示するため、
このディレクトリ自体をprd infra配下にのみ作成し、他環境からは
参照されない独立したstateにするのが安全。

---

## 4. 移植時のファイル一覧とチェックリスト

| ファイル | 移植方針 |
|---|---|
| `patch_baseline.tf` / `patch_baseline_windows.tf` | ほぼそのまま。`approve_after_days`等は社内の承認ポリシーに合わせて値を変える |
| `maintenance_window.tf` | ほぼそのまま。スケジュール(曜日・時刻)は社内の運用時間に合わせる |
| `automation.tf` | ほぼそのまま。`document_names`のプレフィックス等は社内の命名規則に合わせる |
| `documents/*.yaml` | ほぼそのまま(Python/Bash/PowerShellのロジックはOS/実行基盤に非依存) |
| `iam.tf` | **要書き換え**。`hybrid_node`関連を削除、`patch_automation`の信頼ポリシー・権限は[3.2](#32-iamロール-assumeroleチェーンへの組み込み)の設計に合わせる |
| `notification.tf` / `dashboard.tf` / `inventory.tf` | ほぼそのまま(AWS標準サービスの組み合わせ) |
| `variables.tf` / `outputs.tf` | 社内の変数命名規則・tfvars運用に合わせて調整 |
| `backend.tf` | 社内のstate管理方式(S3バケット/キー/ロック方式)に差し替え |
| `docs/patch-mgmt-design.md` | 設計コンセプトの説明として参考にしつつ、社内版として書き直す |

---

## 5. 社内事情に合わせて決め直すべき設計判断

1. **承認日数(`approve_after_days`)**: 自宅ラボはtest=0/stg=1/prod=2日。
   社内のリリース/変更管理ポリシーに合わせて決める。
2. **ゲートの`max_age_hours`**: メンテナンスウィンドウの実施間隔に合わせる。
3. **`InstallNow`を実行できる人の範囲**: 「承認する人と実行する人が同じ」
   という前提が社内の職務分掌(SoD)要件と整合するか要確認。整合しない
   場合は`aws:approve`ステップの追加を検討。
4. **手動再起動(`RebootAndScan`)が必要な環境**: 自宅ラボはprodのみ
   `NoReboot`。社内の変更管理要件(メンテナンス時間外の再起動禁止等)に
   合わせて対象環境を決める。
5. **SSM Core権限の付与方法**: [3.1](#31-ノード登録のiamだけは要確認対象外領域との接点)参照、基盤/セキュリティ担当との合意が必要。
6. **可視化基盤**: Grafana(自宅ラボPoC)か、既存のQuickSight/社内BI
   ツールかを選定。

---

## 6. 移行ステップの提案

1. prd infra環境配下に`patch-mgmt`ディレクトリを新設、state/backendを設定
2. 対象インスタンスのSSM登録状況・権限([3.1](#31-ノード登録のiamだけは要確認対象外領域との接点))を基盤チームと確認
3. `iam.tf`を社内のAssumeRoleパターンに合わせて書き直す(`hybrid_node`削除)
4. `patch_baseline*.tf`/`maintenance_window.tf`の値を社内ポリシーに合わせて調整
5. 対象インスタンスのタグ付け(`PatchGroup`等)を既存運用に組み込む
6. 影響の小さい環境(まずは数台)で`terraform plan`→`apply`、
   スキャン・Install・ゲート・`InstallNow`・`RebootAndScan`を一通り検証
7. 問題なければ対象を広げる。本番適用前に`docs/patch-mgmt-design.md`の
   社内版を作成し、運用チームへ引き継ぐ
