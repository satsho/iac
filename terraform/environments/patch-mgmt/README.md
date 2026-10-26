# パッチ管理検証環境(environments/patch-mgmt)

**目的**: Systems Manager Patch Manager でパッチ適用を自動化しつつ、
「どのパッチを・どの順番で・誰の承認で入れたか」を説明できるガバナンスを確保する。

あわせて、Red Hat CDN → 社内リポジトリ → ミラー → 業務サーバ、という
**リポジトリ更新の流れ**そのものを検証する。

サーバ(RHEL 10.2 × 5台)は **家のサーバの KVM 上の VM** として作り、
**SSM Hybrid Activation** で Systems Manager に登録して AWS から管理する。

| 置き場所 | 中身 | 実行方法 |
|---|---|---|
| `terraform/environments/patch-mgmt/`(ここ) | AWS側: パッチベースライン・メンテナンスウィンドウ・Runbook・通知・VM用IAMロール | GitHub Actions(`terraform-patch-mgmt.yml`) |
| [`ansible/patch-mgmt/`](../../../ansible/patch-mgmt/README.md) | 家のサーバ側: libvirtネットワーク・VM・cloud-init(リポジトリ同期・プロキシ・SSM登録) | 家のサーバで `ansible-playbook` |

## 全体構成

```
Red Hat CDN (cdn.redhat.com / EUS 10.2)
  │
  │ reposync 毎日00:00
  ▼
[patch-repository 192.168.150.10]  httpd + rsyncd / ミラー用データディスク
  │
  │ rsync(873) 毎日01:00
  ▼
[patch-infra 192.168.150.11 / 192.168.151.11]  httpd(ミラー) + squid(プロキシ) + chrony(NTP)
  │
  │ http(80) dnf
  ▼
[patch-test] [patch-stg] [patch-prod]  192.168.151.21〜23
  外へのルーティング無し。外に出られるのは infra のプロキシ経由で
  SSM・CloudWatch Logs・S3・RHSM 登録の宛先だけ(cdn.redhat.com は拒否)

家のサーバ(KVMホスト)
  patch-mgmt     192.168.150.0/24 : NAT。repository / infra がインターネットに出る
  patch-workload 192.168.151.0/24 : 隔離。業務VMと infra の2枚目のNIC

Systems Manager(Fleet Manager / Patch Manager / メンテナンスウィンドウ / Automation)
  各VMは Hybrid Activation で mi-xxxxxxxx のマネージドノードとして登録される
  └ 結果は EventBridge → SNS(メール)
```

| ファイル | 内容 |
|---|---|
| `iam.tf` | VM(Hybrid Activation)用ロール、メンテナンスウィンドウ/Runbook用ロール |
| `patch_baseline.tf` | パッチベースライン・パッチグループ・毎日のスキャン |
| `maintenance_window.tf` | メンテナンスウィンドウ・ターゲット・タスク |
| `automation.tf` / `documents/` | ゲート付きパッチ適用、手動再起動、緊急パッチの各Runbook |
| `notification.tf` | EventBridge → SNS の結果通知、Run Command出力のロググループ |

## 最初に押さえておく前提

### 1. VMはSSM Hybrid Activationで登録する(家のサーバ本体と同じ仕組み)

EC2 ではないので、インスタンスプロファイルの代わりに **アクティベーション** で SSM に登録する。
Ansible が VM を作るたびに、その VM 専用のアクティベーション(登録1回限り)をタグ付きで作り、
cloud-init の中で `amazon-ssm-agent -register` する。

- アクティベーションに付けたタグは、登録したノードにそのまま付く。
  例: `patch-test` 用のアクティベーションに `Env=test, PatchGroup=rhel10-test` を付けると、
  登録された `mi-0123...` にも同じタグが付き、メンテナンスウィンドウやパッチグループの対象になる
- VM が引き受けるロールは家のサーバ本体のもの(`environments/dns` の `ssm-hybrid-activation`、
  Route53 などの権限付き)とは分けて、`iac-poc-patch-hybrid-node-role`(SSM とログ出力だけ)にしている
- 家のサーバ本体には `PatchGroup` タグが無いので、このスタックのスキャンやパッチ適用の対象にはならない

### 2. Session Manager は有料の advanced-instances tier が必要

EC2 以外のノードに Session Manager でつなぐには **advanced-instances tier** が必要
(ノード数 × 時間で課金)。Patch Manager・Run Command・メンテナンスウィンドウ・Automation は
無料の standard tier で使えるので、この検証は standard のまま進められる。

tier は **アカウント・リージョン単位の設定** なので、advanced にすると家のサーバ本体も
課金対象になる点に注意。VM の中に入るときは、家のサーバから SSH(`cloud-user`)するか
`virsh console` を使う。

### 3. 業務VMは「外に出られない」+「プロキシで必要な宛先だけ通す」

