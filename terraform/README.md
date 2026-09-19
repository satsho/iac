# satsho/iac — Terraform VPC PoC

GitHub Actions (OIDC) から Terraform で VPC を作成するトライアル構成。

## ディレクトリ構成

```
.
├── bootstrap/              # tfstate用のS3/DynamoDBを作る「最初の一回だけ」用の構成
├── environments/
│   └── dev/                # 実際にVPCを作る環境。ここをterraform plan/applyする
├── modules/
│   └── vpc/                # VPC本体のモジュール(再利用可能な部品)
├── iam/                     # IAMロール定義(信頼ポリシー・権限ポリシー)
└── .github/workflows/       # CI/CDワークフロー
```

なぜ `bootstrap` と `environments/dev` を分けるか:
tfstateを置くS3バケット自体はTerraformで管理したいですが、
「stateを置く場所」を作る処理自体はまだstateを持てません(鶏と卵)。
なのでbootstrapだけはローカルstateで一度だけ手元から実行し、
以降の`environments/dev`はそのS3バケットをbackendとして使います。

## セットアップ手順

### Step 1: IAMロールを作成する(手動、初回のみ)

```bash
# 信頼ポリシー・権限ポリシーを使ってロールを作成
aws iam create-role \
  --role-name github-actions-terraform \
  --assume-role-policy-document file://iam/terraform-trust-policy.json

aws iam put-role-policy \
  --role-name github-actions-terraform \
  --policy-name terraform-vpc-permissions \
  --policy-document file://iam/terraform-permissions-policy.json
```

### Step 2: tfstate用のS3/DynamoDBをbootstrapで作る(手動、初回のみ)

```bash
cd bootstrap
terraform init
terraform apply
# 出力される bucket名・table名を控える
```

### Step 3: GitHub Variablesを設定する

リポジトリの Settings > Secrets and variables > Actions > Variables タブで以下を設定:

| 変数名 | 値の例 |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::563613886922:role/github-actions-terraform` |
| `AWS_REGION` | `ap-northeast-1` |
| `TF_STATE_BUCKET` | bootstrapの出力値 |
| `TF_STATE_LOCK_TABLE` | bootstrapの出力値 |

Secretsは今回不要(OIDC認証のためAWSキー類が発生しない)。

### Step 4: environments/dev/backend.tf にbootstrapの出力値を反映

`environments/dev/backend.tf` の `bucket` / `dynamodb_table` を実際の値に書き換える。

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

- 認証テスト用の `github-actions` ロールとは別に、Terraform実行専用の `github-actions-terraform` ロールを新設
- 信頼ポリシーは `main` ブランチからの実行のみ許可(`sub` に `ref:refs/heads/main` を指定)
- 権限ポリシーは「VPC関連リソースの操作」+「tfstate用S3/DynamoDBへのアクセス」のみに限定し、ワイルドカード権限(`*`)は使用しない
- 将来的にリソースが増えたら、Terraformが扱うAWSサービスが増えるごとに `iam/terraform-permissions-policy.json` にActionを追加していく運用とする(先回りしてフル権限を与えない)
