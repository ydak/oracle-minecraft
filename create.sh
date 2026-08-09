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

# Always Free covers 2 OCPUs and 12 GB of Ampere A1, and separately two of the
# AMD micro instances. The trial that runs for the first 30 days allows far
# more, so the numbers are pinned here rather than taken from whatever the quota
# currently permits: anything above the Always Free line starts costing money
# once the trial ends.
A1_SHAPE=VM.Standard.A1.Flex
A1_OCPUS=2
A1_MEMORY_GB=12

# Not a flexible shape, so it takes no shape configuration at all.
E2_SHAPE=VM.Standard.E2.1.Micro

# Retry interval when the region has no free host to place the instance on.
RETRY_SECONDS=90

# Launching is rate limited per user, and the limit is reached easily: a second
# attempt was enough to be told "Too many requests". That answer clears by
# waiting, so it is backed off rather than treated as a failure, doubling up to
# this ceiling.
MAX_RETRY_SECONDS=1800

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

# BUDGET ==========
# Set up before anything is built, so the alarm is already in place by the time
# there is something that could cost money.
#
# On a free account nothing outside Always Free can be created at all, which is
# the real safeguard. Upgrading to Pay As You Go removes that wall in exchange
# for Ampere capacity being obtainable, and a budget is what replaces it.
#
# It only notifies. Nothing here stops a charge from happening.
budget_name=minecraft-budget

existing_budget=$(oci budgets budget list --compartment-id "$compartment_id" \
  --display-name "$budget_name" --query 'data[0].id' --raw-output 2> /dev/null || true)

if [ -n "$existing_budget" ] && [ "$existing_budget" != "null" ]; then
  echo "  予算アラートは設定済みです"
else
  # The console account's own address is the obvious default, but the variable
  # holding it is not documented, so its absence has to be survivable.
  default_email=""
  if [ -n "${OCI_CS_USER_OCID:-}" ]; then
    default_email=$(oci iam user get --user-id "$OCI_CS_USER_OCID" \
      --query 'data.email' --raw-output 2> /dev/null || true)
    if [ "$default_email" == "null" ]; then default_email="" ; fi
  fi

  cat <<EOS

-*-*-*-*- [BUDGET (予算アラート)] -*-*-*-*-

無料枠を超える操作が起きた場合に、メールで通知します。
1 ドルを超えた時点で届くので、少額のうちに気付けます。

[WARN] 通知するだけで、課金を止めるものではありません。

空欄のまま Enter を押すと作成しません。
EOS
  echo -n "通知先メールアドレス${default_email:+ (Default: ${default_email})}: "
  read -r budget_email
  if [ "$budget_email" == "" ]; then budget_email=$default_email ; fi

  if [ -z "$budget_email" ]; then
    echo "  予算アラートは作成しません"
  else
    echo -n "  予算アラートを作成中 "
    budget_out=$(mktemp)
    budget_log=$(mktemp)
    (
      set -e
      budget_id=$(oci budgets budget create --compartment-id "$compartment_id" \
        --target-type COMPARTMENT --targets "[\"$compartment_id\"]" \
        --amount 1 --reset-period MONTHLY --display-name "$budget_name" \
        --query 'data.id' --raw-output)

      oci budgets alert-rule create --budget-id "$budget_id" \
        --type ACTUAL --threshold 100 --threshold-type PERCENTAGE \
        --recipients "$budget_email" \
        --display-name "${budget_name}-alert" > /dev/null
    ) > "$budget_out" 2> "$budget_log" &
    budget_status=0
    wait_with_dots $! || budget_status=$?

    if [ "$budget_status" -eq 0 ]; then
      echo " 完了"
    else
      # Not fatal. Creating the server is what was asked for, and failing to
      # arm a notification is not a reason to refuse to do it.
      echo " 失敗"
      echo ""
      echo "[WARN] 予算アラートを作成できませんでした。処理は続行します。"
      echo "       コンソールの Billing → Budgets から手動で設定できます。"
      echo "--------------------------------------------------------------------"
      cat "$budget_log"
      echo "--------------------------------------------------------------------"
      echo ""
    fi
    rm -f "$budget_out" "$budget_log"
  fi
fi

# SHAPE ==========
# Asked before anything is built, because the answer decides which image to look
# for: the A1 is Arm and the micro is x86.
cat <<EOS

-*-*-*-*- [SHAPE (サーバーの性能)] -*-*-*-*-

[1] Ampere A1 (2 OCPU / 12GB)
    無料枠で最も高性能ですが、空きが出るまで作成できません。
    数時間から数日かかることがあります。

[2] AMD E2.1.Micro (1GB)
    すぐに作成できます。無料枠に 2 台含まれています。
    メモリは GCP の e2-micro と同じです。

どちらを選んでも、下り通信 10TB/月 は変わりません。
EOS
echo -n "Select shape (Default: 2): "
read -r shape_num
if [ "$shape_num" == "" ]; then shape_num=2 ; fi
num_validation "$shape_num" 2

