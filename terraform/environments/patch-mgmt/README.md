# パッチ管理検証環境(environments/patch-mgmt)

**目的**: Systems Manager Patch Manager でパッチ適用を自動化しつつ、
「どのパッチを・どの順番で・誰の承認で入れたか」を説明できるガバナンスを確保する。

あわせて、Red Hat CDN → 社内リポジトリ → ミラー → 業務サーバ、という
**リポジトリ更新の流れ**そのものを検証する。

サーバ(RHEL 10.2 × 5台)は **家のサーバの KVM 上の VM** として Image Builder の ISO から作り、
**SSM Hybrid Activation** で Systems Manager に登録して AWS から管理する。VM の中の設定は
Ansible が SSH で行い、人が入るときも SSH(外出先からは Tailscale 経由)を使う。

| 置き場所 | 中身 | 実行方法 |
|---|---|---|
| `terraform/environments/patch-mgmt/`(ここ) | AWS側: パッチベースライン・メンテナンスウィンドウ・Runbook・通知・VM用IAMロール | GitHub Actions(`terraform-patch-mgmt.yml`) |
| [`ansible/patch-mgmt/`](../../../ansible/patch-mgmt/README.md) | 家のサーバ側: libvirtネットワーク・VM(ISOからインストール)・業務VM向けの仮想FW・VMの中の設定(リポジトリ同期・SSM登録) | 家のサーバで `ansible-playbook` |

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
[patch-infra 192.168.150.11 / 192.168.151.11]  httpd(ミラー)
  │
  │ http(80) dnf
  ▼
[patch-test] [patch-stg] [patch-prod]  192.168.151.21〜23
  外に出られるのは、KVMホストの仮想FW(nftables)が許可した
  SSM・CloudWatch Logs・S3・RHSM 登録・NTP の宛先だけ(cdn.redhat.com は拒否)

家のサーバ(KVMホスト)
  patch-mgmt     192.168.150.0/24 : NAT。repository / infra がインターネットに出る
  patch-workload 192.168.151.0/24 : NAT + 仮想FW。業務VMと infra の2枚目のNIC

Systems Manager(Fleet Manager / Patch Manager / メンテナンスウィンドウ / Automation)
  各VMは Hybrid Activation で mi-xxxxxxxx のマネージドノードとして登録される
  ├ 結果は EventBridge → SNS(メール)
  └ 準拠状況・CVE・実行履歴は CloudWatch ダッシュボード(1時間ごとに集計)
