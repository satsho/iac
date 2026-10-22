# ---- ミラー用データボリュームのマウント ----
# EBSボリュームはインスタンスとは別リソースなので、インスタンスを作り直しても
# reposync済みのデータが残る。アタッチはインスタンス起動後に行われるため、
# デバイスが見えるまで待つ(NitroではボリュームIDからデバイスを特定できる)。
data_dev="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${volume_serial}"
for _ in $(seq 1 60); do
  [ -e "$data_dev" ] && break
  sleep 10
done
if ! blkid "$data_dev" >/dev/null 2>&1; then
  mkfs.xfs "$data_dev"
fi
mkdir -p "${mount_point}"
data_uuid=$(blkid -s UUID -o value "$data_dev")
grep -q "$data_uuid" /etc/fstab || echo "UUID=$data_uuid ${mount_point} xfs defaults,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "${mount_point}" || mount "${mount_point}"
restorecon -R "${mount_point}"
