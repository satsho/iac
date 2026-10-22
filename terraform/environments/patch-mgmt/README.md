# パッチ管理検証環境(environments/patch-mgmt)

**目的**: Systems Manager Patch Manager でパッチ適用を自動化しつつ、
「どのパッチを・どの順番で・誰の承認で入れたか」を説明できるガバナンスを確保する。

あわせて、Red Hat CDN → 社内リポジトリ → ミラー → 業務サーバ、という
**リポジトリ更新の流れ**そのものを検証する。

## 全体構成

```
Red Hat CDN (cdn.redhat.com / EUS 10.2)
  │
  │ reposync 毎日00:00 (NAT Gateway経由)
  ▼
[repository 10.20.1.10]  httpd + rsyncd / データ用EBS
  │
  │ rsync(873) 毎日01:00
  ▼
[infra 10.20.1.11]       httpd / データ用EBS
  │
  │ http(80) dnf
  ▼
[test] [stg] [prod]      インバウンド無し、アウトバウンドは infra とVPCエンドポイントだけ

VPC 10.20.0.0/16
  public  10.20.0.0/24 : NAT Gateway
  private 10.20.1.0/24 : 上の5台
  VPCエンドポイント     : ssm / ssmmessages / ec2messages / logs / s3(ゲートウェイ)

Systems Manager (Fleet Manager / Patch Manager / メンテナンスウィンドウ / Automation)
  └ 結果は EventBridge → SNS(メール)
```

| ファイル | 内容 |
|---|---|
| `network.tf` | VPC・サブネット・NAT・VPCエンドポイント |
| `security_group.tf` | CDN → repository → infra → 業務サーバ の一方向だけ許可 |
| `ec2.tf` / `templates/` | 5台のEC2と、起動時のセットアップ(user_data) |
| `iam.tf` | インスタンスロール、メンテナンスウィンドウ/Runbook用ロール |
| `patch_baseline.tf` | パッチベースライン・パッチグループ・毎日のスキャン |
| `maintenance_window.tf` | メンテナンスウィンドウ・ターゲット・タスク |
| `automation.tf` / `documents/` | ゲート付きパッチ適用、手動再起動、緊急パッチの各Runbook |
| `notification.tf` | EventBridge → SNS の結果通知、Run Command出力のロググループ |

## 最初に押さえておく前提(調査して分かったこと)

### 1. RHEL 10.1 以降の PAYG は「RHUI」ではなく「Red Hat CDN」を使う

RHEL 9.7 / 10.1 以降の AWS Marketplace(Red Hat 提供の PAYG)AMI は
**auto-registration v2** が既定で有効になっている。起動すると AWS アカウントに紐づく
匿名の Red Hat org に自動登録され、パッケージは RHUI ではなく **Red Hat CDN** から取ってくる。

この検証にとっての意味:

- **良い点**: repository サーバは PAYG のままで CDN から reposync できる(自前の
  サブスクリプション登録や activation key が要らない)。
- **注意点**: test/stg/prod も放っておくと CDN に直接つながり、**infra のミラーを迂回して
  パッケージを取れてしまう**。ガバナンス上これは塞ぐ必要があるので、2段構えにしている。
  1. user_data で `subscription-manager config --rhsm.manage_repos=0` を設定し、既存の repo 定義をすべて無効にして、
     `/etc/yum.repos.d/infra-mirror.repo` だけを有効にする
  2. 業務サーバのセキュリティグループのアウトバウンドを「infra の80番」「VPCエンドポイント」
     「S3」だけに絞る(`restrict_workload_egress = true`)。サーバの中で repo を有効に
     戻されても、CDN には到達できない

### 2. EUS 10.2 が PAYG(匿名org)で使えるかは未確認

AWS の RHUI 経由の PAYG は RHEL 8/9 で EUS をサポートしているが、auto-registration v2
(CDN 経由)で RHEL 10.2 の EUS リポジトリが見えるかは公式情報で確認できなかった。
**構築後に最初に確認すること**:

```bash
aws ssm start-session --target <repositoryのインスタンスID>
sudo subscription-manager identity            # 登録済みか
sudo subscription-manager repos --list | grep -A3 -i eus
sudo journalctl -u cloud-final --no-pager | tail -50   # user_data が失敗していないか
```

EUS が出てこない場合の選択肢:

| 案 | やり方 | 備考 |
|---|---|---|
| A. 自社の Red Hat org に登録し直す | EUS が含まれるサブスクリプションの activation key で `subscription-manager register --force` | PAYG と二重課金になる |
| B. 非EUSリポジトリで検証を進める | `upstream_repos` を `rhel-10-for-x86_64-baseos-rpms` 等に変更 | `rhel_release = "10.2"` のままなら 10.2 時点のコンテンツに固定される |

