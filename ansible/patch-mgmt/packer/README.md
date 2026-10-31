# ゴールデンイメージ(Packer)

5台それぞれでフルのOSインストールをやり直す代わりに、**1回だけ** RHEL 10.2 の
ゴールデンイメージ(qcow2)を作り、`site.yml`(`kvm-install.yml`)はそれを
クローン(qcow2のbacking file)して使う。

フルインストールが1回だけになるので:

- Anacondaのインストーラに関わる不具合(後述の`poweroff`問題など)に当たる
  リスクが5回分から1回分に減る
- 2台目以降のVM作成は「ディスクをコピーして起動するだけ」になり、数秒〜数十秒で終わる

ホスト名・SSH鍵・SSM登録・ロール別設定は、クローン後も今まで通り`site.yml`が
SSH経由で行う(ここは無改造)。

## 前提: ISOのキックスタートに`poweroff`があるか確認する

Image BuilderのISOは、Anacondaのインストールが終わった後に**自動で電源を切る**
(`poweroff`)か、**自動で再起動する**(`reboot`)設定になっている必要がある。
どちらも無い場合、インストール完了後に「Enterを押してください」の画面で
止まったままになり、Packer(も、今までのvirt-installも)インストールの完了を
検知できない。

確認方法(ISOをマウントしてキックスタートを覗く):

```bash
sudo mkdir -p /mnt/rhel-iso
sudo mount -o loop /var/lib/libvirt/images/rhel-10.2-patch-mgmt.iso /mnt/rhel-iso
# キックスタートファイルの場所はISOの作り方によって異なる。よくある場所:
find /mnt/rhel-iso -iname "*.ks" -o -iname "ks.cfg" 2>/dev/null
# 見つかったファイルの末尾に poweroff か reboot があるか確認
tail -20 /mnt/rhel-iso/<見つかったパス>
sudo umount /mnt/rhel-iso
```

**`poweroff`も`reboot`も無い場合**、ISOを作り直す(Image Builderのblueprintに
`reboot`の設定を追加する。console.redhat.comのImage Builderでは「Set up to
reboot after installation」のようなカーネル引数オプションがある場合がある)か、
ISOを直接編集して追記する(**この場合はPackerの`boot_command`でカーネル引数に
`inst.ks=`を上書きする方法が確実**。下記テンプレートの`boot_command`を参照。
ISOの再構築(`xorriso`)は面倒な割に失敗しやすいので、まずはこちらを試す)。

VNCでインストーラの画面を直接見て原因を確認するのが一番確実:

```bash
virsh vncdisplay <VM名>   # 例: 127.0.0.1:0 のような値が出る
# SSHトンネルを張ってVNCクライアントで接続するか、`virt-viewer`を使う
```

## ビルド

```bash
cd ansible/patch-mgmt/packer
packer init rhel10-golden.pkr.hcl
packer build \
  -var "iso_path=/var/lib/libvirt/images/rhel-10.2-patch-mgmt.iso" \
  -var "ssh_password=<ISOに設定したshoユーザーのパスワード>" \
  rhel10-golden.pkr.hcl
```

成功すると `{{ libvirt_image_dir }}/rhel10-golden.qcow2`
(`/var/lib/libvirt/images/patch-mgmt/rhel10-golden.qcow2`)にゴールデンイメージができる。
これができていれば `site.yml` 側の `golden_image_path` のチェックを通る。

## 作り直すとき

ゴールデンイメージ自体を更新したい場合(RHELのマイナーバージョンを上げる等)は、
`packer build`を再実行してファイルを上書きし、既存のVMは`destroy.yml`で消してから
`site.yml`を流し直す(クローン元が変わるだけで、既に作られたVMのディスクには
影響しない)。