```

| ファイル | 内容 |
|---|---|
| `iam.tf` | VM(Hybrid Activation)用ロール、メンテナンスウィンドウ/Runbook用ロール |
| `patch_baseline.tf` | パッチベースライン・パッチグループ・毎日のスキャン |
| `maintenance_window.tf` | メンテナンスウィンドウ・ターゲット・タスク |
| `automation.tf` / `documents/` | ゲート付きパッチ適用、手動再起動、緊急パッチの各Runbook |
| `notification.tf` | EventBridge → SNS の結果通知、Run Command出力のロググループ |
| `dashboard.tf` / `documents/collect-patch-compliance.yaml` | 準拠状況・CVEの集計(1時間ごと)と CloudWatch ダッシュボード |

## 最初に押さえておく前提

### 1. VMはSSM Hybrid Activationで登録する(家のサーバ本体と同じ仕組み)

家のサーバの VM は **アクティベーション**(Hybrid Activation)で SSM に登録する。
Ansible が SSM Agent をまだ登録していない VM を見つけると、その VM 専用のアクティベーション
(登録1回限り)をタグ付きで作り、SSH で `amazon-ssm-agent -register` する。

- アクティベーションに付けたタグは、登録したノードにそのまま付く。
  例: `patch-test` 用のアクティベーションに `Env=test, PatchGroup=rhel10-test` を付けると、
  登録された `mi-0123...` にも同じタグが付き、メンテナンスウィンドウやパッチグループの対象になる
- VM が引き受けるロールは家のサーバ本体のもの(`environments/dns` の `ssm-hybrid-activation`、
  Route53 などの権限付き)とは分けて、`iac-poc-patch-hybrid-node-role`(SSM とログ出力だけ)にしている
- 家のサーバ本体には `PatchGroup` タグが無いので、このスタックのスキャンやパッチ適用の対象にはならない
- アクティベーションのタグは登録時にしか付かないので、Ansible は流すたびに `vars.yml` のタグで
  マネージドノードのタグを上書きする(タグの正は `vars.yml`)

### 2. Session Manager は使わず SSH で管理する

家のサーバの VM(オンプレのノード)に Session Manager でつなぐには、有料の **advanced-instances tier** が必要になる
(アカウント・リージョン単位の設定なので、家のサーバ本体も課金対象になる)。この検証では使わず、
**SSH**(家のサーバを踏み台にする。外出先からは Tailscale で家のサーバに入る)で管理する。
Patch Manager・Run Command・メンテナンスウィンドウ・Automation は無料の standard tier で使える。

### 3. 業務VMは「仮想FW」で必要な宛先だけ外に出す

業務VMを SSM で管理するには、SSM の宛先(インターネット上にある)へ出られる必要がある。
そこで業務VMのネットワーク(`patch-workload`)は外に出られる設定(libvirt の NAT。家のサーバが VM の通信を
中継する方式)にしたうえで、**KVMホストの nftables を仮想FWにして、許可したドメイン宛ての通信だけを通す**。

| 宛先 | 用途 | 業務VMから |
|---|---|---|
| `ssm` / `ssmmessages` / `ec2messages`(TCP 443) | SSM Agent(`ec2messages` は SSM Agent の通信先の名前で、EC2 は使っていない) | 許可 |
| `logs`(TCP 443) | Run Command 出力 | 許可 |
| `s3.ap-northeast-1.amazonaws.com` とそのサブドメイン(TCP 443) | SSM Agent 本体、パッチ処理用ファイル | 許可 |
| `subscription.rhsm.redhat.com`(TCP 443) | RHSM 登録(ISO の自動登録) | 許可 |
| `rhel.pool.ntp.org`(UDP 123) | 時刻同期(ずれると AWS API の署名が通らない) | 許可 |
| `cdn.redhat.com`、家の LAN、それ以外すべて | — | **拒否**(KVMホストのカーネルログに `patch-mgmt-fw drop:` が残る) |

nftables は IP アドレスでしか判定できないので、ドメインは DNS と組み合わせて扱っている。

```
業務VM が ssm.ap-northeast-1.amazonaws.com を名前解決
  → libvirt の dnsmasq(業務VMの DNS サーバ)が答えを返すと同時に、
    返した IP を nftables の許可リスト(set)に入れる(dnsmasq の nftset 機能)
  → その IP への TCP 443 だけ、KVMホストを通過できる
業務VM が cdn.redhat.com を名前解決
  → 名前は引けるが、許可リストには入らないので通信は KVMホストで落ちる
