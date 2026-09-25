# satsho/iac — Terraform Infra PoC

GitHub Actions (OIDC) から Terraform でVPC・EC2・ALB等のインフラ一式を
作成するトライアル構成。

## ディレクトリ構成

```
iac/                          # リポジトリルート
├── terraform/
│   ├── bootstrap/            # tfstate用のS3を作る「最初の一回だけ」用のCFNテンプレート
│   ├── environments/
│   │   ├── dev/               # 実際にVPCとインスタンスを作る、使い捨て前提の環境
│   │   │   # state は1つ(環境ごとにまとめて作成・削除)だが、可読性のため
│   │   │   # リソースドメインごとに.tfファイルを分割している:
│   │   │   #   network.tf(networkモジュール呼び出し) / security_group.tf / iam.tf / ec2.tf / lb.tf
│   │   └── dns/                # ドメイン(Route 53 hosted zone)専用の別state。
│   │       # devとライフサイクルが違う(destroyされたくない)ので分離している
│   ├── modules/
│   │   └── network/          # VPC・サブネット・ルーティング一式のモジュール(再利用可能な部品)
│   ├── iam/                  # IAMロール定義(CFNテンプレート)
│   └── README.md             # このファイル
├── packer/                   # AMIビルド用Packerテンプレート
└── .github/workflows/        # CI/CDワークフロー(terraform/とは別階層)
```

なぜ `bootstrap` を分けるか:
tfstateを置くS3バケット自体はTerraformで管理したいですが、
「stateを置く場所」を作る処理自体はまだstateを持てません(鶏と卵)。
なのでbootstrapだけはTerraformを使わず、**CloudFormationで一度だけ手動作成**します。

state のロックは DynamoDB を使わず、Terraform 1.10 以降の
**S3ネイティブロック**(`use_lockfile = true`)を使います。
S3バケットへの書き込み権限だけでロックが取れるので、
DynamoDBテーブルの作成・IAM権限が不要になります。

## セットアップ手順

### Step 1: tfstate用のS3をCloudFormationで作る(手動、初回のみ)

**実行場所: ローカル端末(GitHub Actionsではない)、リポジトリルート(`iac/`)から実行**。
まだtfstate用のS3バケットが存在しないため、この工程だけはローカルの
AWS認証情報(S3バケット・バケットポリシーを作成できる権限を持つもの)を使って手元から実行する。

```bash
aws sts get-caller-identity  # 認証情報が正しいか確認

aws cloudformation deploy \
  --template-file terraform/bootstrap/bootstrap.yaml \
  --stack-name iac-tfstate-bootstrap \
  --parameter-overrides BucketName=satsho-iac-tfstate

# 出力されたバケット名を確認(次のStep 3・4で使う)
aws cloudformation describe-stacks \
  --stack-name iac-tfstate-bootstrap \
  --query "Stacks[0].Outputs"
```

バケット名を変えたい場合は `BucketName` パラメータを変更する。
その場合は `terraform/environments/dev/backend.tf` と
`terraform/iam/terraform-role.yaml` の `TFStateBucketName` も合わせて変更すること。

### Step 2: GitHub Actions用Terraformロールを作成する(手動、初回のみ)

**実行場所: ローカル端末、リポジトリルート(`iac/`)から実行**。IAMロールを作成できる権限を持つ認証情報で実行する。

```bash
aws cloudformation deploy \
  --template-file terraform/iam/terraform-role.yaml \
  --stack-name iac-terraform-role \
  --capabilities CAPABILITY_NAMED_IAM

# 出力されたロールARNを確認(Step 3のGitHub Variablesで使う)
aws cloudformation describe-stacks \
  --stack-name iac-terraform-role \
  --query "Stacks[0].Outputs"
```

デフォルトパラメータは `satsho/iac` リポジトリの `AWS` Environment、
`OIDCProviderArn` は既存の `token.actions.githubusercontent.com` プロバイダーを指す。
別リポジトリ・別Environment名で使う場合は `--parameter-overrides` で上書きする。

