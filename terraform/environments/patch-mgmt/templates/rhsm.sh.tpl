# ---- Red Hat CDN(EUS)の利用設定 ----
# RHEL 9.7/10.1以降のAWS Marketplace(PAYG)AMIは auto-registration v2 により、起動後に
# rhsmcertdが非同期でRHSM(AWSアカウントに紐づく匿名org)へ自動登録し、RHUIではなく
# Red Hat CDNからコンテンツを取得する。登録が終わるまで待ってからリポジトリを設定する。
for _ in $(seq 1 60); do
  subscription-manager identity >/dev/null 2>&1 && break
  sleep 30
done
# 30分待っても登録されなければここで失敗させる(10.0以前のRHUI方式のAMIを使っている等)
subscription-manager identity

%{ if rhel_release != "" ~}
subscription-manager release --set="${rhel_release}"
%{ else ~}
subscription-manager release --unset
%{ endif ~}
# このサーバ自身のOS更新もreposync対象と同じリポジトリだけにして、業務サーバと同じ
# マイナーリリースに揃える。EUSが使えない場合はここで失敗するので、upstream_repos変数を
# 非EUSのリポジトリIDに切り替える(README参照)。
subscription-manager repos --disable='*' ${repo_enable_args}
dnf clean all
