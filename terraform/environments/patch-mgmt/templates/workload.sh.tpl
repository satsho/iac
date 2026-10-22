# ---- 業務サーバ: infraのミラーだけを参照する ----
# PAYG AMI(auto-registration v2)はRHSMに自動登録されると redhat.repo を生成して
# Red Hat CDNへ直接取りに行く。ミラーを迂回したパッケージ取得を防ぐため、
# subscription-managerによるrepoファイル管理を止め、既存のrepo定義もすべて無効化する。
if command -v subscription-manager >/dev/null 2>&1; then
  subscription-manager config --rhsm.manage_repos=0
fi
for repo_file in /etc/yum.repos.d/*.repo; do
  [ -e "$repo_file" ] || continue
  sed -i 's/^enabled[[:space:]]*=[[:space:]]*1/enabled=0/' "$repo_file"
done

# gpgcheckはRed Hatの署名鍵で行うので、ミラーをhttpで配っても改ざんは検出できる
cat <<'EOF' > /etc/yum.repos.d/infra-mirror.repo
%{ for name, repo_id in upstream_repos ~}
[infra-${name}]
name=infra mirror of ${repo_id} (${release_dir})
baseurl=http://${infra_ip}/repos/rhel/${release_dir}/${name}/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release

%{ endfor ~}
EOF