```bash
aws cloudformation deploy \
  --template-file terraform/iam/terraform-role.yaml \
  --stack-name iac-terraform-role \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOwner=satsho \
      GitHubOwnerId=15127328 \
      GitHubRepo=iac \
      GitHubRepoId=1371692263 \
      GitHubEnvironment=AWS \
      TFStateBucketName=satsho-iac-tfstate
```

**注意:** ワークフロー側のジョブに `environment:` を指定すると、OIDCトークンの`sub`は
ブランチ基準(`ref:refs/heads/main`)ではなく**Environment基準**(`environment:<name>`)に変わる。
`environment:`を使わない設計に変える場合は、このテンプレートの`sub`条件も
`ref:refs/heads/<branch>`形式に戻す必要がある。

### Step 3: GitHub Variablesを設定する

リポジトリの Settings > Secrets and variables > Actions > Variables タブで以下を設定:

| 変数名 | 値の例 |
|---|---|
| `AWS_ROLE_ARN` | Step 2の出力値(`arn:aws:iam::563613886922:role/github-actions-terraform`) |
| `AWS_REGION` | `ap-northeast-1` |
| `TF_STATE_BUCKET` | Step 1の出力値 |
| `RHEL_AMI_ID` | Step 6参照。RHEL 10.2のAMI ID(非機密なのでVariables側) |

AWS認証自体はOIDCのためSecrets不要だが、RHELサブスク登録のために下記Secretsが必要
(詳細はStep 6を参照)。

リポジトリの Settings > Secrets and variables > Actions で、`AWS` Environmentの
Secrets(Variablesと同じ画面のSecretsタブ)に以下を設定:

| Secret名 | 値 |
|---|---|
| `RHEL_ORG_ID` | Red Hat Hybrid Cloud ConsoleのOrg ID |
| `RHEL_ACTIVATION_KEY` | 同コンソールで発行したactivation key名 |

### Step 4: environments/dev/backend.tf にbootstrapの出力値を反映

`terraform/environments/dev/backend.tf` の `bucket` を実際の値に書き換える。

### Step 5: GitHub Actionsでplan/apply/destroyを実行

`.github/workflows/terraform-infra.yml` を使って、`workflow_dispatch` で手動実行。
`action`入力で `plan` / `apply` / `destroy` を選べる。
このワークフローは `terraform/environments/dev` を作業ディレクトリとして動く。

`destroy`を選ぶと `terraform plan -destroy` → `terraform apply` の順で実行され、
作成したVPC・インスタンス一式が削除される。applyと同じくplan結果を経由するので、
実行前にログで削除対象を確認できる。

### Step 6: RHEL + k3sノードの起動

`environments/dev/ec2.tf` はRHEL 10.2のAMIを`var.rhel_ami_id`で受け取って起動する設計。
当初はRed Hat公式所有者ID(`309956199834`)からの`data "aws_ami"`動的検索を
試みたが、このAWSアカウント/リージョンでは該当AMIが見えず断念し、
**AMI IDを直接変数で渡す方式**にしている。

AMI IDの確認方法:
1. EC2コンソールで「インスタンスを起動」画面を開く(起動はしない)
2. 「アプリケーションおよびOSイメージ」→ Quick Startタブ → Red Hatを選択、
   RHEL 10系のバージョンを選ぶ
3. 表示されたAMI ID(`ami-...`)をコピーし、Step 3の`RHEL_AMI_ID`変数に設定

サブスク登録(`subscription-manager register`)とk3s(シングルノード、Traefik/ServiceLBは
無効化してALBを前段に置く構成)のセットアップは、AMIに焼き込むのではなく
**起動時のuser_data(cloud-init)** で行う。焼き込み方式だとAMIを複数インスタンスで
使い回したときにサブスク登録が競合しやすいため。

当初はRKE2を使っていたが、「ALB経由でシンプルなWebアプリを公開する」という
用途に対してはRKE2はオーバースペックだったため、より軽量な**k3s**に切り替えた
(Rancher/ArgoCD前提の学習は改めて別途行う想定)。`aws_instance`には
`user_data_replace_on_change = true`を設定しているので、user_dataの内容
(スクリプトそのものやテンプレート変数)が変わるとインスタンスごと作り直され、
確実に新しいセットアップが反映される(user_dataは初回起動時にしか実行されないため)。