```

パッケージは infra のミラー(同じネットワーク上の 192.168.151.11)から直接 http で取るので、
仮想FWは通らない。許可するドメインは `ansible/patch-mgmt/vars.yml` の `workload_egress_allowlist` で変えられる。

### 4. サブスクリプションとEUS

5台とも、自分の Red Hat アカウントのサブスクリプションで RHSM に登録する
(Developer Subscription for Individuals なら16台まで)。

- ゴールデンイメージ(`ansible/patch-mgmt/packer/`)は未登録の状態にしてあるので、5台とも
  クローン後にAnsibleが環境変数の activation key(`RHEL_ORG_ID` / `RHEL_ACTIVATION_KEY`)で登録する
  (業務VMも、仮想FWで `subscription.rhsm.redhat.com` だけは通している)
- repository/infraはキーが無いと登録タスクで失敗する(必須)。業務VMはキーが無ければ警告だけ出して
  先に進む(パッチはミラーから当てるので検証は進められる)
- 業務VMは `manage_repos=0` にして、CDN のリポジトリは使わせない(仮想FWでも CDN には届かない)

**EUS がそのサブスクリプションに含まれているかは未確認**。構築後に repository で確認する:

```bash
ssh patch-repository        # ansible/patch-mgmt/README.md の ~/.ssh/config の例を参照
sudo subscription-manager repos --list | grep -A3 -i eus
```

EUS が見えない場合は Ansible の「Enable only the repositories that are mirrored」で失敗する。
`ansible/patch-mgmt/vars.yml` の `upstream_repos` を `rhel-10-for-x86_64-baseos-rpms` /
`rhel-10-for-x86_64-appstream-rpms` に変えて流し直す(`rhel_release: "10.2"` のままなら
10.2 時点のコンテンツに固定される)。

### 5. ISO は 10.2 で作る

ミラーは EUS 10.2 なので、10.3 以降で業務VMを作ると「ミラーの方が古い」状態になり
更新できない。Image Builder の ISO は **RHEL 10.2** で作る。
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

手動で同期したいとき(初回の構築直後など)は、SSH で入って `systemctl start` するか、
Run Command で実行する:

```bash
# SSHの場合
ssh patch-repository 'systemctl status patch-reposync.service --no-pager; cat /var/www/html/repos/rhel/10.2/.last-sync'
ssh patch-infra 'sudo systemctl start patch-mirror-sync.service'
```


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

## 成功・失敗の管理とダッシュボード

| どこで見るか | 内容 |
|---|---|
| SNS(メール) | EventBridge で拾った以下のイベント |
| ・メンテナンスウィンドウ | このスタックのウィンドウの実行が SUCCESS / FAILED / TIMED_OUT / CANCELLED で終わった |
| ・Runbook | ゲート付き適用・手動再起動・緊急パッチの実行が Success / Failed / TimedOut / Cancelled で終わった |
| ・コンプライアンス | VMがパッチ非準拠に**変わった**とき(状態が変わった時だけ通知される) |
| CloudWatch ダッシュボード `iac-poc-patch-status` | いまの状態: VMごとの準拠状況、未適用・失敗・再起動待ちのパッチとCVE |
| CloudWatch ダッシュボード `iac-poc-patch-history` | 推移と実行履歴: 環境ごとの未適用パッチ数のグラフ、ウィンドウ・Runbookの結果 |
| Patch Manager の画面 | 標準のダッシュボード・コンプライアンスレポート(パッチごとの詳細) |
| CloudWatch Logs `/iac-poc-patch/run-command` | AWS-RunPatchBaseline の出力(どのパッケージが入ったか) |

### ダッシュボードの仕組み

Patch Manager の標準画面でも準拠状況やパッチごとの CVE は見られるが、「環境ごと(test/stg/prod)に
並べる」「CVE を全VM分まとめて一覧する」「推移を見る」はできないので、集計して CloudWatch に
ダッシュボードを作っている。

```
EventBridge Scheduler(毎時10分)
  └ Runbook CollectPatchCompliance
      ├ Patch Manager の API でVMごとの件数と、未適用・失敗・再起動待ちのパッチ(CVE ID付き)を取得
      ├ CloudWatch Logs /iac-poc-patch/compliance に1行1レコードで書く → ダッシュボードの表
      └ CloudWatch メトリクス(Env 別の件数)を書く                    → ダッシュボードのグラフ
EventBridge(ウィンドウ・Runbook・コンプライアンスのイベント)
  └ CloudWatch Logs /iac-poc-patch/events にそのまま書く              → 実行履歴の表
