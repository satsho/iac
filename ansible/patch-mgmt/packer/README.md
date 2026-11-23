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

**`poweroff`も`reboot`も無い場合**でも、心配しなくてよい。フルインストールが
走るのはこのゴールデンイメージを作る時の**1回だけ**なので、VNCで1回だけ画面を
見て、止まっていたらEnterを押せばよい(ISOの再構築やキックスタートの書き換えは
不要)。

```bash
virsh list --all                 # Packerが作ったVM名を確認(packer-<乱数>のような名前)
virsh vncdisplay <VM名>          # 例: 127.0.0.1:0 のような値が出る
# SSHトンネルを張ってVNCクライアントで接続するか、`virt-viewer`を使う
```

Anacondaのインストールが終わって「Enterを押して再起動」の画面で止まっていたら
Enterを押す。再起動後、PackerがSSHで接続できるようになれば自動で進む。

## ビルド

Packerの仕様上、`output_directory`は**まだ存在しないディレクトリ**である必要が
あるため、5台のVM用ディスクを置く`libvirt_image_dir`(`vars.yml`の値、
`/var/lib/libvirt/images/patch-mgmt`)とは別の、一時的なビルド用ディレクトリに
出力する。ビルドが終わったら、できたqcow2を`libvirt_image_dir`へ移動する。

```bash
cd ansible/patch-mgmt/packer
packer init rhel10-golden.pkr.hcl
packer build \
  -var "iso_path=/var/lib/libvirt/images/rhel-10.2-patch-mgmt.iso" \
  -var "ssh_password=<ISOに設定したshoユーザーのパスワード>" \
  rhel10-golden.pkr.hcl

# できたqcow2を、site.ymlが探す場所(vars.ymlのgolden_image_path)へ移動する
mkdir -p /var/lib/libvirt/images/patch-mgmt
mv /var/lib/libvirt/images/patch-mgmt-golden-build/rhel10-golden.qcow2 \
   /var/lib/libvirt/images/patch-mgmt/
rmdir /var/lib/libvirt/images/patch-mgmt-golden-build
```

これで `/var/lib/libvirt/images/patch-mgmt/rhel10-golden.qcow2` ができていれば、
`site.yml` 側の `golden_image_path` のチェックを通る。

## 作り直すとき

ゴールデンイメージ自体を更新したい場合(RHELのマイナーバージョンを上げる等)は、
まず一時ビルド用ディレクトリが残っていないことを確認してから(`rm -rf
/var/lib/libvirt/images/patch-mgmt-golden-build`、Packerは既存のディレクトリに
出力できないため)、`packer build`を再実行し、上の移動手順をもう一度行う。
既存のVMは`destroy.yml`で消してから`site.yml`を流し直す(クローン元が変わる
だけで、既に作られたVMのディスクには影響しない)。

## Windows側の構築方針

Windowsはsysprepを使わない。ゴールデンイメージは「OpenSSH Server有効化まで済んだ状態」で
普通にシャットダウンし、クローン後はRHELと同じ発想(SSH経由のAnsibleで仕上げる)で
コンピュータ名・固定IPを設定する。これにより**コンピュータ名・SIDがクローン間で重複する**
(sysprepの`/generalize`をしないため)。ドメイン非参加のワークグループ構成で、
SSH/SSMだけで管理する自宅ラボという前提では実害がほぼ無いと判断して、このやり方を
選んでいる。ADドメインに参加させる、またはSMBでの名前解決に依存する用途には向かない。

固定IP・コンピュータ名の変更は、クローンしたディスクに`virt-customize`の
firstboot機能(Windows対応、内部的にはレジストリのRunOnce経由)でPowerShell
スクリプトを仕込むことで実現している(`templates/windows-firstboot.ps1.j2`、
`tasks/kvm-install-windows.yml`)。

### 前提パッケージ(KVMホスト)

```bash
sudo dnf install -y guestfs-winsupport libguestfs-winsupport
```

これが無いと、`virt-customize`がWindowsイメージ(NTFS・レジストリ)を正しく編集できない。

### ビルド

```bash
cd ansible/patch-mgmt/packer
packer init windows2025-golden.pkr.hcl

# ADMIN_PASSWORD_PLACEHOLDERを実際のパスワードに置き換えたコピーを作る(Gitにコミットしない)。
# ファイル名は必ずautounattend.xmlにすること(Windows SetupがCD/ISOのルートで自動検出する
# ファイル名が厳密にこれで、違う名前だと応答ファイルが一切認識されず完全手動インストール
# 扱いになる。症状: エディション選択が手動プロンプトになる、ComputerNameが自動生成名のまま、
# AutoLogon/FirstLogonCommandsが実行されずsshdが永遠に起動しない)。
mkdir -p /tmp/windows2025-golden-seed
sed "s/ADMIN_PASSWORD_PLACEHOLDER/<password>/g" \
  windows2025-golden-autounattend.xml > /tmp/windows2025-golden-seed/autounattend.xml

packer build \
  -var "iso_path=/var/lib/libvirt/images/windows-server-2025-eval.iso" \
  -var "admin_password=<password>" \
  -var "autounattend_path=/tmp/windows2025-golden-seed/autounattend.xml" \
  windows2025-golden.pkr.hcl

mv /var/lib/libvirt/images/patch-mgmt-golden-build-windows/windows2025-golden.qcow2 \
   /var/lib/libvirt/images/patch-mgmt/
rmdir /var/lib/libvirt/images/patch-mgmt-golden-build-windows
rm -rf /tmp/windows2025-golden-seed
```

これで`/var/lib/libvirt/images/patch-mgmt/windows2025-golden.qcow2`ができていれば、
`site.yml`側の`golden_image_path_windows`のチェックを通る。

**未検証の部分**: このWindows版パイプライン(Packerのssh通信、virt-customizeの
Windows firstboot機能、WSUS関連のPowerShellスクリプト)は実機で動作確認できていない。
実行してエラーが出た場合、特にvirt-customizeのfirstboot周りとWSUSのPowerShellコマンドレット
(`UpdateServices`モジュール)の挙動を疑うこと。