事前にStep 3で `RHEL_ORG_ID` / `RHEL_ACTIVATION_KEY` のSecretsを設定しておくこと。
これらはCIワークフロー側で `TF_VAR_rhel_org_id` / `TF_VAR_rhel_activation_key` として
Terraformに渡され、`templates/k3s-user-data.sh.tpl` に埋め込まれる。

Step 5のTerraform applyを実行すると、RHELインスタンスが起動し初回起動時に
自動でSSMエージェントのインストール・サブスク登録・k3sインストール・起動まで
完了する。RHELの公式AMIにはamazon-ssm-agentが同梱されていない(Amazon Linuxと
異なる点)ため、user_dataの最初のステップとして明示的にインストールしている。
これによりSSHキーやインバウンドルール無しでもSSM Session Managerが使える。

デモ用のnginx(Deployment + NodePort Service、ポートは`var.web_node_port`
デフォルト`30080`)は、k3sのマニフェスト自動デプロイディレクトリ
(`/var/lib/rancher/k3s/server/manifests/`)にuser_dataから直接配置しているので、
`kubectl apply`を手動で打たなくても起動時に自動で立ち上がる。

**ハマった点**: 初回構築時、Podは起動するのにNodePort/Service経由の通信が
一切通らない(`curl localhost:30080`が`Connection refused`)現象が発生した。
原因は`kernel-modules-extra`パッケージが`dnf install`時にリポジトリ内の
最新バージョンで入ってしまい、実際に起動中のカーネルバージョンと食い違って
`br_netfilter`等のモジュールが見つからなかったこと(k3s/flannel/kube-proxyは
iptables-nftでルールを組むのにこれらのカーネルモジュールを必要とする)。
`kernel-modules-extra-$(uname -r)`と明示的にバージョンを指定してインストール
することで解消した。user_data側でも同様に明示バージョン指定にしてある。

**接続確認・動作確認**(SSHキーを使わず、SSM Session Manager経由):

```bash
aws ssm start-session --target <instance-id>

# インスタンス内で実行
sudo systemctl status k3s
sudo kubectl get nodes
sudo kubectl get pods,svc
```

**注意点**:
- `user_data`の内容(activation key含む)はEC2のインスタンス属性とTerraform state
  (S3、SSE暗号化済み)に平文で残る。完全な秘匿ではないので、activation keyが漏れた
  場合はRed Hat Hybrid Cloud Console側で失効・再発行すること。
- インスタンスタイプは`t3.medium`(`var.rke2_instance_type`、変数名は歴史的経緯でrke2の
  ままだがk3s/RKE2共通で使っている)。k3s自体はもっと小さいインスタンスでも動くが、
  当面はそのままにしている。
- `packer/al2023-nginx.pkr.hcl` / `packer-build.yml` はAmazon Linux 2023 + nginxの
  検証用AMIを作る別系統のパイプラインで、このRHEL+k3sインスタンスとは独立している。

### Step 7: ALB経由でのWebアプリ公開

`environments/dev/lb.tf`でALB(Application Load Balancer)を作成し、Step 6の
デモnginx(NodePort `30080`)をターゲットグループにアタッチしている。

セキュリティグループは「ALB(80番、インターネットに公開)→ インスタンス
(`web_node_port`番、ALBのSGからのみ許可)」という一方向の経路のみを許可する形。
インスタンスSG自体は相変わらずSSH/インバウンド直接公開はしていない。

HTTPS化(ACM証明書・443番リスナー・80→443リダイレクト)はStep 9を参照。

**動作確認**:

```bash
# ALBのDNS名を確認
terraform output alb_dns_name

# ブラウザ or curl でアクセス(ALB→NodePort→nginxまで疎通していればnginxの
# ウェルカムページが表示される)
curl http://<alb_dns_name>/
```

### Step 8: ドメインをRoute 53に委任する(別state)