### 3. AMI は 10.1〜10.2 を使う

ミラーは EUS 10.2 なので、10.3 以降の AMI で業務サーバを作ると「ミラーの方が古い」状態になり更新できない。
GitHub Variables の `RHEL_AMI_ID` は RHEL 10.2 の PAYG AMI にしておく。

## リポジトリ同期の流れ

1日の流れ(時刻は `Asia/Tokyo`。変数で変更可能):

| 時刻 | どこで | 何をする |
|---|---|---|
| 00:00 | repository | `patch-reposync.timer` → CDN から reposync(`/var/www/html/repos/rhel/10.2/{baseos,appstream}`) |
| 01:00 | infra | `patch-mirror-sync.timer` → repository から rsync |
| 01:30 | 全サーバ | State Manager の関連付けで Patch Manager のスキャン(不足パッチの検出) |

ポイント:

- **updateinfo.xml を必ず持ってくる**: `dnf reposync --download-metadata` で CDN のメタデータを
  そのままコピーしている。Patch Manager は updateinfo.xml(アドバイザリ情報)を見て
  「Security 分類か」「深刻度は何か」「いつのパッチか」を判断するので、`createrepo_c` で
  メタデータを作り直すとこれが消えて **Security パッチが1件も見つからない** 状態になる。
- **infra への同期は2段階**: 1回目はパッケージ本体だけ、2回目でメタデータを差し替える。
  例えば `kernel-6.12.0-55.20` が追加される日に、同期の途中で test が `dnf` を実行しても、
  メタデータはまだ古い(`kernel-6.12.0-55.19` を指している)ので「メタデータにはあるのに
  パッケージが無い」というエラーにならない。
- **reposync 中は infra 側の同期を見送る**: repository に `.sync-in-progress` がある間は
  infra は何もしない。
- **データ用EBSはインスタンスと別リソース**: user_data を直してインスタンスを作り直しても、
  reposync 済みの数十GBを CDN から取り直さずに済む。

手動で同期したいとき(初回の構築直後など)は Run Command で実行できる:

```bash
# repositoryの同期状況(初回は数時間かかる)
aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:Role,Values=repository \
  --parameters 'commands=["systemctl status patch-reposync.service --no-pager","cat /var/www/html/repos/rhel/10.2/.last-sync"]'

# infraに今すぐ同期させる
aws ssm send-command --document-name AWS-RunShellScript \
  --targets Key=tag:Role,Values=infra \
  --parameters 'commands=["systemctl start patch-mirror-sync.service","cat /var/www/html/repos/rhel/10.2/.last-sync"]'
```

## タグ設計

| タグ | 値の例 | 使い道 |
|---|---|---|
| `Env` | `test` / `stg` / `prod` / `mgmt` | メンテナンスウィンドウのターゲット |
| `App` | `sample-app` | アプリ単位のメンテナンスウィンドウ(本番想定) |
| `RebootPolicy` | `auto` / `manual` | 自動再起動か手動再起動か |
| `PatchGroup` | `rhel10-test` など | **パッチベースラインとの紐付け**(Patch Manager が見る) |
| `Role` | `repository` / `infra` / `workload` | Run Command の対象指定など |

`PatchGroup` はスペース無しの表記を使っている(`Patch Group` でも動くが、インスタンス
メタデータからタグを読めるようにする場合はスペース無しが必須なので、こちらに揃えておく)。

メンテナンスウィンドウのターゲットは **タグを複数指定するとAND、1つのタグに値を複数書くとOR** になる:

```hcl
target_tags = { Env = ["prod"], App = ["app-a", "app-b"], RebootPolicy = ["auto"] }
# → Env=prod かつ (App=app-a または App=app-b) かつ RebootPolicy=auto のサーバ
```

## パッチベースライン

| パッチグループ | 承認 | 分類 | 深刻度 |
|---|---|---|---|
| `rhel10-test` | 0日後に自動承認 | Security | Critical / Important / Moderate / Low(=全部) |
| `rhel10-stg` | 1日後に自動承認 | 同上 | 同上 |
| `rhel10-prod` | 2日後に自動承認 | 同上 | 同上 |
| `rhel10-mgmt` | 0日後に自動承認 | 同上 | 同上(repository/infra。スキャンのみ) |

分類・深刻度に指定できる値は OS ごとに決まっている。絞り込みを変えるときは次で確認できる:

```bash
aws ssm describe-patch-properties --operating-system REDHAT_ENTERPRISE_LINUX --property CLASSIFICATION
aws ssm describe-patch-properties --operating-system REDHAT_ENTERPRISE_LINUX --property SEVERITY
```

