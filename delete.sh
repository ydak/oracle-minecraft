#!/usr/bin/env bash
set -e

script_dir=$(dirname "${0}")
# shellcheck source=functions.sh
. "$script_dir/functions.sh"
# shellcheck source=const.sh
. "$script_dir/const.sh"

SERVER_NAME=minecraft
VCN_NAME=minecraft-vcn
SUBNET_NAME=minecraft-subnet
IGW_NAME=minecraft-igw

echo ""
echo "==================== Minecraft サーバーの削除 ===================="
echo ""

if ! command -v oci > /dev/null; then
  echo "[ERROR] 'oci' が見つかりません。Oracle Cloud Shell で実行して下さい。"
  exit 1
fi

if [ -z "${OCI_TENANCY:-}" ]; then
  echo "[ERROR] OCI_TENANCY が設定されていません。Oracle Cloud Shell で実行して下さい。"
  exit 1
fi
compartment_id=$OCI_TENANCY

# INSTANCE ==========
echo -n "確認中 "
find_out=$(mktemp)
find_log=$(mktemp)
# The backticks are JMESPath literals, not command substitution.
# shellcheck disable=SC2016
oci compute instance list --compartment-id "$compartment_id" \
  --display-name "$SERVER_NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`]|[0].id' --raw-output \
  > "$find_out" 2> "$find_log" &
wait_with_dots $! || true
instance_id=$(tr -d '\r\n' < "$find_out")
rm -f "$find_out" "$find_log"

if [ "$instance_id" == "null" ]; then instance_id="" ; fi

# Not an exit when nothing is found. A previous run can have removed the
# instance and then failed partway through the network, and that state needs a
# way back.
if [ -z "$instance_id" ]; then
  echo " 完了"
  cat <<EOS

削除できるサーバーが見つかりませんでした。
すでに削除済みか、まだ作成していません。
EOS
else
shape=$(oci compute instance get --instance-id "$instance_id" \
  --query 'data.shape' --raw-output 2> /dev/null || true)
echo " 完了"

cat <<EOS

-*-*-*-*- [削除の確認] -*-*-*-*-

サーバー '$SERVER_NAME' を削除します。
シェイプ : ${shape:-(取得できませんでした)}

ワールドのデータも一緒に消え、元に戻せません。
残したい場合は、先にメニューから backup を実行してください。

※ 設定を変えたいだけなら、削除せずに config から変更できます。
EOS

# A note rather than a warning. Re-obtaining an A1 took under a minute on a Pay
# As You Go account, which is what this repository assumes; on a free account it
# can genuinely take a while, and that is worth mentioning once without dressing
# it up as a danger.
case "$shape" in
  *A1*)
    cat <<EOS
※ Ampere A1 は、空きが無いと再作成に時間がかかることがあります。
EOS
    ;;
esac
echo ""

echo -n "本当に削除しますか? [y/N]: "
read -r delete_yn
if [ "$delete_yn" != "y" ]; then
  echo ""
  echo "中止しました。"
  echo ""
  exit 1
fi

# The boot volume outlives the instance unless this says otherwise, and it would
# keep taking up part of the 200GB Always Free block storage.
echo ""
echo -n "  サーバーを削除中 "
term_log=$(mktemp)
# Both streams into the log. Nothing is read back from this command, and the
# CLI does not always put its errors on stderr: discarding stdout once left a
# failure with no message at all.
# SUCCEEDED, not TERMINATED: terminate returns a work request, so the states it
# can be waited on are the request's own, not the instance's lifecycle.
oci compute instance terminate --instance-id "$instance_id" --force \
  --preserve-boot-volume false --wait-for-state SUCCEEDED \
  > "$term_log" 2>&1 &
term_status=0
wait_with_dots $! || term_status=$?

if [ "$term_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] サーバーの削除に失敗しました。(終了コード: $term_status)"
  echo "--------------------------------------------------------------------"
  # An empty log is itself worth saying out loud, rather than printing two
  # rules with nothing between them.
  if [ -s "$term_log" ]; then
    cat "$term_log"
  else
    echo "(出力がありませんでした)"
  fi
  echo "--------------------------------------------------------------------"
  cat <<EOS

インスタンスが残っているため、ネットワークは削除できません。
先にインスタンスの削除を成功させる必要があります。

下記で直接実行すると、詳しい原因が表示されます。

  oci compute instance terminate --instance-id $instance_id --force --preserve-boot-volume false

EOS
  rm -f "$term_log"
  exit 1
fi
rm -f "$term_log"
echo " 完了"
fi

# NETWORK ==========
# Kept by default. It costs nothing, and leaving it means a later create only
# has to place the instance, which is the part that can fail for hours.
cat <<EOS

-*-*-*-*- [ネットワークの扱い] -*-*-*-*-

VCN などのネットワーク設定が残っています。料金はかかりません。
残しておくと、次に作成するときはインスタンスを置くだけで済みます。

[1] 残す (推奨)
[2] 削除する
EOS
echo -n "Select (Default: 1): "
read -r net_num
if [ "$net_num" == "" ]; then net_num=1 ; fi
num_validation "$net_num" 2

if [ "$net_num" == "2" ]; then
  echo ""
  echo -n "  ネットワークを削除中 "
  net_log=$(mktemp)
  (
    set -e
    vcn_id=$(oci network vcn list --compartment-id "$compartment_id" \
      --display-name "$VCN_NAME" --query 'data[0].id' --raw-output 2> /dev/null || true)

    if [ -n "$vcn_id" ] && [ "$vcn_id" != "null" ]; then
      # Order matters: the VCN cannot go while anything still lives in it.
      subnet_id=$(oci network subnet list --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" --display-name "$SUBNET_NAME" \
        --query 'data[0].id' --raw-output 2> /dev/null || true)
      if [ -n "$subnet_id" ] && [ "$subnet_id" != "null" ]; then
        oci network subnet delete --subnet-id "$subnet_id" --force \
          --wait-for-state TERMINATED
      fi

      # The route rule pointing at the gateway has to go before the gateway can.
      # Deleting it outright is not an option: this is the VCN's default route
      # table, which only disappears with the VCN itself. Emptying the rules is
      # what releases the reference.
      rt_id=$(oci network vcn get --vcn-id "$vcn_id" \
        --query 'data."default-route-table-id"' --raw-output)
      oci network route-table update --rt-id "$rt_id" --force --route-rules '[]'

      igw_id=$(oci network internet-gateway list --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" --display-name "$IGW_NAME" \
        --query 'data[0].id' --raw-output 2> /dev/null || true)
      if [ -n "$igw_id" ] && [ "$igw_id" != "null" ]; then
        oci network internet-gateway delete --ig-id "$igw_id" --force \
          --wait-for-state TERMINATED
      fi

      oci network vcn delete --vcn-id "$vcn_id" --force \
        --wait-for-state TERMINATED
    fi
  # Everything lands in one log, including each command's stdout: the log is
  # only shown when something failed, so there is no noise to keep out of it.
  ) > "$net_log" 2>&1 &
  net_status=0
  wait_with_dots $! || net_status=$?

  if [ "$net_status" -ne 0 ]; then
    echo " 失敗"
    echo ""
    echo "[WARN] ネットワークの削除に失敗しました。サーバーは削除済みです。"
    echo "--------------------------------------------------------------------"
    cat "$net_log"
    echo "--------------------------------------------------------------------"
    rm -f "$net_log"
    exit 1
  fi
  rm -f "$net_log"
  echo " 完了"
fi

cat <<EOS

削除が完了しました。

EOS