お名前.comで`focus4.net`を取得し、Route 53にDNS委任した。Hosted Zoneは
AWSコンソールで先に手動作成してしまっていたため、`environments/dns/dns.tf`
では**新規作成ではなくimportブロックで取り込む**形にしている。

```hcl
import {
  to = aws_route53_zone.main
  id = "Z00444252EVDC2QR0ELW1"
}
```

ドメインは`environments/dev`(VPC・EC2など使い捨て前提のリソース群)とは
**ライフサイクルが根本的に違う**(destroyされたくない、devとは無関係に
存続してほしい)ため、`environments/dns`という別ディレクトリ・別state
(`dns/terraform.tfstate`)に分離している。実行も専用ワークフロー
`.github/workflows/terraform-dns.yml`(`terraform-infra.yml`と同じ構造、
working-directoryだけ`environments/dns`)を使う。

手順:
1. お名前.comでドメインを取得
2. Route 53コンソールでHosted Zoneを作成(または既存のものを使う)し、
   払い出された4つのネームサーバーをお名前.com側のネームサーバー設定に登録
3. `nslookup -type=NS <ドメイン名>`で`awsdns-*.com/net/org/co.uk`の4つが
   返ってくれば委任完了(反映まで多少時間がかかることがある)
4. `terraform-dns.yml`を`plan`→`apply`で実行(`import`ブロックにより
   新規作成ではなく既存ゾーンを取り込む動きになる。差分が無くなったことを
   確認できたら`import`ブロックは削除してよい)

**新規にhosted zoneを作り直すと4つのネームサーバーの値が変わり、お名前.com側の
設定とズレて委任が壊れる**ので、state分離に加えて`lifecycle { prevent_destroy
= true }`でも保護している。`terraform-dns.yml`で`destroy`を実行しても
このリソースだけはエラーで止まる(解除するには明示的にこのブロックを消して
から`destroy`する必要がある)。

tfstate用S3バケットへのIAM権限(`terraform-role.yaml`の`TerraformStateS3`)は
元々`dev/*`プレフィックス限定だったが、`dns/terraform.tfstate`という別キーを
使うためバケット全体への許可に広げてある。

### Step 9: ALBのHTTPS化(ACM証明書 + 443番リスナー)

`environments/dev/acm.tf`でDNS検証方式のACM証明書(`focus4.net`)を発行し、
`environments/dev/lb.tf`のALBに443番リスナーとしてアタッチした。80番リスナーは
forwardではなく443番への301リダイレクトに変更している。

証明書はapex(`focus4.net`)一つのみ。ゾーン自体はStep 8の通り`environments/dns`
という別stateで管理しているため、DNS検証用レコードとALB向けのエイリアス
Aレコードは`data "terraform_remote_state" "dns"`経由で`environments/dns`の
tfstateから`zone_id`を読み取って`environments/dev`側から作成している
(ゾーンの所有権はdns state、レコードの追加はdev stateという分担)。

```hcl
data "terraform_remote_state" "dns" {
  backend = "s3"
  config = {
    bucket = "satsho-iac-tfstate"
    key    = "dns/terraform.tfstate"
    region = var.aws_region
  }
}
```

証明書のライフサイクルは`environments/dev`側にあるため、`dev`スタックを
destroy→再applyすると証明書もDNS検証からやり直しになる(トライアル段階の
使い捨てstateなので許容している)。ゾーン自体は別stateなので、この
destroy/apply往復でドメイン委任(NSレコード)が壊れることはない。

**動作確認**:

```bash
terraform output web_url          # => "https://focus4.net"
curl -I https://focus4.net/       # 200が返ればOK
curl -I http://focus4.net/        # 301 → https://focus4.net/ へのLocationヘッダ
```

CloudFront CDNは未実装(将来的にALBの前段に追加予定)。

### Step 10: Ansible + ArgoCDによるGitOps化

これまで`user_data`に直書きしていたRHELセットアップ・k3sインストール・デモアプリの
デプロイを、Ansible playbookとArgoCDのGitOpsに置き換えた。

**構成:**