### 注意: 「承認N日」は「前段が成功してからN日」ではない

Patch Manager の承認日数は **アドバイザリ(RHSA)の日付から数える**(updateinfo.xml の日付。
AWS のドキュメントでは更新日(Updated Date)が基準と説明されている)。前の環境の結果とは関係なく、日付だけで決まる。

例: `RHSA-2026:1234` の日付が 10/19(月)23:00 の場合

| ベースライン | いつから承認されるか |
|---|---|
| test(0日) | 10/19 23:00 から |
| stg(1日) | 10/20 23:00 から |
| prod(2日) | 10/21 23:00 から |

なので「stg は test が成功したら」「prod は stg が成功したら」という条件は、
ベースラインではなく **メンテナンスウィンドウの順番 + ゲートチェック** で実現している(次節)。

また、アドバイザリの文言修正だけでも更新日が変わり、承認までのカウントがやり直しになることがある。

## メンテナンスウィンドウ

| ウィンドウ | 日時(JST) | ターゲット | タスク | 再起動 | ゲート |
|---|---|---|---|---|---|
| `test-weekly` | 毎週火 02:00 | Env=test かつ RebootPolicy=auto | RUN_COMMAND | 自動 | なし |
| `stg-weekly` | 毎週水 02:00 | Env=stg かつ RebootPolicy=auto | AUTOMATION | 自動 | test-weekly が成功 |
| `prod-weekly` | 毎週金 02:00 | Env=prod かつ RebootPolicy=manual | AUTOMATION | 手動 | stg-weekly が成功 |

1週間の流れの例(10/20 の週):

```
10/19(月) 23:00  RHSA-2026:1234 公開
10/20(火) 00:00  repositoryがreposync → 01:00 infraがrsync → 01:30 全台スキャン
          02:00  test-weekly : test(0日)は承認済み → インストール・自動再起動 → SUCCESS
10/21(水) 02:00  stg-weekly  : ゲート「test-weekly が48時間以内にSUCCESS?」→ OK
                               stg(1日)も承認済み → インストール・自動再起動
10/23(金) 02:00  prod-weekly : ゲート「stg-weekly が72時間以内にSUCCESS?」→ OK
                               prod(2日)も承認済み → インストール(再起動はしない)
          日中   運用者が都合の良いタイミングで RebootAndScan を実行
```

ウィンドウは `maintenance_windows` 変数で定義しているので、アプリごとの時間帯を足すときは
エントリを増やすだけでよい(`terraform.tfvars.example` に例あり)。

検証中に「今すぐウィンドウを動かしたい」場合、メンテナンスウィンドウには即時実行が無いので、
`schedule` を一回限りの `at(2026-10-23T15:00:00)` に一時的に変えて apply する。

### タスクの種類の比較

| 種類 | 向いている用途 | 今回 |
|---|---|---|
| **RUN_COMMAND**(`AWS-RunPatchBaseline`) | パッチを当てるだけ。設定が一番シンプルで、台数ごとの同時実行数・エラー閾値も使える | test |
| RUN_COMMAND(`AWS-RunPatchBaselineWithHooks`) | 適用前後に任意のコマンド(アプリ停止・ヘルスチェック等)を挟みたい | 候補 |
| **AUTOMATION**(自作Runbook) | 「前段の成功を確認してから」「適用後に検証する」など、複数ステップの判断が必要 | stg / prod |
| LAMBDA | AWS API を使った独自処理(例: 外部チケットシステムへの登録) | 不使用 |
| STEP_FUNCTIONS | 複数のRunbook・待機・分岐をまたぐ長いワークフロー | 不使用 |

test は条件が無いので RUN_COMMAND、stg/prod は前段の確認が要るので AUTOMATION にしている。

### ゲート(前段ステージの成功確認)

`documents/gated-patch-baseline.yaml` の最初のステップで、次の2点を確認してからパッチを当てる。

1. 前段のメンテナンスウィンドウの **直近の実行が `max_age_hours` 以内に SUCCESS** で終わっている
2. 前段のパッチグループのサーバに **適用失敗(Failed)と再起動待ち(InstalledPendingReboot)が残っていない**

例: 火曜の test でパッチ適用が失敗した場合

```
火 02:00 test-weekly  → FAILED            → SNSに「test-weekly が FAILED」
水 02:00 stg-weekly   → ゲートで中止        → SNSに「GatedPatchBaseline が Failed」
                         (理由: test-weekly の直近の実行が FAILED)
金 02:00 prod-weekly  → ゲートで中止        (理由: stg-weekly の直近の実行が FAILED)
```