shape_config_opt=()
if [ "$shape_num" == "1" ]; then
  SHAPE=$A1_SHAPE
  shape_label="${A1_SHAPE} (${A1_OCPUS} OCPU / ${A1_MEMORY_GB} GB)"
  shape_config_opt=(--shape-config "{\"ocpus\":${A1_OCPUS},\"memoryInGBs\":${A1_MEMORY_GB}}")
  arch_label="Ubuntu 24.04 (aarch64)"
else
  SHAPE=$E2_SHAPE
  shape_label="${E2_SHAPE} (1 GB)"
  arch_label="Ubuntu 24.04 (x86_64)"
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

シェイプ : ${shape_label}
イメージ : ${arch_label}

空きが無い場合は ${RETRY_SECONDS} 秒ごとに自動で再試行します。
待っている間、この画面は開いたままにしてください。
中断する場合は Ctrl+C を押してください。後で実行し直せます。

[WARN] Cloud Shell は 60 分で切断されます。ドットの出力は操作とみなされません。
       切断されたら実行し直してください。作成済みのネットワークは再利用されます。

EOS

# The CLI retries some failures on its own, five times by default, which turns
# one attempt here into several calls to the API and reaches the rate limit
# sooner. A single failed launch taking over a minute is what gave it away.
#
# Two ways of switching that off, because neither is guaranteed to be present:
# --max-retries is asked for rather than assumed, since --no-retry turned out
# not to exist on this subcommand, and the environment variable is set
# regardless because an unrecognised one is ignored rather than fatal.
no_retry_opt=()
if oci compute instance launch --help 2> /dev/null | grep -q -- '--max-retries'; then
  no_retry_opt=(--max-retries 0)
fi

echo -n "作成中 "
attempt=0
started=$SECONDS
wait_seconds=$RETRY_SECONDS
clear_streak=0
instance_id=""
# Same split as the network step: --wait-for-state writes its progress to
# stderr, so only stdout may be read back as the instance id.
launch_out=$(mktemp)
launch_log=$(mktemp)

while true; do
  attempt=$((attempt + 1))

  OCI_SDK_DEFAULT_RETRY_ENABLED=false \
  oci compute instance launch \
    --compartment-id "$compartment_id" \
    --availability-domain "$availability_domain" \
    --subnet-id "$subnet_id" \
    --image-id "$image_id" \
    --shape "$SHAPE" "${shape_config_opt[@]}" \
    --display-name "$SERVER_NAME" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "${ssh_key}.pub" \
    --wait-for-state RUNNING "${no_retry_opt[@]}" \
    --query 'data.id' --raw-output > "$launch_out" 2> "$launch_log" &
  launch_status=0
  wait_with_dots $! || launch_status=$?

  if [ "$launch_status" -eq 0 ]; then
    instance_id=$(tr -d '\r\n' < "$launch_out")
    break
  fi

  # Two answers are worth waiting on: no host free to place the instance, and
  # being told to slow down. Anything else will not clear by waiting, so it is
  # reported straight away rather than retried for hours.
  if grep -qi 'out of host capacity\|outofcapacity' "$launch_log"; then
    reason="空きがないため"
    # Being told there is no capacity means the request itself was accepted, so
    # the rate limit is not currently a problem. Ease the interval back down
    # after a few of those in a row: a single early refusal, often left over
    # from a previous run, should not hold the pace back for the whole session.
    clear_streak=$((clear_streak + 1))
    if [ "$clear_streak" -ge 3 ] && [ "$wait_seconds" -gt "$RETRY_SECONDS" ]; then
      wait_seconds=$((wait_seconds / 2))
      if [ "$wait_seconds" -lt "$RETRY_SECONDS" ]; then
        wait_seconds=$RETRY_SECONDS
      fi
      clear_streak=0
    fi
  elif grep -qi 'toomanyrequests\|"status": *429' "$launch_log"; then
    reason="リクエストの間隔が短すぎるため"
    clear_streak=0
    wait_seconds=$((wait_seconds * 2))
    if [ "$wait_seconds" -gt "$MAX_RETRY_SECONDS" ]; then
      wait_seconds=$MAX_RETRY_SECONDS
    fi
  else
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
  printf '  %s待機します (%d 回目, 経過 %d 分, 次は %d 分後)\n' \
    "$reason" "$attempt" "$(( (SECONDS - started) / 60 ))" "$(( wait_seconds / 60 ))"
  echo -n "  再試行待機中 "
  sleep_with_dots "$wait_seconds"
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
 シェイプ     : ${shape_label}
 リージョン   : $(echo "$availability_domain" | cut -d: -f2)

接続を確認する場合は下記を実行してください。

  ssh -i ${ssh_key} ubuntu@${external_ip}

※ Minecraft はまだ入っていません。ここまでが第 1 段階です。

EOS