AWS では VPC エンドポイントで SSM を閉域から使えたが、家のサーバでは SSM の宛先は
インターネット上にしかない。そこで業務VMは外へのルーティングが無い隔離ネットワークに置き、
**infra の squid(フォワードプロキシ)が許可した宛先にだけ** 出られるようにしている。

| 宛先 | 用途 | 業務VMから |
|---|---|---|
| `ssm` / `ssmmessages` / `ec2messages` | SSM Agent | 許可 |
| `logs` | Run Command 出力 | 許可 |
| `*.s3.ap-northeast-1.amazonaws.com` | SSM Agent 本体、パッチ処理用ファイル | 許可 |
| `subscription.rhsm.redhat.com` | RHSM 登録 | 許可 |
| `cdn.redhat.com` などそれ以外 | — | **拒否**(infra の `/var/log/squid/access.log` に記録が残る) |

パッケージは infra のミラーから直接 http で取る(プロキシは通さない)。業務VMは外の NTP にも
出られないので、時刻は infra(chrony)に合わせている。時刻がずれると AWS API の署名が通らず、
SSM が使えなくなるため。

### 4. サブスクリプションとEUS

KVM 上の VM は PAYG ではないので、5台とも自分の Red Hat アカウントの activation key で
RHSM に登録する(Developer Subscription for Individuals なら16台まで)。
業務VMも登録はするが、`manage_repos=0` にして CDN のリポジトリは使わせない。

**EUS がそのサブスクリプションに含まれているかは未確認**。構築後に repository で確認する:

```bash
ssh cloud-user@192.168.150.10        # 家のサーバから
sudo subscription-manager repos --list | grep -A3 -i eus
sudo tail -50 /var/log/cloud-init-output.log   # user-data が途中で失敗していないか
```

EUS が見えない場合は、`ansible/patch-mgmt/vars.yml` の `upstream_repos` を
`rhel-10-for-x86_64-baseos-rpms` / `rhel-10-for-x86_64-appstream-rpms` に変えて
repository と infra を作り直す(`rhel_release: "10.2"` のままなら 10.2 時点のコンテンツに固定される)。

### 5. ゲストイメージは 10.2 を使う

ミラーは EUS 10.2 なので、10.3 以降のイメージで業務VMを作ると「ミラーの方が古い」状態になり
更新できない。Red Hat Customer Portal から **RHEL 10.2 の KVM Guest Image** を使う。
また RHEL 10 は CPU が x86-64-v3(AVX2 など)に対応している必要がある(playbook で確認している)。

## リポジトリ同期の流れ

1日の流れ(時刻は `Asia/Tokyo`。`ansible/patch-mgmt/vars.yml` で変更可能):

| 時刻 | どこで | 何をする |
|---|---|---|
| 00:00 | repository | `patch-reposync.timer` → CDN から reposync(`/var/www/html/repos/rhel/10.2/{baseos,appstream}`) |
| 01:00 | infra | `patch-mirror-sync.timer` → repository から rsync |
| 01:30 | 全VM | State Manager の関連付けで Patch Manager のスキャン(不足パッチの検出) |

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
- **ミラー用データディスクは VM と別の qcow2**: VM を作り直しても、reposync 済みの数十GBを
  CDN から取り直さずに済む。

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

タグは `ansible/patch-mgmt/vars.yml` の VM 定義に書き、アクティベーション経由でマネージドノードに付く。
`PatchGroup` の値は、このディレクトリの `patch_baselines` のキー(`rhel10-<キー>`)と一致させる。

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

- **ミラーの更新を週1回にする**: `vars.yml` の `reposync_schedule` / `mirror_sync_schedule` を月曜だけにすると、
  火〜金の間はミラーの中身が変わらないので、test → stg → prod に同じパッチの組み合わせが流れる。
- **`approve_until_date` で日付を揃える**: test で確認したアドバイザリの日付までを stg/prod で
  承認する(`terraform.tfvars.example` に例あり)。変更を PR で行えば、その PR が承認記録になる。

## 再起動の2パターン

| パターン | 設定 | パッチ適用後の状態 |
|---|---|---|
| 自動 | `RebootOption = RebootIfNeeded` | 必要なら Patch Manager が再起動し、再起動後のスキャンまで自動で行う |
| 手動 | `RebootOption = NoReboot` | パッケージは入るが **InstalledPendingReboot(再起動待ち)** になり、コンプライアンス上は非準拠のまま |

