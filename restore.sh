#!/usr/bin/env bash
set -e

script_dir=$(dirname "${0}")
# shellcheck source=functions.sh
. "$script_dir/functions.sh"
# shellcheck source=const.sh
. "$script_dir/const.sh"

SERVER_NAME=minecraft
BUCKET=minecraft-backup
VOLUME_PATH=/var/lib/docker/volumes/mc-volume/_data
ssh_key=~/.ssh/id_rsa
ssh_opts=(-T -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)

echo ""
echo "==================== ワールドの復元 ===================="
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
  printf 'namespace=%q\n' "$(oci os ns get --query 'data' --raw-output)"
) > "$find_out" 2> "$find_log" &
wait_with_dots $! || true

external_ip=""
namespace=""
# shellcheck disable=SC1090
. "$find_out"
rm -f "$find_out" "$find_log"

if [ -z "$external_ip" ] || [ "$external_ip" == "null" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] 起動中のサーバーが見つかりませんでした。"
  echo ""
  exit 1
fi
echo " 完了"

# LIST ==========
echo -n "  バックアップを検索中 "
list_out=$(mktemp)
oci os object list --bucket-name "$BUCKET" --namespace "$namespace" \
  --query 'data[].name' --output json > "$list_out" 2> /dev/null &
wait_with_dots $! || true

# Sorted newest first: the names carry the timestamp, so a reverse sort is
# enough and there is no second call for metadata.
mapfile -t backups < <(grep -oE '"[^"]+\.tar\.gz"' "$list_out" 2> /dev/null \
  | tr -d '"' | sort -r)
rm -f "$list_out"

if [ "${#backups[@]}" -eq 0 ]; then
  echo " 完了"
  cat <<EOS

バックアップが見つかりませんでした。
先にメニューから backup を実行してください。

EOS
  exit 0
fi
echo " 完了"

cat <<EOS

-*-*-*-*- [復元するバックアップを選択] -*-*-*-*-

EOS
i=1
for b in "${backups[@]}"; do
  echo "[$i] $b"
  i=$((i + 1))
done
echo ""
echo -n "Select (Default: 1): "
read -r backup_num
if [ "$backup_num" == "" ]; then backup_num=1 ; fi
if [[ ! ("$backup_num" =~ ^[1-9][0-9]*$) ]] || [ "$backup_num" -gt "${#backups[@]}" ]; then
  echo "[ERROR] 表示された番号から選んで下さい。"
  exit 1
fi
object_name=${backups[$backup_num-1]}
local_file="${HOME}/restore-${object_name}"

cat <<EOS

-*-*-*-*- [復元の確認] -*-*-*-*-

 復元するもの : ${object_name}

[WARN] いま遊んでいるワールドは失われ、元に戻せません。
       残しておきたい場合は、先に backup を実行してください。

接続中のプレイヤーは切断されます。

EOS
echo -n "本当に復元しますか? [y/N]: "
read -r restore_yn
if [ "$restore_yn" != "y" ]; then
  echo ""
  echo "中止しました。"
  echo ""
  exit 1
fi

echo ""

# DOWNLOAD ==========
# Fetched and checked before the running world is touched. A broken archive
# found halfway through the restore would leave nothing to go back to.
echo -n "  ダウンロード中 "
get_log=$(mktemp)
oci os object get --bucket-name "$BUCKET" --namespace "$namespace" \
  --name "$object_name" --file "$local_file" > "$get_log" 2>&1 &
get_status=0
wait_with_dots $! || get_status=$?

if [ "$get_status" -ne 0 ] || [ ! -s "$local_file" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] ダウンロードに失敗しました。ワールドはそのままです。"
  echo "--------------------------------------------------------------------"
  cat "$get_log"
  echo "--------------------------------------------------------------------"
  rm -f "$get_log" "$local_file"
  exit 1
fi
rm -f "$get_log"
echo " 完了"

if ! tar tzf "$local_file" > /dev/null 2>&1; then
  echo ""
  echo "[ERROR] バックアップが壊れています。復元を中止しました。"
  echo "        ワールドはそのままです。"
  echo ""
  rm -f "$local_file"
  exit 1
fi

# STOP ==========
echo -n "  サーバーを停止中 "
stop_log=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo docker stop -t 60 mc-server" > "$stop_log" 2>&1 &
stop_status=0
wait_with_dots $! || stop_status=$?

if [ "$stop_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] サーバーを停止できませんでした。ワールドはそのままです。"
  echo "--------------------------------------------------------------------"
  cat "$stop_log"
  echo "--------------------------------------------------------------------"
  rm -f "$stop_log" "$local_file"
  exit 1
fi
rm -f "$stop_log"
echo " 完了"

# REPLACE ==========
# The old world is cleared first. Unpacking over it would leave behind any file
# the backup does not have, and a world made of two different saves is worse
# than either one.
echo -n "  ワールドを書き戻し中 "
put_log=$(mktemp)
# Only worlds is removed, and the whole directory goes rather than its contents:
# that takes the dot files with it, and unpacking over a world left in place
# would keep any file the backup does not have. A world made of two different
# saves is worse than either one.
#
# The rest of the volume is left alone. It holds the Bedrock server itself,
# which has nothing to do with which save is loaded.
#
# VOLUME_PATH is a constant defined here, so expanding it locally is intended.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo rm -rf ${VOLUME_PATH}/worlds && sudo tar xzf - -C ${VOLUME_PATH}" \
  < "$local_file" > "$put_log" 2>&1 &
put_status=0
wait_with_dots $! || put_status=$?

start_log=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo docker start mc-server" > "$start_log" 2>&1 || true
rm -f "$start_log" "$local_file"

if [ "$put_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] 書き戻しに失敗しました。サーバーは再開しています。"
  echo "--------------------------------------------------------------------"
  cat "$put_log"
  echo "--------------------------------------------------------------------"
  rm -f "$put_log"
  exit 1
fi
rm -f "$put_log"
echo " 完了"

echo ""
echo -n "マインクラフト起動中 "

mc_info=$(mktemp)
if wait_for_server "$external_ip" 900 "$mc_info"; then
  # shellcheck disable=SC1090
  . "$mc_info"
  rm -f "$mc_info"
  cat <<EOS

復元が完了しました！

################################################################################
${external_ip}
################################################################################

 復元したもの : ${object_name}
 バージョン   : ${MC_VERSION:-(取得できませんでした)}

EOS
else
  rm -f "$mc_info"
  cat <<EOS

[WARN] 15 分待ちましたが、サーバーが応答しませんでした。

書き戻しは完了しています。起動に時間がかかっているだけかもしれません。
下記でログを確認できます。

  ssh -i ${ssh_key} ubuntu@${external_ip} 'sudo docker logs mc-server | tail -30'

EOS
  exit 1
fi