ゲートで分からないこと: 「stg に入るパッチが、すべて test にも入っていたか」までは見ていない。
例えば古い日付のパッチが火曜の test の後にミラーへ届くと、水曜の stg では承認済みなので
test を経由せずに入ってしまう。これを防ぐ方法は2つある。

- **ミラーの更新を週1回にする**: `reposync_schedule` / `mirror_sync_schedule` を月曜だけにすると、
  火〜金の間はミラーの中身が変わらないので、test → stg → prod に同じパッチの組み合わせが流れる。
- **`approve_until_date` で日付を揃える**: test で確認したアドバイザリの日付までを stg/prod で
  承認する(`terraform.tfvars.example` に例あり)。変更を PR で行えば、その PR が承認記録になる。

## 再起動の2パターン

| パターン | 設定 | パッチ適用後の状態 |
|---|---|---|
| 自動 | `RebootOption = RebootIfNeeded` | 必要なら Patch Manager が再起動し、再起動後のスキャンまで自動で行う |
| 手動 | `RebootOption = NoReboot` | パッケージは入るが **InstalledPendingReboot(再起動待ち)** になり、コンプライアンス上は非準拠のまま |

手動パターンの再起動は `RebootAndScan` Runbook で行う。EC2 コンソールから再起動しただけだと、
次のスキャン(翌日 01:30)まで Patch Manager 上は再起動待ちのまま残り、次のステージの
ゲートも通らない。Runbook は「再起動 → スキャン」までまとめて行う。

```bash
# prodを1台ずつ再起動する(タグで対象を選び、同時実行1台・1台でも失敗したら止める)
aws ssm start-automation-execution \
  --document-name iac-poc-patch-RebootAndScan \
  --targets Key=tag:Env,Values=prod \
  --target-parameter-name InstanceId \
  --max-concurrency 1 --max-errors 0
```

なお、再起動待ちが残ったサーバに `RebootIfNeeded` で次のパッチ適用を行うと、そのときに再起動される。

## 緊急パッチ

メンテナンスウィンドウやゲートを待たずに当てる手段。どちらも `EmergencyPatch` Runbook を使い、
**実行前に承認者の承認(`aws:approve`)を必須**にしている。承認依頼は SNS でメールが届き、
コンソールの Automation 実行画面から承認・却下する。

### A. ベースラインの承認リストに追加して当てる(推奨)

1. `patch_baselines` の `approved_patches` に `RHSA-2026:12345` を追加する PR を作る
   (承認リストに載ったパッチは承認日数を待たずに承認される)
2. PR がマージされたら apply
3. test → stg → prod の順に Runbook を実行する

```bash
aws ssm start-automation-execution \
  --document-name iac-poc-patch-EmergencyPatch \
  --parameters 'TargetTagKey=PatchGroup,TargetTagValues=rhel10-test,Approvers=arn:aws:iam::123456789012:role/admin'
```

「何を・なぜ緊急で入れたか」が PR として残り、「誰が承認して実行したか」が Automation の
実行履歴と CloudTrail に残る。

### B. InstallOverrideList でパッケージを直接指定する

ベースラインを変えずに、インストールするパッケージを YAML に書いて S3 に置き、URL を
`InstallOverrideList` に渡す。リストに書いたパッチがベースラインの代わりに使われる。

```yaml
# s3://<bucket>/emergency/openssl.yaml (書式は AWS ドキュメントで要確認)
patches:
  - id: 'openssl.x86_64'
  - id: 'openssl-libs.x86_64'
```

コンプライアンスの判定は引き続きベースライン基準なので、A の方が後から状態を説明しやすい。

## 成功・失敗の管理

| どこで見るか | 内容 |
|---|---|
| SNS(メール) | EventBridge で拾った以下のイベント |
| ・メンテナンスウィンドウ | このスタックのウィンドウの実行が SUCCESS / FAILED / TIMED_OUT / CANCELLED で終わった |
| ・Runbook | ゲート付き適用・手動再起動・緊急パッチの実行が Success / Failed / TimedOut / Cancelled で終わった |
| ・コンプライアンス | サーバがパッチ非準拠に**変わった**とき(状態が変わった時だけ通知される) |
| メンテナンスウィンドウの履歴 | ウィンドウ → タスク → サーバごとの結果 |
| CloudWatch Logs `/iac-poc-patch/run-command` | AWS-RunPatchBaseline の出力(どのパッケージが入ったか) |
| Patch Manager のダッシュボード | パッチグループ・サーバごとのコンプライアンス |

## 構築手順

