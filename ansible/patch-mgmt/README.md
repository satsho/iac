# パッチ管理検証用VM(家のサーバのKVM)

[`terraform/environments/patch-mgmt`](../../terraform/environments/patch-mgmt/README.md) で検証する
5台の RHEL 10.2(repository / infra / test / stg / prod)を、家のサーバの KVM 上に作り、
SSH で設定する playbook。設計(ネットワーク・プロキシ・パッチ適用の流れ)は Terraform 側の README を参照。

| ファイル | 内容 |
|---|---|
| `vars.yml` | VM・ネットワーク・タグ・リポジトリ同期の設定(ここを編集する) |
| `site.yml` | VMを作り(まだ無いものだけ)、SSHで全VMの設定を揃える。何度流してもよい |
| `destroy.yml` | VMを消し、SSMのマネージドノードとRHSMの登録を解除する |
| `tasks/kvm-*.yml` | KVMホスト側(ネットワーク、ISOからのインストール) |
| `tasks/*.yml`(それ以外) | VMの中(SSH・SSM Agent・RHSM・役割ごとの設定) |
| `templates/` | VMに置く設定ファイル(reposync・rsync・squid・repoファイルなど) |

## 流れ

`site.yml` は3つのplayに分かれている。

1. **KVMホスト**(ローカル実行)
   - libvirtのネットワーク2つを作る(VMのIPはMACアドレスでDHCP固定)
   - まだ無いVMを、Image BuilderのISOから全台同時に無人インストールする
   - インストールが終わって停止したVMから、ミラー用データディスクを付けて起動する
     (ISOは最初のディスクを無条件にフォーマットするので、データディスクはインストール後に付ける)
2. **repository / infra**(SSH)
   - SSH鍵の登録、パスワードでのSSHログインの停止、ホスト名・タイムゾーン
   - SSM Agentのインストールと登録(VMごとに使い捨てのアクティベーションを作る)、タグの同期
   - ISOの自動登録が済んでいるか確認し、リリースを10.2に固定してEUSリポジトリだけを有効にする
   - ミラー用データディスクのマウント、役割ごとの設定(reposync / rsync / squid / NTP)
3. **test / stg / prod**(SSH)
   - 時刻とリポジトリをinfraに向ける
   - SSM Agentのインストールと登録(infraのプロキシ経由)、タグの同期
   - RHSMへの登録(infraのプロキシ経由。ISOの自動登録は外に出られず失敗しているため)

例: `patch-test` の場合、`vars.yml` の `Env=test, PatchGroup=rhel10-test, RebootPolicy=auto` が
マネージドノード(`mi-0abc...`)のタグになり、Terraform 側のメンテナンスウィンドウ
(`Env=test かつ RebootPolicy=auto`)とパッチグループ(`rhel10-test`)の対象になる。
タグは `vars.yml` を直して `site.yml` を流し直せば、マネージドノード側も書き換わる。

## 前提

家のサーバ(KVMホスト)に必要なもの:

- `libvirt` / `qemu-kvm` / `virt-install` / `qemu-img` / `aws`(AWS CLI v2)/ `ansible-core`
- `sshpass`(初回だけ、VMにパスワードでSSHするため)
- CPU が x86-64-v3 に対応していること(RHEL 10 の要件。AVX2 など。playbook で確認する)
- メモリ: 4GB × 2(repository / infra)+ 2GB × 3 = 14GB
- ディスク: ルート 20GB × 5 と、ミラー用データディスク 150GB × 2(使った分だけ増える qcow2)。
  repository と infra に同じリポジトリが1式ずつ入るので、実際の使用量は「同期したリポジトリのサイズ × 2」+ α
- `vars.yml` の `rhel_install_iso` に、Image Builder で作った RHEL 10.2 のISOを置く
  (Red Hat への自動登録あり、ユーザー `sho`(wheel))
- `osinfo-query os | grep rhel10` で `os_variant` の値が使えることを確認する(古い osinfo-db だと
  `rhel10.0` が無いので、その場合はホストの osinfo-db を更新するか一番近い値にする)
- playbook を実行するユーザーの SSH 鍵(`vars.yml` の `ssh_public_key_file`)

