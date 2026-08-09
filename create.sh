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

# Always Free covers 2 OCPUs and 12 GB of Ampere A1. The trial that runs for the
# first 30 days allows far more, so the numbers are pinned here rather than
# taken from whatever the quota currently permits: anything above the Always
# Free line starts costing money once the trial ends.
SHAPE=VM.Standard.A1.Flex
OCPUS=2
MEMORY_GB=12

# Retry interval when the region has no free host to place the instance on.
RETRY_SECONDS=60

echo ""
echo "==================== Minecraft サーバーの作成 ===================="
echo ""

for cmd in oci ssh-keygen; do
  if ! command -v "$cmd" > /dev/null; then
    echo "[ERROR] '$cmd' が見つかりません。Oracle Cloud Shell で実行して下さい。"
    exit 1
  fi
done

# TENANCY ==========
# Cloud Shell exports OCI_TENANCY and authenticates the CLI for us, so there is
# nothing to configure. The tenancy OCID doubles as the root compartment.
if [ -z "${OCI_TENANCY:-}" ]; then
  echo "[ERROR] OCI_TENANCY が設定されていません。Oracle Cloud Shell で実行して下さい。"
  exit 1
fi
compartment_id=$OCI_TENANCY

echo -n "確認中 "
oci_info=$(mktemp)
(
  ad=$(oci iam availability-domain list --query 'data[0].name' --raw-output)
  printf 'availability_domain=%q\n' "$ad"
) > "$oci_info" 2> /dev/null &
wait_with_dots $! || true
availability_domain=""
# shellcheck disable=SC1090
. "$oci_info"
rm -f "$oci_info"

if [ -z "$availability_domain" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] 可用性ドメインを取得できませんでした。"
  echo "        Oracle Cloud Shell で実行しているか確認して下さい。"
  exit 1
fi
echo " 完了"