```
Terraform (ec2.tf)
  └─ user_data (templates/ansible-bootstrap.sh.tpl)
       ├─ amazon-ssm-agentインストール
       ├─ subscription-manager register / repos --enable
       │    (dnfでのパッケージインストール全般の前提になるため、
       │     ここだけはAnsibleに移譲せずuser_dataで行う)
       ├─ ansible-core・gitのインストール
       └─ ansible-pull 実行
              │
              ▼
ansible/playbook.yml (このリポジトリ、GitHubから直接pull)
  ├─ kernel-modules-extra・br_netfilterのセットアップ
  ├─ k3sインストール(--disable traefik --disable servicelb)
  └─ ArgoCDインストール + Applicationリソースの適用
              │
              ▼
ArgoCD (クラスタ内で稼働)
  └─ manifests/demo-nginx/ (このリポジトリ) を継続的に同期
       (プッシュするたびにArgoCDが自動でPull・適用・selfHeal)
```

`ansible-pull`を使っているのは、SSH鍵を配らずSSM限定でアクセスするという既存方針を
崩さないため。インスタンス自身が起動時にGitHub(公開リポジトリ)からplaybookを
pullしてローカル実行するので、CI側からSSHでpushする必要がない。

**GitOps対象のマニフェスト(`manifests/demo-nginx/`)を変更する場合**、Terraformの
再applyは不要で、単にこのリポジトリの`main`にpushするだけでArgoCDが自動的に
差分を検知して適用する(`syncPolicy.automated`で`prune`・`selfHeal`を有効化済み)。

**動作確認**:

```bash
# SSM Session Manager経由でインスタンスに接続
aws ssm start-session --target <instance_id>

# ArgoCDの同期状況を確認
sudo /usr/local/bin/kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml \
  -n argocd get applications

# ArgoCD管理下のPod/Serviceを確認
sudo /usr/local/bin/kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml \
  get pods,svc -n default
```

ArgoCDのWeb UIは現時点では外部公開していない(SSM経由のポートフォワードで見る想定)。
Rancherの導入は後回し(今回はArgoCD単体でのGitOps運用を優先)。

## CloudFormation Git Sync(`iac-terraform-role` スタックの自動反映)

Step 2のIAMロール(`iac-terraform-role`スタック)は、権限不足エラーが出るたびに
`terraform-role.yaml`を直して再デプロイする、を何度も繰り返す運用になっていた。
都度ローカル/コンソールで`aws cloudformation deploy`を打つのが面倒なため、
`main`へのpushで自動反映される仕組みを2つ用意した。

- `.github/workflows/cfn-role-deploy.yml`:
  `main`への push で `aws cloudformation deploy` を実行するGitHub Actions
- AWS CloudFormation純正の **Git sync** 機能(コンソールの「Git と同期」タブ):
  CodeConnections経由でCloudFormationサービス自身がGitHubを監視し、直接スタックを更新する

どちらか一方でも良いが、Git syncのセットアップでいくつも躓いたので、
再現できるように手順と原因を残しておく。

### つまずいたポイント

#### 1. 「デプロイファイル」とテンプレートファイルは別物

Git Syncの「デプロイファイルのパス」に、いきなり既存のCFNテンプレート
(`terraform-role.yaml`)のパスを指定すると失敗する。

```
Error: Unable to read CloudFormation Deployment Config File
```

Git Syncが読むのは、テンプレートとは別スキーマの「デプロイファイル」という
YAMLで、最小構成は以下(`template-file-path`/`parameters`/`tags`の3キー):

```yaml
# terraform/iam/deployment-terraform-role.yaml
template-file-path: terraform/iam/terraform-role.yaml
parameters: {}
tags: {}
```

このファイル自体をリポジトリに事前にコミットしておく必要がある。
**「スタックの作成」ウィザードから新規作成する場合はAWSが自動でこのファイルの
プルリクエストを作ってくれるが、既存スタックへの後付け接続(「Git と同期」
タブの「接続」ボタン)ではPRは飛んでこず、指定パスに実ファイルが無いと
`404 Resource not found`になる。**

#### 2. ブランチの取り違え