1. **Terraform 実行ロールに権限を足す**: この環境は SSM・EventBridge・SNS・CloudWatch Logs を
   作るので、`terraform/iam/terraform-role.yaml` の `github-actions-terraform` ロールに
   `ssm:*` / `events:*` / `sns:*` / `logs:*` が必要(今回の変更には含めていない)
2. GitHub Variables を設定する
   - `RHEL_AMI_ID`: RHEL 10.2 の PAYG AMI(既存の変数を流用)
   - `PATCH_NOTIFICATION_EMAIL`: 通知先メールアドレス(任意)
3. `Terraform Patch Management (patch-mgmt)` ワークフローを `plan` → `apply` で実行
4. SNS から届く確認メールのリンクを踏む
5. Fleet Manager に5台が表示されることを確認する
6. repository の EUS リポジトリと reposync の進み具合を確認する(「前提 2.」のコマンド)
7. reposync が終わったら infra に同期させる(「リポジトリ同期の流れ」のコマンド)
8. State Manager の関連付け `iac-poc-patch-daily-scan` を「今すぐ適用」し、
   Patch Manager のダッシュボードにコンプライアンスが出ることを確認する
9. 業務サーバから mirror を使えていることを確認する

```bash
aws ssm start-session --target <testのインスタンスID>
dnf repolist                         # infra-baseos / infra-appstream だけが有効
dnf updateinfo list --security       # Security アドバイザリが見えればupdateinfoも同期できている
curl -m 5 -sI https://cdn.redhat.com # 業務サーバからはCDNに出られない(タイムアウトする)
```

## コストと後片付け

NAT Gateway、インターフェイスエンドポイント4つ、PAYG の RHEL 5台、ミラー用 EBS 100GB×2 が
時間課金でかかる。使わない間は `destroy` しておく(データ用 EBS も消えるので、
次回は reposync を最初からやり直すことになる)。エンドポイント代を節約したい場合は
`restrict_workload_egress = false`(業務サーバの出口制限は repo 設定だけになる)。

## 追加で使えそうなサービス

| サービス | 使いどころ | 優先度 |
|---|---|---|
| Amazon Inspector(EC2スキャン) | SSM Agent 経由で各サーバの CVE を検出する。「どの脆弱性が残っているか・緊急パッチが要るか」の判断材料になり、Patch Manager(当てる側)と役割が分かれる | 高 |
| AWS Config(`ec2-managedinstance-patch-compliance-status-check`) | パッチ準拠状況の**履歴**を残す。監査で「いつ時点で準拠していたか」を示せる | 高 |
| Change Calendar(Systems Manager) | 年末年始などの変更凍結期間を定義し、その間はパッチ適用を止める | 中 |
| Inventory + Resource Data Sync → Athena | 全サーバのパッケージ一覧を S3 に集約し、「この kernel が入っているサーバ」を SQL で引ける | 中 |
| Patch Manager のコンプライアンスレポート | 準拠状況を CSV で定期的に S3 に出力する(報告書向け) | 中 |
| Resource Groups | タグ条件に名前を付けて(例: `prod-app-a`)、メンテナンスウィンドウや Run Command のターゲットに使い回す | 中 |
| AWS Backup / 適用前のEBSスナップショット | 失敗時の切り戻し手段。ゲート付き Runbook に1ステップ足せば自動化できる | 中 |
| Step Functions + EventBridge Scheduler | 「test 成功のイベントから**ちょうど1日後**に stg を流す」のようなイベント駆動の昇格 | 低(今回は曜日固定で代替) |
| Quick Setup のパッチポリシー | 複数アカウント・リージョンに一括でパッチ設定を配る。設定は簡単だが、段階適用やゲートの細かい制御には向かない | 低 |

Systems Manager **Change Manager** は 2025/11/7 以降、新規の利用受付を終了しているため候補から外している。
変更承認は「ベースライン変更は GitHub の PR」「緊急実行は Runbook の `aws:approve`」で代替している。

## これから詰める点

- EUS 10.2 が PAYG(匿名org)で使えるか → 使えなければ「前提 2.」のどちらで進めるか
- 承認の考え方: 承認日数(日付基準)のままでよいか、ミラーの週1凍結や `approve_until_date` で「同じパッチを順番に流す」形にするか
- 再起動パターンの割り当て: 今は test/stg が自動、prod が手動
- アプリ単位のウィンドウのタグ設計: `App` タグで分けるか、`MaintenanceWindow=weekday-night` のようにウィンドウ名をタグに直接持たせるか
- 緊急パッチの承認者と、Runbook を実行できる人(IAM)の範囲
- 通知先: メールのままか、Slack(Amazon Q Developer in chat applications)に流すか