# EXISTING SERVER ==========
# Ampere A1 capacity is scarce enough that giving one up can mean not getting
# another, so an existing instance is reported rather than replaced.
# A stopped instance still holds the capacity and the name, so everything but a
# terminated one counts as existing.
#
# The backticks below are JMESPath's literal syntax, not a command substitution,
# so the query has to stay in single quotes.
# shellcheck disable=SC2016
existing=$(oci compute instance list --compartment-id "$compartment_id" \
  --display-name "$SERVER_NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`]|[0].id' --raw-output 2> /dev/null || true)

if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  echo ""
  echo "[ERROR] すでに '$SERVER_NAME' が存在します。"
  echo "        作成を中止しました。削除するとインスタンス枠を手放すことになります。"
  echo ""
  exit 1
fi

# NETWORK ==========
# OCI does not hand a new tenancy a usable network the way GCP does: a VCN, an
# internet gateway, a route to it and an ingress rule all have to be built
# before an instance can be reached. Each step checks for what it needs first,
# so the script can be re-run after a failure without piling up duplicates.
echo -n "  ネットワークを準備中 "
# Two files, not one: --wait-for-state narrates its progress on stderr, and one
# of those lines is "Waiting until the resource has entered state:
# ('AVAILABLE',)". Sourcing a file with that in it is a bash syntax error, so
# the result is written somewhere the log cannot reach.
net_log=$(mktemp)
net_out=$(mktemp)
(
  set -e

  vcn_id=$(oci network vcn list --compartment-id "$compartment_id" \
    --display-name "$VCN_NAME" --query 'data[0].id' --raw-output 2> /dev/null || true)

  if [ -z "$vcn_id" ] || [ "$vcn_id" == "null" ]; then
    vcn_id=$(oci network vcn create --compartment-id "$compartment_id" \
      --display-name "$VCN_NAME" --cidr-blocks '["10.0.0.0/16"]' \
      --dns-label minecraft --wait-for-state AVAILABLE \
      --query 'data.id' --raw-output)
  fi

  igw_id=$(oci network internet-gateway list --compartment-id "$compartment_id" \
    --vcn-id "$vcn_id" --display-name "$IGW_NAME" --query 'data[0].id' --raw-output 2> /dev/null || true)

  if [ -z "$igw_id" ] || [ "$igw_id" == "null" ]; then
    igw_id=$(oci network internet-gateway create --compartment-id "$compartment_id" \
      --vcn-id "$vcn_id" --display-name "$IGW_NAME" --is-enabled true \
      --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  fi

  # The VCN ships with a route table and a security list already attached to it.
  # Editing those is simpler than creating replacements and repointing the
  # subnet at them.
  rt_id=$(oci network vcn get --vcn-id "$vcn_id" --query 'data."default-route-table-id"' --raw-output)
  sl_id=$(oci network vcn get --vcn-id "$vcn_id" --query 'data."default-security-list-id"' --raw-output)

  oci network route-table update --rt-id "$rt_id" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw_id\"}]" \
    > /dev/null

  # This replaces the rule list rather than adding to it, so SSH has to be
  # restated here or the instance becomes unreachable.
  oci network security-list update --security-list-id "$sl_id" --force \
    --ingress-security-rules '[
      {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
       "tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
      {"protocol":"17","source":"0.0.0.0/0","isStateless":false,
       "udpOptions":{"destinationPortRange":{"min":19132,"max":19132}}}
    ]' > /dev/null

  subnet_id=$(oci network subnet list --compartment-id "$compartment_id" \
    --vcn-id "$vcn_id" --display-name "$SUBNET_NAME" --query 'data[0].id' --raw-output 2> /dev/null || true)

  if [ -z "$subnet_id" ] || [ "$subnet_id" == "null" ]; then
    subnet_id=$(oci network subnet create --compartment-id "$compartment_id" \
      --vcn-id "$vcn_id" --display-name "$SUBNET_NAME" --cidr-block 10.0.0.0/24 \
      --dns-label mc --wait-for-state AVAILABLE --query 'data.id' --raw-output)
  fi

  printf 'subnet_id=%q\n' "$subnet_id" > "$net_out"
) > "$net_log" 2>&1 &
wait_with_dots $! || true

subnet_id=""
# shellcheck disable=SC1090
. "$net_out"

if [ -z "$subnet_id" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] ネットワークの準備に失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$net_log"
  echo "--------------------------------------------------------------------"
  rm -f "$net_log" "$net_out"
  exit 1
fi
rm -f "$net_log" "$net_out"
echo " 完了"

# IMAGE ==========
# Asked for by shape so that only images actually bootable on Ampere come back;
# the same query on x86 would return the amd64 builds instead.
echo -n "  イメージを検索中 "
image_out=$(mktemp)
image_log=$(mktemp)
oci compute image list --compartment-id "$compartment_id" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape "$SHAPE" --sort-by TIMECREATED \
  --query 'data[0].id' --raw-output > "$image_out" 2> "$image_log" &
wait_with_dots $! || true
image_id=$(tr -d '\r\n' < "$image_out")

if [ -z "$image_id" ] || [ "$image_id" == "null" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] Ubuntu 24.04 のイメージが見つかりませんでした。"
  echo "--------------------------------------------------------------------"
  cat "$image_log"
  echo "--------------------------------------------------------------------"
  rm -f "$image_out" "$image_log"
  exit 1
fi
rm -f "$image_out" "$image_log"
echo " 完了"

# SSH KEY ==========
# Cloud Shell keeps the home directory between sessions, so a key made here is
# still around on the next run.
ssh_key=~/.ssh/id_rsa
if [ ! -f "${ssh_key}.pub" ]; then
  echo -n "  SSH 鍵を作成中 "
  ssh-keygen -t rsa -b 2048 -f "$ssh_key" -N "" -q &
  wait_with_dots $! || true
  echo " 完了"
fi

# LAUNCH ==========
cat <<EOS

-*-*-*-*- [インスタンスの作成] -*-*-*-*-

シェイプ : ${SHAPE} (${OCPUS} OCPU / ${MEMORY_GB} GB)
イメージ : Ubuntu 24.04 (aarch64)

無料枠の Ampere A1 は空きが出るまで作成できないことがあります。
その場合は ${RETRY_SECONDS} 秒ごとに自動で再試行します。
待っている間、この画面は開いたままにしてください。
中断する場合は Ctrl+C を押してください。後で実行し直せます。

EOS

echo -n "作成中 "
attempt=0
started=$SECONDS
instance_id=""
# Same split as the network step: --wait-for-state writes its progress to
# stderr, so only stdout may be read back as the instance id.
launch_out=$(mktemp)
launch_log=$(mktemp)

while true; do
  attempt=$((attempt + 1))

  oci compute instance launch \
    --compartment-id "$compartment_id" \
    --availability-domain "$availability_domain" \
    --subnet-id "$subnet_id" \
    --image-id "$image_id" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}" \
    --display-name "$SERVER_NAME" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "${ssh_key}.pub" \
    --wait-for-state RUNNING \
    --query 'data.id' --raw-output > "$launch_out" 2> "$launch_log" &
  launch_status=0
  wait_with_dots $! || launch_status=$?

  if [ "$launch_status" -eq 0 ]; then
    instance_id=$(tr -d '\r\n' < "$launch_out")
    break
  fi

  # Anything other than a placement failure will not clear by waiting, so it is
  # reported straight away rather than retried for hours.
  if ! grep -qi 'out of host capacity\|outofcapacity' "$launch_log"; then
    echo " 失敗"
    echo ""
    echo "[ERROR] インスタンスの作成に失敗しました。"
    echo "--------------------------------------------------------------------"
    cat "$launch_log"
    echo "--------------------------------------------------------------------"
    rm -f "$launch_out" "$launch_log"
    exit 1
  fi

  echo ""
  printf '  空きがないため待機します (%d 回目, 経過 %d 分)\n' "$attempt" "$(( (SECONDS - started) / 60 ))"
  echo -n "  再試行まで "
  sleep_with_dots "$RETRY_SECONDS"
  echo ""
  echo -n "作成中 "
done
rm -f "$launch_out" "$launch_log"
echo " 完了"

# PUBLIC IP ==========
echo -n "  IP アドレスを取得中 "
ip_out=$(mktemp)
ip_log=$(mktemp)
(
  vnic_id=$(oci compute instance list-vnics --instance-id "$instance_id" \
    --query 'data[0].id' --raw-output)
  oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output
) > "$ip_out" 2> "$ip_log" &
wait_with_dots $! || true
external_ip=$(tr -d '\r\n' < "$ip_out")

if [ -z "$external_ip" ] || [ "$external_ip" == "null" ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] 公開 IP アドレスを取得できませんでした。"
  echo "--------------------------------------------------------------------"
  cat "$ip_log"
  echo "--------------------------------------------------------------------"
  rm -f "$ip_out" "$ip_log"
  exit 1
fi
rm -f "$ip_out" "$ip_log"
echo " 完了"

cat <<EOS

インスタンスの作成が完了しました。

################################################################################
${external_ip}
################################################################################

 インスタンス : ${SERVER_NAME}
 シェイプ     : ${SHAPE} (${OCPUS} OCPU / ${MEMORY_GB} GB)
 リージョン   : $(echo "$availability_domain" | cut -d: -f2)

接続を確認する場合は下記を実行してください。

  ssh -i ${ssh_key} ubuntu@${external_ip}

※ Minecraft はまだ入っていません。ここまでが第 1 段階です。

EOS
