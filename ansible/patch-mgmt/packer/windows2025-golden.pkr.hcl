# Windows Server 2025のゴールデンイメージ(qcow2)を、ISOから1回だけフルインストールして作る。
# rhel10-golden.pkr.hclと同じ考え方(site.yml/kvm-install-windows.ymlがこれをクローンして使う)。
#
# RHEL版と違い、ここではsysprepを行わない(README.md「Windows側の構築方針」参照:
# ドメイン非参加の自宅ラボではコンピュータ名・SIDの重複による実害は無いという判断)。
# クローンごとの固定IP・コンピュータ名変更は、クローン後にkvm-install-windows.ymlが
# virt-customizeのfirstbootスクリプトで行う。

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
  description = "Windows Server 2025評価版インストーラISOの絶対パス"
  default     = "/var/lib/libvirt/images/windows-server-2025-eval.iso"
}

# rhel10-golden.pkr.hclと同じ理由で、まだ存在しないディレクトリである必要がある
variable "output_directory" {
  type    = string
  default = "/var/lib/libvirt/images/patch-mgmt-golden-build-windows"
}

variable "qemu_binary" {
  type    = string
  default = "/usr/libexec/qemu-kvm"
}

# windows2025-golden-autounattend.xmlのADMIN_PASSWORD_PLACEHOLDERに書き込むパスワード。
# このまま常用パスワードにはしない(クローン後、common-windows.ymlがSSH鍵登録・
# パスワード認証無効化を行う)。Gitにコミットしない。
variable "admin_password" {
  type      = string
  sensitive = true
}

# cd_filesで自動生成する一時ファイル。ADMIN_PASSWORD_PLACEHOLDERを実際の値に
# 置き換えたコピーをbuild前に用意しておくこと(packer build前に下記を実行する):
#   mkdir -p /tmp/windows2025-golden-seed
#   sed "s/ADMIN_PASSWORD_PLACEHOLDER/<password>/g" \
#     windows2025-golden-autounattend.xml > /tmp/windows2025-golden-seed/autounattend.xml
#
# ファイル名は必ず"autounattend.xml"にすること。Windows SetupはCD/ISOのルートに
# あるこの厳密なファイル名だけを自動検出する(ボリュームラベルのcd_labelは無関係)。
# 違う名前だと応答ファイルが一切認識されず、完全手動インストールの扱いになる
# (エディション選択の手動プロンプトが出る、ComputerNameが自動生成名になる、
# AutoLogon/FirstLogonCommandsが実行されずsshdが永遠に起動しない、という形で現れる)。
variable "autounattend_path" {
  type        = string
  description = "パスワード置換済みのautounattend.xmlの絶対パス(ファイル名は必ずautounattend.xmlにすること)"
  default     = "/tmp/windows2025-golden-seed/autounattend.xml"
}

# virtio-win.isoからNetKVM\2k25フォルダをコピーしておくディレクトリ
# (packer build前に下記を実行する):
#   mkdir -p /tmp/windows2025-golden-seed/NetKVM
#   sudo mount -o loop /var/lib/libvirt/images/virtio-win.iso /mnt/virtio-win
#   cp -r /mnt/virtio-win/NetKVM/2k25 /tmp/windows2025-golden-seed/NetKVM/
#   sudo umount /mnt/virtio-win
#
# autounattend.xmlと同じcd_filesにまとめて1枚のISOにする(qemuargsに自分で
# "-drive"を追加するとビルダー自動生成分と衝突するため、2枚目のCD-ROMを別途
# 追加する代わりにこの方法を取っている)。
variable "netkvm_driver_path" {
  type        = string
  description = "virtio-win.isoからコピーしたNetKVMドライバフォルダの絶対パス"
  default     = "/tmp/windows2025-golden-seed/NetKVM"
}

source "qemu" "windows2025_golden" {
  iso_url      = "file://${var.iso_path}"
  iso_checksum = "none"

  disk_image = false
  disk_size  = "40G"
  format     = "qcow2"

  accelerator = "kvm"
  qemu_binary = var.qemu_binary
  memory      = 4096
  cpus        = 2
  # hv-*はvirt-install(--os-variant win*)が自動で付けるHyper-V準仮想化拡張と同じもの
  # (実際に動いているpatch-test-winの起動コマンドから採取)。これが無いと、最近のWindowsは
  # 早期ブート時のタイミング関連で不安定になりクラッシュすることがある。
  # qemuargsに"-drive"を自分で追加すると、ビルダーが自動生成する"-drive"
  # (ディスク本体・インストーラISO・autounattend ISO)が全部それに差し替わってしまう
  # (同名フラグの衝突)。なので"-drive"はここに書かず、virtio-net用のドライバは
  # cd_filesでautounattend.xmlと同じISOに同梱する方式にしている(下記参照)。
  qemuargs = [
    ["-cpu", "host,hv-time=on,hv-relaxed=on,hv-vapic=on,hv-spinlocks=0x1fff,hv-vpindex=on,hv-runtime=on,hv-synic=on,hv-stimer=on,hv-frequencies=on,hv-tlbflush=on,hv-ipi=on,hv-evmcs=on,hv-avic=on"]
  ]

  # NICはvirtio-net(実際に動いているpatch-test-winと同じ構成に合わせた。e1000だと
  # WinPE起動直後にクラッシュ→再起動ループする問題があった)。virtio-netはWindows標準の
  # インボックスドライバが無いため、NetKVMドライバをcd_filesでautounattend.xmlと
  # 同じISOに同梱し、autounattend.xml側のDriverPathsで読み込む。
  net_device     = "virtio-net"
  disk_interface = "ide"

  headless  = true
  boot_wait = "5s"

  # autounattend.xmlとNetKVMドライバを1枚のISOにまとめて3枚目のCD-ROMとして付ける
  # (手動のgenisoimageステップが不要になる)
  cd_files = [var.autounattend_path, var.netkvm_driver_path]
  cd_label = "autounattend"

  output_directory = var.output_directory
  vm_name          = "windows2025-golden.qcow2"

  # Windows標準のOpenSSH Server経由。golden-autounattend.xmlのFirstLogonCommandsで
  # 有効化済み。既定シェルはPowerShellにしてある。
  communicator = "ssh"
  ssh_username = "Administrator"
  ssh_password = var.admin_password
  ssh_timeout  = "60m"

  # cmd.exeではなくPowerShellが既定シェルなので、PowerShellのコマンドレットで直接シャットダウンする。
  shutdown_command = "Stop-Computer -Force"
  shutdown_timeout = "10m"
}

build {
  sources = ["source.qemu.windows2025_golden"]
}