Git Sync(および`cfn-role-deploy.yml`)は`main`ブランチを監視する設定に
していたが、実際の作業はfeatureブランチ上で進めていて`main`へのマージを
忘れていた。デプロイファイルをコミットしても`main`に無ければ同じ404になる。
→ 作業ブランチをPRで`main`にマージして解消。

#### 3. CI用ロール自身の権限不足(鶏と卵)

`cfn-role-deploy.yml`実行時にこのエラーが出た。

```
AccessDenied: ... is not authorized to perform: cloudformation:DescribeStacks
```

`github-actions-terraform`ロールの権限を「IAM/CloudFormationを広く許可する」
ように直したが、**その変更を反映させる行為自体を、まだ広い権限を持って
いないロールでは実行できない**という堂々巡りになった。
→ ここだけはCLIまたはAWSコンソールから**手動で一度だけ**`aws cloudformation
deploy`(またはコンソールでの「スタックを更新」)を実行し、広い権限を先に
反映させることで解消。以降は自動デプロイが機能するようになる。

#### 4. 副作用: 手動更新するとGit Syncが一時停止する

上記3の手動更新を行った直後、Git Syncが自動的に「無効」になった。

```
デプロイファイルの外部でスタックに変更が加えられたため、Git sync は無効になっています。
```

これはGit Sync管理外での変更を検知した安全装置。「Git と同期」タブの
「有効にする」を押せば、現在のデプロイファイルの内容で再同期され、実害なく
復旧する(`STACK_ALREADY_IN_SYNC`になれば成功)。

### 最終的な手順(再現用)

1. デプロイファイル(`deployment-terraform-role.yaml`)をテンプレートと同じ
   ディレクトリに作成してコミット
2. 作業ブランチを`main`にマージ
3. CloudFormationコンソール → 対象スタック → 「Git と同期」タブ → 「接続」
   - リポジトリ・ブランチ(`main`)・デプロイファイルのパスを指定
   - 「スタックの権限を指定」で使うIAMロール
     (`cloudformation.amazonaws.com`を信頼するロール)を新規作成し、
     実際にリソースを作成・更新できる権限を付与する
4. 初回反映で権限不足エラーが出た場合、**その権限を追加する変更だけは
   手動で一度デプロイ**(CLIまたはコンソールの「スタックを更新」)
5. 手動更新後にGit Syncが「無効」になっていたら「有効にする」を押して復旧
6. 以降は対象ファイル(テンプレート・デプロイファイルとも)を`main`にpush
   するだけで自動反映される

## 変数・Secretsの設計方針

| 種類 | 置き場所 | 例 |
|---|---|---|
| 環境非依存の非機密設定 | `terraform.tfvars`(リポジトリにコミット) | `project_name` |
| 環境ごとの設定 | `terraform/environments/<env>/terraform.tfvars` | VPC CIDR |
| CI実行に必要な非機密値 | GitHub Variables | ロールARN、リージョン、tfstateバケット名 |
| 本物の機密情報 | GitHub Secrets | RHELのorg ID・activation key |
| AWS内で完結する機密 | AWS Secrets Manager / SSM SecureString | 将来のDBパスワード等 |

## IAM設計方針

- 認証テスト用の `github-actions` ロールとは別に、Terraform実行専用の `github-actions-terraform` ロールを新設(`terraform/iam/terraform-role.yaml`)
- ロール自体をCloudFormationで管理することで、権限変更の履歴がスタックの更新履歴として残る(手動コンソール操作による設定ドリフトを防ぐ)
- 信頼ポリシーは `AWS` という名前のGitHub Actions Environmentからの実行のみ許可(`sub` に不変のowner_id/repo_idを埋め込み、`environment:AWS`条件で絞る。リポジトリ名変更にも強い)
- 権限ポリシーは「EC2操作全般(`ec2:*`、リージョン制限あり)」+「tfstate用S3へのアクセス」。**トライアル段階のため広めに許可しており、今後絞り込む前提**(下記参照)
- 将来的な絞り込み方針: 運用が進んだらCloudTrailで実際に使われた`ec2:*`アクションを洗い出し、`ec2:*`を実際に必要なAction一覧に置き換える。VPC操作+Describe系はひとまず判明済み(過去のコミット履歴に残してある)
