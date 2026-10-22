# ---- infra: repositoryからrsyncで同期するミラー。業務サーバにはhttpで配る ----
dnf install -y httpd rsync

mkdir -p /var/www/html/repos/rhel

cat <<'EOF' > /usr/local/sbin/patch-mirror-sync.sh
#!/bin/bash
set -euo pipefail
src="rsync://${repository_ip}/rhel/"
dst=/var/www/html/repos/rhel/

# repository側がreposync中なら、途中の状態をコピーしないよう今回は見送る
if rsync --list-only "$src.sync-in-progress" >/dev/null 2>&1; then
  echo "repository is running reposync, skipping this run"
  exit 0
fi

# 1回目: パッケージ本体だけを先に追加する。メタデータは古いまま(=古いパッケージを指したまま)
#        なので、同期中に業務サーバがdnfを実行しても「メタデータにあるのにパッケージが無い」
#        状態にはならない。
rsync -rlt --exclude='repodata/' --exclude='.last-sync' --exclude='.sync-in-progress' "$src" "$dst"
# 2回目: メタデータを差し替え、上流で消えたパッケージを削除する
rsync -rlt --delete --delay-updates --exclude='.sync-in-progress' "$src" "$dst"
restorecon -R "$dst"
EOF
chmod 755 /usr/local/sbin/patch-mirror-sync.sh

cat <<'EOF' > /etc/systemd/system/patch-mirror-sync.service
[Unit]
Description=Sync the local mirror from the repository server
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/patch-mirror-sync.sh
TimeoutStartSec=6h
EOF

cat <<'EOF' > /etc/systemd/system/patch-mirror-sync.timer
[Unit]
Description=Daily rsync from the repository server

[Timer]
OnCalendar=${mirror_sync_schedule}
Persistent=true

[Install]
WantedBy=timers.target
EOF

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http
  firewall-cmd --reload
fi

# 初回はrepositoryのreposyncが終わってから手動で同期する(README参照)
systemctl daemon-reload
systemctl enable --now httpd patch-mirror-sync.timer
