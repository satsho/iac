# RHEL 10.2のゴールデンイメージ(qcow2)を、Image BuilderのISOから1回だけ
# フルインストールして作る。できたqcow2は site.yml(kvm-install.yml)が
# backing fileとしてクローンして使う。詳細はREADME.md参照。
#
# ホスト名・SSH鍵・SSM登録・ロール別設定はここでは行わない(クローン後に
# site.ymlがSSH経由で行う)。ここでの目的はただ1つ、「正しくpoweroffされた
# ベースイメージを作る」こと。

packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "iso_path" {
  type        = string
  description = "Image BuilderのRHEL 10.2インストーラISOの絶対パス"
  default     = "/var/lib/libvirt/images/rhel-10.2-patch-mgmt.iso"
}

# Packerの仕様で「まだ存在しないディレクトリ」である必要があるため、
# 5台のVMのディスクを置く libvirt_image_dir(vars.ymlの値、
# /var/lib/libvirt/images/patch-mgmt)とは別のディレクトリにする。
variable "output_directory" {
  type    = string
  default = "/var/lib/libvirt/images/patch-mgmt-golden-build"
}

variable "vm_user" {
  type    = string
  default = "sho"
}

# RHELのqemu-kvmパッケージは、バイナリをqemu-system-x86_64ではなく
# /usr/libexec/qemu-kvmに置く(Debian系と違う)。$PATHにも入っていない。
variable "qemu_binary" {
  type    = string
  default = "/usr/libexec/qemu-kvm"
}

# ISOのキックスタートに設定したパスワード(Gitにコミットしない。
# `packer build -var "ssh_password=..."` で渡す)
variable "ssh_password" {
  type      = string
  sensitive = true
}

source "qemu" "rhel10_golden" {
  iso_url      = "file://${var.iso_path}"
  iso_checksum = "none" # ローカルファイルなのでチェックサム検証は省略

  disk_image = false
  disk_size  = "20G"
  format     = "qcow2"

  accelerator = "kvm"
  qemu_binary = var.qemu_binary
  memory      = 2048
  cpus        = 2
  # RHEL 10はx86-64-v3(AVX2等)のCPU機能が必須。virt-installの
  # --cpu host-passthrough と同じ意図で、ホストのCPU機能をそのまま見せる。
  qemuargs = [
    ["-cpu", "host"]
  ]

  net_device     = "virtio-net"
  disk_interface = "virtio"

  headless = true

  # ISOの起動メニューがそのまま無人インストールへ進む前提(今までの
  # virt-install --cdromと同じ挙動)。もしメニューで止まる場合は、ここに
  # 起動メニューの選択キー(例: ["<enter>"])を追加する。
  boot_wait = "5s"

  output_directory = var.output_directory
  vm_name           = "rhel10-golden.qcow2"

  ssh_username = var.vm_user
  ssh_password = var.ssh_password
  # フルインストール+初回起動を待つ。環境によっては延ばす。
  ssh_timeout = "45m"

  # ISOは自動でRHSMに登録される仕様なので、ゴールデンイメージのまま電源を切ると
  # クローンした5台が全部同じ登録情報を複製してしまう。ここで登録解除しておき、
  # 各VM側の既存のタスク(rhsm-mirror.yml/rhsm-workload.yml、「登録済みか確認し、
  # 未登録ならactivation keyで登録する」)が、クローン後にそれぞれ別の登録を
  # 行えるようにする。
  #
  # shutdown_commandはTTYなしでSSH実行されるため、sudoがパスワードを対話的に
  # 聞いてくる設定だと "a terminal is required" で止まる。sudo -S でパスワードを
  # 標準入力から渡す。
  shutdown_command = "echo '${var.ssh_password}' | sudo -S subscription-manager unregister; echo '${var.ssh_password}' | sudo -S poweroff"
  shutdown_timeout = "5m"
}

build {
  sources = ["source.qemu.rhel10_golden"]

  # キックスタートにnetworkの設定が無いため、インストール直後は有線接続の
  # 自動接続(autoconnect)が無効になっており、クローンした5台も同じ問題を
  # 引き継いでしまう(SSH接続待ちで固まる原因になる)。ゴールデンイメージの
  # 時点で直しておく。接続名(ens3)は環境によって変わる可能性があるため、
  # もし別の名前なら `nmcli con show` で確認して読み替えること。
  provisioner "shell" {
    inline = [
      "echo '${var.ssh_password}' | sudo -S nmcli con modify ens3 connection.autoconnect yes",
    ]
  }
}
