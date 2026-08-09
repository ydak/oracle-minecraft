#!/usr/bin/env bash
set -e

script_dir=$(dirname "${0}")
# shellcheck source=functions.sh
. "$script_dir/functions.sh"
# shellcheck source=const.sh
. "$script_dir/const.sh"


echo ""
echo "==================== ワールドのバックアップ ===================="
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

stamp=$(date +%Y%m%d-%H%M%S)
object_name="world-${stamp}.tar.gz"
local_file="${HOME}/${object_name}"

cat <<EOS

-*-*-*-*- [バックアップの確認] -*-*-*-*-

ワールドのデータを取り出し、オブジェクト・ストレージに保存します。

 保存先 : ${BUCKET}/${object_name}

取り出している間、サーバーを一時的に止めます。数十秒ほどです。
接続中のプレイヤーは切断されます。

EOS
echo -n "続けますか? [y/N]: "
read -r backup_yn
if [ "$backup_yn" != "y" ]; then
  echo ""
  echo "中止しました。"
  echo ""
  exit 1
fi

echo ""

# STOP ==========
# Stopped rather than copied live: the server writes the world continuously, and
# an archive taken mid-write restores as a corrupt world. The image turns
# SIGTERM into a clean save, so a graceful stop is what makes the copy safe.
#
# systemctl stop would not do it. The unit is oneshot with RemainAfterExit and
# has no ExecStop, so the container it started keeps running.
echo -n "  サーバーを停止中 "
stop_log=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo docker stop -t 60 mc-server" > "$stop_log" 2>&1 &
stop_status=0
wait_with_dots $! || stop_status=$?

if [ "$stop_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] サーバーを停止できませんでした。"
  echo "--------------------------------------------------------------------"
  cat "$stop_log"
  echo "--------------------------------------------------------------------"
  rm -f "$stop_log"
  exit 1
fi
rm -f "$stop_log"
echo " 完了"

# COPY ==========
# Streamed straight into Cloud Shell rather than written on the instance first.
# The instance never needs credentials of its own that way, and the boot volume
# does not have to hold a second copy of the world.
echo -n "  ワールドを取り出し中 "
copy_log=$(mktemp)
# Only worlds. The rest of the volume is the Bedrock server itself, which the
# container downloads again on every start, plus files the image rewrites from
# the environment variables in run.sh. Carrying all of it made a barely played
# world into a 157MB archive, and restoring it would put an old server binary
# back over a current one.
#
# VOLUME_PATH is a constant defined here, so expanding it locally is what is
# wanted.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo test -d ${VOLUME_PATH}/worlds || { echo 'worlds が見つかりませんでした' >&2; exit 1; }
   sudo tar czf - -C ${VOLUME_PATH} worlds" > "$local_file" 2> "$copy_log" &
copy_status=0
wait_with_dots $! || copy_status=$?

# START ==========
# Started before the copy is judged. Whatever went wrong, leaving the server
# down is worse than reporting the failure a moment later.
start_log=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo docker start mc-server" > "$start_log" 2>&1 || true
rm -f "$start_log"

if [ "$copy_status" -ne 0 ] || [ ! -s "$local_file" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] ワールドを取り出せませんでした。サーバーは再開しています。"
  echo "--------------------------------------------------------------------"
  cat "$copy_log"
  echo "--------------------------------------------------------------------"
  rm -f "$copy_log" "$local_file"
  exit 1
fi
rm -f "$copy_log"
echo " 完了"

# The archive is checked before it is stored. An unreadable backup is worse than
# no backup, because it is only discovered when it is needed.
if ! tar tzf "$local_file" > /dev/null 2>&1; then
  echo ""
  echo "[ERROR] 取り出したデータが壊れています。保存を中止しました。"
  echo ""
  rm -f "$local_file"
  exit 1
fi

# BUCKET ==========
echo -n "  保存先を準備中 "
bucket_log=$(mktemp)
(
  if ! oci os bucket get --bucket-name "$BUCKET" --namespace "$namespace" > /dev/null 2>&1; then
    oci os bucket create --compartment-id "$compartment_id" \
      --name "$BUCKET" --namespace "$namespace"
  fi
) > "$bucket_log" 2>&1 &
bucket_status=0
wait_with_dots $! || bucket_status=$?

if [ "$bucket_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] バケットを準備できませんでした。"
  echo "--------------------------------------------------------------------"
  cat "$bucket_log"
  echo "--------------------------------------------------------------------"
  echo ""
  echo "取り出したデータは下記に残っています。"
  echo "  ${local_file}"
  echo ""
  rm -f "$bucket_log"
  exit 1
fi
rm -f "$bucket_log"
echo " 完了"

# UPLOAD ==========
echo -n "  アップロード中 "
put_log=$(mktemp)
oci os object put --bucket-name "$BUCKET" --namespace "$namespace" \
  --file "$local_file" --name "$object_name" --force > "$put_log" 2>&1 &
put_status=0
wait_with_dots $! || put_status=$?

if [ "$put_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] アップロードに失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$put_log"
  echo "--------------------------------------------------------------------"
  echo ""
  echo "取り出したデータは下記に残っています。"
  echo "  ${local_file}"
  echo ""
  rm -f "$put_log"
  exit 1
fi
rm -f "$put_log"
echo " 完了"

size=$(du -h "$local_file" | cut -f1)

# The copy in the home directory is kept rather than cleaned up. Cloud Shell has
# no command that downloads a file: the only way to get one onto your own
# machine is the Menu, which asks for the name of a file in the home directory.
# Leaving it there is what makes that possible, and the name is printed so it
# can be typed straight in.
cat <<EOS

バックアップが完了しました。

 保存先 : ${BUCKET}/${object_name}
 サイズ : ${size}

戻す場合はメニューから restore を選んでください。

--------------------------------------------------------------------
 手元のパソコンに保存したい場合
--------------------------------------------------------------------
Cloud Shell 右上の [Menu] から [Download] を選び、下記を入力します。

  ${object_name}

不要であれば、下記で消せます。

  rm ~/${object_name}

無料枠のオブジェクト・ストレージは 20GB までです。古いものは
コンソールの「ストレージ → バケット」から削除できます。

EOS
