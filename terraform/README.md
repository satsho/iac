# satsho/iac — Terraform VPC PoC

GitHub Actions (OIDC) から Terraform で VPC を作成するトライアル構成。

## ディレクトリ構成

```
iac/                          # リポジトリルート
├── terraform/
│   ├── bootstrap/            # tfstate用のS3を作る「最初の一回だけ」用のCFNテンプレート
│   ├── environments/
│   │   └── dev/              # 実際にVPCとインスタンスを作る環境。ここをterraform plan/applyする
│   │       # state は1つ(環境ごとにまとめて作成・削除)だが、可読性のため
│   │       # リソースドメインごとに.tfファイルを分割している:
│   │       #   network.tf(networkモジュール呼び出し) / security_group.tf / iam.tf / ec2.tf
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
| `RHEL_AMI_ID` | Step 6参照。RHEL 9のAMI ID(非機密なのでVariables側) |

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

`.github/workflows/terraform-vpc.yml` を使って、`workflow_dispatch` で手動実行。
`action`入力で `plan` / `apply` / `destroy` を選べる。
このワークフローは `terraform/environments/dev` を作業ディレクトリとして動く。

`destroy`を選ぶと `terraform plan -destroy` → `terraform apply` の順で実行され、
作成したVPC・インスタンス一式が削除される。applyと同じくplan結果を経由するので、
実行前にログで削除対象を確認できる。

### Step 6: RHEL + RKE2ノードの起動

`environments/dev/ec2.tf` はRHEL 9のAMIを`var.rhel_ami_id`で受け取って起動する設計。
当初はRed Hat公式所有者ID(`309956199834`)からの`data "aws_ami"`動的検索を
試みたが、このAWSアカウント/リージョンでは該当AMIが見えず断念し、
**AMI IDを直接変数で渡す方式**にしている。

AMI IDの確認方法:
1. EC2コンソールで「インスタンスを起動」画面を開く(起動はしない)
2. 「アプリケーションおよびOSイメージ」→ Quick Startタブ → Red Hatを選択、
   RHEL 9系のバージョンを選ぶ
3. 表示されたAMI ID(`ami-...`)をコピーし、Step 3の`RHEL_AMI_ID`変数に設定

サブスク登録(`subscription-manager register`)とRKE2(シングルノード、server単体)の
セットアップは、AMIに焼き込むのではなく**起動時のuser_data(cloud-init)** で行う。
焼き込み方式だとAMIを複数インスタンスで使い回したときにサブスク登録が競合しやすいため。

事前にStep 3で `RHEL_ORG_ID` / `RHEL_ACTIVATION_KEY` のSecretsを設定しておくこと。
これらはCIワークフロー側で `TF_VAR_rhel_org_id` / `TF_VAR_rhel_activation_key` として
Terraformに渡され、`templates/rke2-user-data.sh.tpl` に埋め込まれる。

Step 5のTerraform applyを実行すると、RHELインスタンスが起動し初回起動時に
自動でサブスク登録・RKE2インストール・起動まで完了する。

**接続確認・動作確認**(SSHキーを使わず、SSM Session Manager経由):

```bash
aws ssm start-session --target <instance-id>

# インスタンス内で実行
sudo systemctl status rke2-server
sudo /var/lib/rancher/rke2/bin/kubectl \
  --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes
```

**注意点**:
- `user_data`の内容(activation key含む)はEC2のインスタンス属性とTerraform state
  (S3、SSE暗号化済み)に平文で残る。完全な秘匿ではないので、activation keyが漏れた
  場合はRed Hat Hybrid Cloud Console側で失効・再発行すること。
- RKE2は`t2.micro`では非力なため、インスタンスタイプは`t3.medium`
  (`var.rke2_instance_type`)に変更済み。コストが上がる点に注意。
- `packer/al2023-nginx.pkr.hcl` / `packer-build.yml` はAmazon Linux 2023 + nginxの
  検証用AMIを作る別系統のパイプラインで、このRHEL+RKE2インスタンスとは独立している。

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
