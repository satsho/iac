# パッチ管理検証用VM(家のサーバのKVM)

[`terraform/environments/patch-mgmt`](../../terraform/environments/patch-mgmt/README.md) で検証する
5台の RHEL 10.2(repository / infra / test / stg / prod)を、家のサーバの KVM 上に作る playbook。
設計(ネットワーク・プロキシ・パッチ適用の流れ)は Terraform 側の README を参照。

| ファイル | 内容 |
|---|---|
| `vars.yml` | VM・ネットワーク・タグ・リポジトリ同期の設定(ここを編集する) |
| `site.yml` | libvirt ネットワークを作り、まだ無い VM を作る |
| `destroy.yml` | VM を消し、SSM のマネージドノードと RHSM の登録を解除する |
| `templates/user-data/` | cloud-init で初回起動時に実行するスクリプト(役割ごと) |

## VM が出来上がるまでの流れ

`site.yml` は1台ずつ次の順に処理する(repository → infra → test → stg → prod)。

1. RHEL の KVM Guest Image をバッキングファイルにして、ルートディスク(差分の qcow2)を作る
2. repository / infra にはミラー用のデータディスクも作る(VM を消しても残す)
3. その VM 専用の SSM アクティベーション(登録1回限り)を、`vars.yml` のタグ付きで作る
4. user-data(役割ごとのスクリプト)・meta-data・network-config を入れた cloud-init の seed ISO を作る
5. `virt-install` で起動する
6. SSM に登録されて Online になるまで待つ(最大15分)

例: `patch-test` の場合、アクティベーションに `Name=patch-test, Env=test, PatchGroup=rhel10-test,
RebootPolicy=auto ...` が付き、起動した VM が `mi-0abc...` として登録されると、同じタグが付いた状態で
Fleet Manager に現れる。これで Terraform 側のメンテナンスウィンドウ(`Env=test かつ RebootPolicy=auto`)の
対象になる。

## 前提

家のサーバ(KVM ホスト)に必要なもの:

- `libvirt` / `qemu-kvm` / `virt-install` / `qemu-img` / `xorriso` / `aws`(AWS CLI v2)/ `ansible-core`
- CPU が x86-64-v3 に対応していること(RHEL 10 の要件。AVX2 など。playbook で確認する)
- 空きメモリ 10GB 程度(2GB × 5台)と、ミラー用のディスク(repository と infra それぞれにリポジトリ1式)
- `vars.yml` の `rhel_base_image` に、Red Hat Customer Portal からダウンロードした
  **RHEL 10.2 の KVM Guest Image**(qcow2)を置く
- `osinfo-query os | grep rhel10` で `os_variant` の値が使えることを確認する(古い osinfo-db だと
  `rhel10.0` が無いので、その場合はホストの osinfo-db を更新するか一番近い値にする)
- k3s と同居する場合も、このネットワーク(192.168.150.0/24, 192.168.151.0/24)は k3s の
  Pod / Service の CIDR(10.42.0.0/16, 10.43.0.0/16)と重ならないので、そのまま使える

先に Terraform 側を apply しておく(VM が引き受ける IAM ロール `iac-poc-patch-hybrid-node-role` が要る)。

## 実行

```bash
# SSMのアクティベーションを作れるAWSの認証情報(ssm:CreateActivation と、
# iac-poc-patch-hybrid-node-role への iam:PassRole が要る)
export AWS_PROFILE=<管理者のプロファイル>
# RHSMに登録するためのRed Hatのorg IDとactivation key(GitHub Secretsと同じもの)
export RHEL_ORG_ID=<org id>
export RHEL_ACTIVATION_KEY=<activation key>

cd ansible/patch-mgmt
ansible-playbook -K site.yml
```

AWS CLI は playbook を実行したユーザーの認証情報で動かし、`become` しない。root の
`/root/.aws/credentials` は家のサーバ自身の Hybrid Activation の一時クレデンシャル
(Route53 などの権限を持つロール)なので、VM の登録には使わない。最初のタスクで
どの IAM で作成するかを表示するので、意図したものか確認する。

VM に SSH したい場合は `vars.yml` の `ssh_authorized_keys` に公開鍵を入れてから作る
(ユーザーは `cloud-user`)。鍵を入れないと、Session Manager(advanced-instances tier が必要)を
使わない限り VM の中に入る手段が `virsh console` だけになり、パスワードも無いのでログインできない。

`site.yml` は何度流してもよく、既にある VM はそのままにする。VM の設定(メモリ・タグ・user-data など)を
変えたいときは、その VM を消してから流し直す:

```bash
ansible-playbook -K destroy.yml -e '{"only": ["patch-test"]}'
ansible-playbook -K site.yml
```

## 消す

```bash
ansible-playbook -K destroy.yml                      # VMだけ消す(ミラー用データディスクは残す)
ansible-playbook -K destroy.yml -e wipe_data=true -e remove_networks=true   # 全部消す
```

`destroy.yml` は、VM が動いているうちに Run Command で `subscription-manager unregister` を実行してから
VM を消し、最後に SSM のマネージドノード登録を解除する。消さずに VM を捨てると、
RHSM のシステム(Developer Subscription なら16台の枠)と SSM の `mi-...` が残り続けるので注意。

## うまくいかないとき

| 症状 | 見るところ |
|---|---|
| 「SSM に登録されるまで待つ」で止まる | `virsh console <VM名>` で起動しているか、VM 内の `/var/log/cloud-init-output.log` |
| 業務VMだけ登録されない | infra のプロキシが動いているか(`systemctl status squid`)、`/var/log/squid/access.log` に `TCP_DENIED` が出ていないか |
| repository で `subscription-manager repos` が失敗する | サブスクリプションに EUS が無い可能性(Terraform 側 README の「前提 4.」) |
| SSM の操作が `InvalidSignatureException` などで失敗する | VM の時刻ずれ(`chronyc tracking`)。業務VMは infra を NTP サーバにしている |

user-data にはアクティベーションコードと Red Hat の activation key が入るため、seed ISO
(`/var/lib/libvirt/images/patch-mgmt/<VM名>/seed.iso`)は root だけが読めるディレクトリに置き、
元のファイルは ISO を作った直後に消している。アクティベーションコードは登録1回限り・24時間で失効する。