手動パターンの再起動は `RebootAndScan` Runbook で行う。`virsh reboot` や VM の中で再起動しただけだと、
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
2. GitHub Variables に `PATCH_NOTIFICATION_EMAIL`(通知先メールアドレス、任意)を設定する
3. `Terraform Patch Management (patch-mgmt)` ワークフローを `plan` → `apply` で実行
4. SNS から届く確認メールのリンクを踏む
5. 家のサーバで VM を作る([`ansible/patch-mgmt/README.md`](../../../ansible/patch-mgmt/README.md))
6. Fleet Manager に5台(`mi-...`)が表示され、タグが付いていることを確認する
7. repository の EUS リポジトリと reposync の進み具合を確認する(「前提 4.」「リポジトリ同期の流れ」)
8. reposync が終わったら infra に同期させる(「リポジトリ同期の流れ」のコマンド)
9. State Manager の関連付け `iac-poc-patch-daily-scan` を「今すぐ適用」し、
   Patch Manager のダッシュボードにコンプライアンスが出ることを確認する
10. 業務VMがミラーだけを使い、CDN には出られないことを確認する

```bash
ssh cloud-user@192.168.151.21        # 家のサーバから patch-test へ
dnf repolist                         # infra-baseos / infra-appstream だけが有効
dnf updateinfo list --security       # Security アドバイザリが見えればupdateinfoも同期できている
curl -m 5 -sI --proxy http://192.168.151.11:3128 https://cdn.redhat.com   # 403(プロキシが拒否)
curl -m 5 -sI https://cdn.redhat.com # 直接は経路が無いので失敗する
```

## コストと後片付け

AWS 側は standard tier の SSM・メンテナンスウィンドウ・Automation・EventBridge・SNS・CloudWatch Logs
だけなので、ほぼ無料枠に収まる(Session Manager を使うために advanced-instances tier にした場合だけ
ノード数 × 時間の課金がかかる)。

家のサーバ側はメモリ 2GB × 5台と、ミラー用データディスク(repository と infra に同じ中身が入るので
同期したリポジトリのサイズ × 2)を使う。VM を消すときは `ansible/patch-mgmt/destroy.yml` を使うと、
SSM のマネージドノードと RHSM の登録も一緒に解除される。

## 追加で使えそうなサービス

| サービス | 使いどころ | 優先度 |
|---|---|---|
| Red Hat Insights(console.redhat.com) | RHSM に登録した VM の CVE・推奨対応を一覧できる(サブスクリプションに含まれる)。「緊急パッチが要るか」の判断材料になる。Amazon Inspector のドキュメントは EC2 を対象にしており、オンプレの VM はスキャン対象外とみられる(要確認)ので、こちらが代わりになる。業務VMで使う場合はプロキシの許可先に Insights の宛先を足す | 高 |
| AWS Config(`ec2-managedinstance-patch-compliance-status-check`) | パッチ準拠状況の**履歴**を残す。監査で「いつ時点で準拠していたか」を示せる。ハイブリッドのノードも記録できるかは要確認 | 中 |
| Change Calendar(Systems Manager) | 年末年始などの変更凍結期間を定義し、その間はパッチ適用を止める | 中 |
| Inventory + Resource Data Sync → Athena | 全VMのパッケージ一覧を S3 に集約し、「この kernel が入っているVM」を SQL で引ける | 中 |
| Patch Manager のコンプライアンスレポート | 準拠状況を CSV で定期的に S3 に出力する(報告書向け) | 中 |
| Resource Groups | タグ条件に名前を付けて(例: `prod-app-a`)、メンテナンスウィンドウや Run Command のターゲットに使い回す | 中 |
| 適用前の VM スナップショット | 失敗時の切り戻し手段。KVM ホストで `virsh snapshot-create-as` を取ってから当てる(家のサーバ本体も SSM 管理下なので、Run Command で実行できる) | 中 |
| Step Functions + EventBridge Scheduler | 「test 成功のイベントから**ちょうど1日後**に stg を流す」のようなイベント駆動の昇格 | 低(今回は曜日固定で代替) |

Systems Manager **Change Manager** は 2025/11/7 以降、新規の利用受付を終了しているため候補から外している。
変更承認は「ベースライン変更は GitHub の PR」「緊急実行は Runbook の `aws:approve`」で代替している。

## これから詰める点

- 使っているサブスクリプションに EUS が含まれるか → 含まれなければ非EUSで進めるか
- 承認の考え方: 承認日数(日付基準)のままでよいか、ミラーの週1凍結や `approve_until_date` で「同じパッチを順番に流す」形にするか
- Session Manager を使うために advanced-instances tier にするか(家のサーバ本体も課金対象になる)
- 再起動パターンの割り当て: 今は test/stg が自動、prod が手動
- アプリ単位のウィンドウのタグ設計: `App` タグで分けるか、`MaintenanceWindow=weekday-night` のようにウィンドウ名をタグに直接持たせるか
- 緊急パッチの承認者と、Runbook を実行できる人(IAM)の範囲
- 通知先: メールのままか、Slack(Amazon Q Developer in chat applications)に流すか
