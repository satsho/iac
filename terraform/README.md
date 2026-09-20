# satsho/iac — Terraform VPC PoC

GitHub Actions (OIDC) から Terraform で VPC を作成するトライアル構成。

## ディレクトリ構成

```
.
├── bootstrap/               # tfstate用のS3を作る「最初の一回だけ」用のCFNテンプレート
├── environments/
│   └── dev/                # 実際にVPCを作る環境。ここをterraform plan/applyする
├── modules/
│   └── vpc/                # VPC本体のモジュール(再利用可能な部品)
├── iam/                     # IAMロール定義(CFNテンプレート)
└── .github/workflows/       # CI/CDワークフロー
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

**実行場所: ローカル端末(GitHub Actionsではない)**。
まだtfstate用のS3バケットが存在しないため、この工程だけはローカルの
AWS認証情報(S3バケット・バケットポリシーを作成できる権限を持つもの)を使って手元から実行する。

```bash
aws sts get-caller-identity  # 認証情報が正しいか確認

aws cloudformation deploy \
  --template-file bootstrap/bootstrap.yaml \
  --stack-name iac-tfstate-bootstrap \
  --parameter-overrides BucketName=satsho-iac-tfstate

# 出力されたバケット名を確認(次のStep 3・4で使う)
aws cloudformation describe-stacks \
  --stack-name iac-tfstate-bootstrap \
  --query "Stacks[0].Outputs"
```

バケット名を変えたい場合は `BucketName` パラメータを変更する。
その場合は `environments/dev/backend.tf` と
`iam/terraform-role.yaml` の `TFStateBucketName` も合わせて変更すること。

### Step 2: GitHub Actions用Terraformロールを作成する(手動、初回のみ)

**実行場所: ローカル端末**。IAMロールを作成できる権限を持つ認証情報で実行する。

```bash
aws cloudformation deploy \
  --template-file iam/terraform-role.yaml \
  --stack-name iac-terraform-role \
  --capabilities CAPABILITY_NAMED_IAM

# 出力されたロールARNを確認(Step 3のGitHub Variablesで使う)
aws cloudformation describe-stacks \
  --stack-name iac-terraform-role \
  --query "Stacks[0].Outputs"
```

デフォルトパラメータは `satsho/iac` リポジトリの `main` ブランチ、
`OIDCProviderArn` は既存の `token.actions.githubusercontent.com` プロバイダーを指す。
別リポジトリ・別ブランチで使う場合は `--parameter-overrides` で上書きする。

```bash
aws cloudformation deploy \
  --template-file iam/terraform-role.yaml \
  --stack-name iac-terraform-role \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      GitHubOwner=satsho \
      GitHubOwnerId=15127328 \
      GitHubRepo=iac \
      GitHubRepoId=1371692263 \
      GitHubBranch=main \
      TFStateBucketName=satsho-iac-tfstate
```

### Step 3: GitHub Variablesを設定する

リポジトリの Settings > Secrets and variables > Actions > Variables タブで以下を設定:

| 変数名 | 値の例 |
|---|---|
| `AWS_ROLE_ARN` | Step 2の出力値(`arn:aws:iam::563613886922:role/github-actions-terraform`) |
| `AWS_REGION` | `ap-northeast-1` |
| `TF_STATE_BUCKET` | Step 1の出力値 |

Secretsは今回不要(OIDC認証のためAWSキー類が発生しない)。

### Step 4: environments/dev/backend.tf にbootstrapの出力値を反映

`environments/dev/backend.tf` の `bucket` を実際の値に書き換える。

### Step 5: GitHub Actionsでplan/applyを実行

`.github/workflows/terraform-vpc.yml` を使って、`workflow_dispatch` で手動実行。

## 変数・Secretsの設計方針

| 種類 | 置き場所 | 例 |
|---|---|---|
| 環境非依存の非機密設定 | `terraform.tfvars`(リポジトリにコミット) | `project_name` |
| 環境ごとの設定 | `environments/<env>/terraform.tfvars` | VPC CIDR |
| CI実行に必要な非機密値 | GitHub Variables | ロールARN、リージョン、tfstateバケット名 |
| 本物の機密情報 | GitHub Secrets(今回は未使用) | 外部SaaSのAPIキーなど |
| AWS内で完結する機密 | AWS Secrets Manager / SSM SecureString | 将来のDBパスワード等 |

## IAM設計方針

- 認証テスト用の `github-actions` ロールとは別に、Terraform実行専用の `github-actions-terraform` ロールを新設(`iam/terraform-role.yaml`)
- ロール自体をCloudFormationで管理することで、権限変更の履歴がスタックの更新履歴として残る(手動コンソール操作による設定ドリフトを防ぐ)
- 信頼ポリシーは `main` ブランチからの実行のみ許可(`sub` に不変のowner_id/repo_idを埋め込んだ形式を使用。リポジトリ名変更に強い)
- 権限ポリシーは「VPC関連リソースの操作」+「tfstate用S3へのアクセス」のみに限定し、ワイルドカード権限(`*`)は使用しない
- 将来的にリソースが増えたら、Terraformが扱うAWSサービスが増えるごとに `iam/terraform-role.yaml` の `Policies` にActionを追加していく運用とする(先回りしてフル権限を与えない)
