#!/usr/bin/env bash
set -e

script_dir=$(dirname "${0}")
# shellcheck source=functions.sh
. "$script_dir/functions.sh"
# shellcheck source=const.sh
. "$script_dir/const.sh"


echo ""
echo "==================== Minecraft の更新 ===================="
echo ""

if [ -z "${OCI_TENANCY:-}" ]; then
  echo "[ERROR] OCI_TENANCY が設定されていません。Oracle Cloud Shell で実行して下さい。"
  exit 1
fi
compartment_id=$OCI_TENANCY

# INSTANCE ==========
echo -n "確認中 "
find_out=$(mktemp)
find_log=$(mktemp)
(
  set -e
  # The backticks are JMESPath literals, not command substitution.
  # shellcheck disable=SC2016
  id=$(oci compute instance list --compartment-id "$compartment_id" \
    --display-name "$SERVER_NAME" \
    --query 'data[?"lifecycle-state"==`RUNNING`]|[0].id' --raw-output)
  vnic_id=$(oci compute instance list-vnics --instance-id "$id" \
    --query 'data[0].id' --raw-output)
  printf 'external_ip=%q\n' \
    "$(oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output)"
) > "$find_out" 2> "$find_log" &
wait_with_dots $! || true

external_ip=""
# shellcheck disable=SC1090
. "$find_out"
rm -f "$find_out"

if [ -z "$external_ip" ] || [ "$external_ip" == "null" ]; then
  echo " 失敗"
  cat <<EOS

[ERROR] 起動中のサーバーが見つかりませんでした。

--------------------------------------------------------------------
$(cat "$find_log")
--------------------------------------------------------------------

EOS
  rm -f "$find_log"
  exit 1
fi
rm -f "$find_log"
echo " 完了"

cat <<EOS

-*-*-*-*- [更新の内容] -*-*-*-*-

三つをまとめて最新にします。

 ・Ubuntu のパッケージ
 ・itzg/minecraft-bedrock-server イメージ
 ・Minecraft 統合版サーバー本体

本体はコンテナの起動時に取得されるため、入れ替えるだけで最新になります。
接続中のプレイヤーは切断されます。ワールドのデータはそのまま残ります。

EOS
echo -n "更新しますか? [y/N]: "
read -r update_yn
if [ "$update_yn" != "y" ]; then
  echo ""
  echo "中止しました。"
  echo ""
  exit 1
fi

echo ""

# HOST ==========
echo -n "  ホストを更新中 "
host_log=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" "sudo bash -s" > "$host_log" 2>&1 <<'EOS' &
set -e
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb
apt-get update
apt-get upgrade -y
EOS
host_status=0
wait_with_dots $! || host_status=$?

if [ "$host_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] ホストの更新に失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$host_log"
  echo "--------------------------------------------------------------------"
  rm -f "$host_log"
  exit 1
fi
rm -f "$host_log"
echo " 完了"

# MINECRAFT ==========
# Restarting the unit re-runs /opt/minecraft/run.sh, which pulls the image again
# and replaces the container. The Bedrock binary is downloaded at container
# start, so it comes along with it. No reboot is involved.
echo -n "  Minecraft を更新中 "
mc_log=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo systemctl restart minecraft.service" > "$mc_log" 2>&1 &
mc_status=0
wait_with_dots $! || mc_status=$?

if [ "$mc_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] Minecraft の更新に失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$mc_log"
  echo "--------------------------------------------------------------------"
  rm -f "$mc_log"
  exit 1
fi
rm -f "$mc_log"
echo " 完了"

echo ""
echo -n "マインクラフト起動中 "

mc_info=$(mktemp)
if wait_for_server "$external_ip" 900 "$mc_info"; then
  # shellcheck disable=SC1090
  . "$mc_info"
  rm -f "$mc_info"
  cat <<EOS

更新が完了しました！

################################################################################
${external_ip}
################################################################################

 バージョン : ${MC_VERSION:-(取得できませんでした)}

EOS
else
  rm -f "$mc_info"
  cat <<EOS

[WARN] 15 分待ちましたが、サーバーが応答しませんでした。

更新は適用されています。起動に時間がかかっているだけかもしれません。
下記でログを確認できます。

  ssh -i ${ssh_key} ubuntu@${external_ip} 'sudo docker logs mc-server | tail -30'

EOS
  exit 1
fi
