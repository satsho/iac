# 日時指定公開テスト(CloudFront Functions + KVS)

指定した日時までS3上の画像(jpeg)を403にし、日時を過ぎたら見られるようにする仕組みのテスト環境。
最終的にQiitaの記事にする想定。

## 構成

```
ブラウザ → Route53(release-test.focus4.net)
         → CloudFront(ACM証明書、OAC経由でS3のみ許可)
             - / : 普通にindex.htmlを配信
             - /images/* : CloudFront Function(release-gate.js)が
               KVSの解禁日時と現在時刻を比較し、未解禁ならviewer-requestで
               403を返す。解禁後はそのままS3(OAC経由)へ素通りする
         → S3(完全非公開、OAC経由のみ読み取り許可)
```

- **OAC(Origin Access Control)**: S3を完全非公開にする。これが無いと、CloudFront
  Functionで日時制限をかけても、S3の直接URLから画像が見えてしまう
- **CloudFront Functions + KVS**: 解禁日時をコードではなくKVS(Key Value Store)に
  持たせることで、コードを書き換えずに日時だけ更新できる
- `/images/*`は`min_ttl=default_ttl=max_ttl=0`にしてあり、CloudFront自体には
  キャッシュさせない(解禁前後で判定結果が変わるため)

## 適用

```bash
# GitHub Actions(.github/workflows/terraform-timed-release.yml)をworkflow_dispatchで実行
# action: plan → 確認 → action: apply
```

ACM証明書のDNS検証に数分かかることがある。

## テスト用画像を置く(手動、一度だけ)

Terraformにバイナリをコミットしたくないため、jpeg画像は手動でアップロードする。

```bash
aws s3 cp secret.jpg s3://$(terraform output -raw bucket_name)/images/secret.jpg \
  --content-type image/jpeg
```

## 解禁日時を更新する(手動、AWS CLI)

`release_time`はTerraformの管理外(`lifecycle.ignore_changes`)にしてあるので、
AWS CLIで直接書き換える。KVSは書き込み時にETagが必要。

```bash
KVS_ARN=$(terraform output -raw key_value_store_arn)

# 現在のETagを取得
ETAG=$(aws cloudfront-keyvaluestore get-key \
  --kvs-arn "$KVS_ARN" --key release_time_secret_jpg \
  --query ETag --output text)

aws cloudfront-keyvaluestore put-key \
  --kvs-arn "$KVS_ARN" \
  --key release_time_secret_jpg \
  --value "2026-12-25T00:00:00Z" \
  --if-match "$ETAG"
```

## 動作確認

```bash
curl -i https://release-test.focus4.net/images/secret.jpg
```

- 解禁前: `403 Forbidden`
- 解禁後: `200 OK`(jpeg)

`/images/*`はキャッシュさせていないので、`put-key`の反映はほぼ即時(CloudFront
Functionsの伝播自体に数秒〜1分程度かかることがある)。

## 後片付け

```bash
# GitHub Actionsでaction: destroy
```

ACM証明書の削除やRoute53レコードの削除も含めてTerraformが面倒を見る。