先に Terraform 側を apply しておく(VM が引き受ける IAM ロール `iac-poc-patch-hybrid-node-role` が要る)。

## 実行

```bash
# SSMのアクティベーションを作れるAWSの認証情報(ssm:CreateActivation、ssm:AddTagsToResource、
# iac-poc-patch-hybrid-node-role への iam:PassRole が要る)
export AWS_PROFILE=<管理者のプロファイル>
# 業務VMのRHSM登録に使う(repository / infra はISOの自動登録で済んでいれば不要)
export RHEL_ORG_ID=<org id>
export RHEL_ACTIVATION_KEY=<activation key>

cd ansible/patch-mgmt
ansible-playbook -k -K site.yml   # 初回: -k でVMのSSHパスワード、-K でsudoのパスワードを聞かれる
ansible-playbook -K site.yml      # 2回目以降: 初回に登録したSSH鍵で入る
```

- AWS CLI は playbook を実行したユーザーの認証情報で動かし、`become` しない。root の
  `/root/.aws/credentials` は家のサーバ自身の Hybrid Activation の一時クレデンシャル
  (Route53 などの権限を持つロール)なので、VM の登録には使わない。最初のタスクで
  どの IAM で作成するかを表示するので、意図したものか確認する。
- ISO のパスワードはリポジトリに書かない(`-k` / `-K` で毎回入力する)。
- 鍵を登録したあとは、VM へのパスワードでの SSH ログインを止めている(`ssh_password_authentication: false`)。
  パスワードは `virsh console` からのログインと sudo にだけ使う。

インストール中の画面を見たい場合は、VNC が KVM ホストの 127.0.0.1 で待ち受けているので、
`virsh vncdisplay <VM名>` でポートを確認して SSH トンネル越しに見る。

## SSHで入る

VM は家のサーバの中のネットワークにしか無いので、家のサーバを踏み台にする。
外出先からは Tailscale で家のサーバに入れれば、そのまま VM にも届く。`~/.ssh/config` の例:

```
Host home
  HostName <家のサーバのTailscaleのホスト名>
  User <家のサーバのユーザー>

Host patch-repository
  HostName 192.168.150.10
Host patch-infra
  HostName 192.168.150.11
Host patch-test
  HostName 192.168.151.21
Host patch-stg
  HostName 192.168.151.22
Host patch-prod
  HostName 192.168.151.23

Host patch-*
  User sho
  ProxyJump home
  UserKnownHostsFile ~/.ssh/known_hosts_patch_mgmt
```

```bash
ssh patch-test
```

## 作り直す・消す

`site.yml` は既にある VM を作り直さない。VM ごと作り直したいときは、その VM を消してから流し直す:

```bash
ansible-playbook -K destroy.yml -e '{"only": ["patch-test"]}'
ansible-playbook -k -K site.yml
```

全部消す:

```bash
ansible-playbook -K destroy.yml                      # VMだけ消す(ミラー用データディスクは残す)
ansible-playbook -K destroy.yml -e wipe_data=true -e remove_networks=true   # 全部消す
```

`destroy.yml` は、VM が動いているうちに Run Command で `subscription-manager unregister` を実行してから
VM を消し、最後に SSM のマネージドノード登録を解除する(known_hosts の古い鍵も消す)。
playbook を使わずに VM を消すと、RHSM のシステムと SSM の `mi-...` が残り続けるので注意。

## うまくいかないとき

| 症状 | 見るところ |
|---|---|
| 「インストールが終わって停止するのを待つ」で止まる | VNC でインストーラの画面を見る。ISO のキックスタートに `reboot` / `poweroff` が無いと、最後に Enter 待ちで止まる |
| SSH がつながらない | `virsh domifaddr <VM名>` / `virsh net-dhcp-leases patch-mgmt` でIPが払い出されているか |
| repository で EUS のリポジトリを有効にできない | サブスクリプションに EUS が無い可能性(Terraform 側 README の「前提 4.」) |
| 業務VMの SSM 登録・RHSM 登録が失敗する | infra で `systemctl status squid`、`/var/log/squid/access.log` に `TCP_DENIED` が出ていないか |
| SSM の操作が `InvalidSignatureException` などで失敗する | VM の時刻ずれ(`chronyc tracking`)。業務VMは infra を NTP サーバにしている |