```

例: 月曜に `openssl-libs` の RHSA が出て、その週のウィンドウで順に当たる場合
(status ダッシュボードの「未適用・失敗・再起動待ちのパッチとCVE」の見え方)

| 時刻 | 何が起きるか | ダッシュボードの表 |
|---|---|---|
| 火 01:30 | 全台のスキャンで未適用を検出 | 02:10 の集計で test / stg / prod に `openssl-libs ... / Missing / Important / CVE-2026-xxxx` が出る |
| 火 02:00 | test-weekly が test に適用(結果は Patch Manager に報告される) | 次の集計で test の行が消える |
| 水 02:00 | stg-weekly が stg に適用 | 次の集計で stg の行が消える |
| 金 02:00 | prod-weekly が prod に適用(再起動は手動) | prod の行は `InstalledPendingReboot` に変わって残る |
| 金 日中 | 運用者が `RebootAndScan` を実行 | 次の集計で prod の行も消える |

CVE ID は Patch Manager の仕様で **未適用(Missing)と失敗(Failed)のパッチにだけ** 付く。
再起動待ちのパッチは CVE 欄が空になる。

status ダッシュボードは「直近1時間」で見る前提にしている。範囲を広げると、その後に適用されて
消えたパッチも古い行として残って見える(`CollectedAt` 列で集計時刻が分かる)。

## 構築手順

1. **Terraform 実行ロールの権限を反映する**: この環境は SSM・EventBridge(ルールと Scheduler)・SNS・
   CloudWatch(Logs・ダッシュボード・メトリクス)を作るので、`terraform/iam/terraform-role.yaml` の
   `github-actions-terraform` ロールに `ssm:*` / `events:*` / `scheduler:*` / `sns:*` / `logs:*` /
   `cloudwatch:*` を追加してある。`main` にマージすると `cfn-role-deploy.yml`(と CloudFormation の
   Git sync)でロールに反映される。マージ前にこのブランチで試す場合は、ローカルから一度
   `aws cloudformation deploy`(`terraform/README.md` の Step 2 と同じコマンド)で反映しておく
2. GitHub Variables に `PATCH_NOTIFICATION_EMAIL`(通知先メールアドレス、任意)を設定する
3. `Terraform Patch Management (patch-mgmt)` ワークフローを `plan` → `apply` で実行
4. SNS から届く確認メールのリンクを踏む
5. 家のサーバに ISO を置き、ゴールデンイメージをビルドしてから VM を作る
   ([`ansible/patch-mgmt/README.md`](../../../ansible/patch-mgmt/README.md)、
   [`ansible/patch-mgmt/packer/README.md`](../../../ansible/patch-mgmt/packer/README.md))
6. Fleet Manager に5台(`mi-...`)が表示され、タグが付いていることを確認する
7. repository の EUS リポジトリと reposync の進み具合を確認する(「前提 4.」「リポジトリ同期の流れ」)
8. reposync が終わったら infra に同期させる(「リポジトリ同期の流れ」のコマンド)
9. State Manager の関連付け `iac-poc-patch-daily-scan` を「今すぐ適用」し、Patch Manager の画面と、
   次の毎時10分以降に `iac-poc-patch-status` ダッシュボードにコンプライアンスが出ることを確認する
10. 業務VMがミラーだけを使い、CDN には出られないことを確認する

```bash
ssh patch-test
dnf repolist                         # infra-baseos / infra-appstream だけが有効
dnf updateinfo list --security       # Security アドバイザリが見えればupdateinfoも同期できている
curl -m 5 -sI https://cdn.redhat.com                          # 仮想FWで落ちる(タイムアウト)
curl -m 5 -s -o /dev/null -w '%{http_code}\n' https://ssm.ap-northeast-1.amazonaws.com   # 許可しているので応答がある
```

KVMホスト側では、許可リストと落とした通信を確認できる:

```bash
nft list set inet patch_mgmt_fw https_v4      # 業務VMが名前解決したSSMなどのIP
journalctl -k | grep 'patch-mgmt-fw drop:'    # 落とした通信(cdn.redhat.com 宛てなど)
```

## コストと後片付け

AWS 側は standard tier の SSM・メンテナンスウィンドウ・Automation・EventBridge・SNS・CloudWatch Logs
が中心で、ほぼ無料枠に収まる。ダッシュボード用のカスタムメトリクスは 3種類 × 環境4つ = 12個
(最初の10個は無料枠)なので少額。CloudWatch ダッシュボードは3つまで無料で、ここでは2つ使う。

家のサーバ側はメモリ 14GB と、ミラー用データディスク(repository と infra に同じ中身が入るので
同期したリポジトリのサイズ × 2)を使う。VM を消すときは `ansible/patch-mgmt/destroy.yml` を使うと、
SSM のマネージドノードと RHSM の登録も一緒に解除される。

## 追加で使えそうなサービス

| サービス | 使いどころ | 優先度 |
|---|---|---|
| CloudWatch アラーム | ダッシュボードのメトリクスを使い、「prod の未適用パッチが7日以上0にならない」などを通知する | 中 |
| Red Hat Insights(console.redhat.com) | RHSM に登録した VM の CVE・推奨対応を一覧できる(サブスクリプションに含まれる)。Patch Manager の CVE は「未適用のパッチがあるもの」だけだが、Insights は「その CVE が影響するか・修正があるか」の観点で見られる。ISO の自動登録で Insights にもつながっていれば repository / infra はそのまま使える(業務VMは仮想FWの許可リストに Insights の宛先を足す必要がある)。Amazon Inspector はオンプレの VM は対象外とみられる(要確認) | 中 |
| AWS Config(`ec2-managedinstance-patch-compliance-status-check`) | パッチ準拠状況の**履歴**を残す。監査で「いつ時点で準拠していたか」を示せる。ハイブリッドのノードも記録できるかは要確認 | 中 |
| Change Calendar(Systems Manager) | 年末年始などの変更凍結期間を定義し、その間はパッチ適用を止める | 中 |
| Inventory + Resource Data Sync → Athena | 全VMのパッケージ一覧を S3 に集約し、「この kernel が入っているVM」を SQL で引ける。ダッシュボードを Grafana(家の k3s)や QuickSight で作り込みたくなったときのデータ源にもなる | 低 |
| Resource Groups | タグ条件に名前を付けて(例: `prod-app-a`)、メンテナンスウィンドウや Run Command のターゲットに使い回す | 低 |
| 適用前の VM スナップショット | 失敗時の切り戻し手段。KVM ホストで `virsh snapshot-create-as` を取ってから当てる(家のサーバ本体も SSM 管理下なので、Run Command で実行できる) | 中 |
| Step Functions + EventBridge Scheduler | 「test 成功のイベントから**ちょうど1日後**に stg を流す」のようなイベント駆動の昇格 | 低(今回は曜日固定で代替) |

Systems Manager **Change Manager** は 2025/11/7 以降、新規の利用受付を終了しているため候補から外している。
変更承認は「ベースライン変更は GitHub の PR」「緊急実行は Runbook の `aws:approve`」で代替している。

## 決めたこと

- 承認の考え方: 承認日数(日付基準、test 0日 / stg 1日 / prod 2日)+ 前段の成功確認(ゲート)で進める
- ダッシュボード: まずは今の2つ(status / history)の簡易的なもので運用してみる
- VM の管理: Session Manager は使わず SSH(外出先からは Tailscale 経由)

## これから詰める点

- 使っているサブスクリプションに EUS が含まれるか → 含まれなければ非EUSで進めるか
- 再起動パターンの割り当て: 今は test/stg が自動、prod が手動
- アプリ単位のウィンドウのタグ設計: `App` タグで分けるか、`MaintenanceWindow=weekday-night` のようにウィンドウ名をタグに直接持たせるか
- 緊急パッチの承認者と、Runbook を実行できる人(IAM)の範囲
- 通知先: メールのままか、Slack(Amazon Q Developer in chat applications)に流すか
