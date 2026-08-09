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
  # Always Free only applies in the home region, so which region this is
  # running against decides whether the instance below is free or billed.
  # shellcheck disable=SC2016
  printf 'home_region=%q\n' \
    "$(oci iam region-subscription list \
       --query 'data[?"is-home-region"]|[0]."region-name"' --raw-output)"
) > "$oci_info" 2> /dev/null &
wait_with_dots $! || true
availability_domain=""
home_region=""
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

# HOME REGION ==========
# The availability domain carries the region in it, as Uocm:AP-OSAKA-1-AD-1, so
# there is no second call to make for this.
current_region=$(echo "$availability_domain" | cut -d: -f2 | sed 's/-AD-[0-9]*$//' \
  | tr '[:upper:]' '[:lower:]')

if [ -n "$home_region" ] && [ "$current_region" != "$home_region" ]; then
  cat <<EOS

[WARN] 無料枠の対象外のリージョンです。

 いま接続中 : ${current_region}
 ホーム     : ${home_region}

Always Free はホームリージョンでしか適用されません。ここに作成すると、
同じ構成でも通常料金がかかります。2 OCPU / 12GB で月 25〜30 ドル程度です。

無料で作成するには、コンソール右上のリージョンを ${home_region} に切り替えて
から、Cloud Shell を開き直して下さい。

EOS
  echo -n "料金が発生することを理解した上で続けますか? [y/N]: "
  read -r region_yn
  if [ "$region_yn" != "y" ]; then
    echo ""
    echo "中止しました。"
    echo ""
    exit 1
  fi
fi

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
        --display-name "${budget_name}-alert"
    # One log for both streams. Nothing is read back, and the CLI does not
    # always put its errors on stderr.
    ) > "$budget_log" 2>&1 &
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
    rm -f "$budget_log"
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

# The Minecraft settings follow from the answer too. Outbound transfer is 10TB a
# month either way, so unlike the GCP build there is no reason to cut the view
# distance down to hold traffic: memory and CPU are the only limits left, and
# they differ by an order of magnitude between the two shapes.
shape_config_opt=()
if [ "$shape_num" == "1" ]; then
  SHAPE=$A1_SHAPE
  shape_label="${A1_SHAPE} (${A1_OCPUS} OCPU / ${A1_MEMORY_GB} GB)"
  shape_config_opt=(--shape-config "{\"ocpus\":${A1_OCPUS},\"memoryInGBs\":${A1_MEMORY_GB}}")
  arch_label="Ubuntu 24.04 (aarch64)"

  # 12 GB leaves plenty of room. The view distance stays under Minecraft's own
  # default of 32 because generating that far is work for two cores, not
  # because of the allowance.
  max_players=10
  view_distance=16
  memory_label="12GB"
  player_warn_over=20
  player_hint="メモリが 12GB あるため、10 人程度までは余裕があります。"
else
  SHAPE=$E2_SHAPE
  shape_label="${E2_SHAPE} (1 GB)"
  arch_label="Ubuntu 24.04 (x86_64)"

  # Same memory as the GCP e2-micro, so the same modest numbers apply.
  max_players=3
  view_distance=10
  memory_label="1GB"
  player_warn_over=4
  player_hint="メモリが 1GB しかないため、3 人程度が実用上の上限です。
より多くで遊ぶ場合は Ampere A1 を選んで下さい。"
fi

# Minecraft's own default. The GCP build cuts this to 5 minutes to stop idle
# connections eating a 1GB allowance; here there is nothing to protect.
player_idle_timeout=30

# SETTINGS ==========
# Asked before the instance is built rather than after. Placing an Ampere A1 can
# take a while, and answering everything up front means the rest runs unattended
# instead of stopping to ask once the machine is finally there.
#
# The view distance is not asked. Outbound transfer is 10TB a month, so the one
# reason the GCP build had to raise it with the user is gone, and the shape
# already decides a sensible value.
cat <<EOS

-*-*-*-*- [SERVER NAME (マインクラフトサーバー名を自由に決めて下さい)] -*-*-*-*-

EOS
echo -n "Server name (Default: ydak): "
read -r server_name

cat <<EOS

-*-*-*-*- [GAME MODE (ゲームモードを選択)] -*-*-*-*-

[1] survival (サバイバル)
[2] creative (クリエイティブ)
[3] adventure (アドベンチャー)
EOS
echo -n "Select game mode (Default: 1): "
read -r game_mode_num
if [ "$game_mode_num" == "" ]; then game_mode_num=1 ; fi
num_validation "$game_mode_num" 3
game_mode=${game_mode_list[$game_mode_num-1]}

cat <<EOS

-*-*-*-*- [DIFFICULTY (難易度を選択)] -*-*-*-*-

[1] peaceful (ピースフル)
[2] easy (イージー)
[3] normal (ノーマル)
[4] hard (ハード)
EOS
echo -n "Difficulty (Default: 3): "
read -r difficulty_num
if [ "$difficulty_num" == "" ]; then difficulty_num=3 ; fi
num_validation "$difficulty_num" 4
difficulty=${difficulty_list[$difficulty_num-1]}

cat <<EOS

-*-*-*-*- [CHEAT (チートを有効にするかどうか)] -*-*-*-*-

[1] ON (有効)
[2] OFF (無効)
EOS
echo -n "Allow cheat? (Default: 2): "
read -r allow_cheat_num
if [ "$allow_cheat_num" == "" ]; then allow_cheat_num=2 ; fi
num_validation "$allow_cheat_num" 2
allow_cheat=${allow_cheat_list[$allow_cheat_num-1]}

cat <<EOS

-*-*-*-*- [PERMISSION (サーバーに参加するユーザー全員の権限)] -*-*-*-*-

[1] visitor (訪問者)
[2] member (メンバー)
[3] operator (管理者)
EOS
echo -n "Default permission (Default: 2): "
read -r permission_num
if [ "$permission_num" == "" ]; then permission_num=2 ; fi
num_validation "$permission_num" 3
permission=${permission_num_list[$permission_num-1]}

cat <<EOS

-*-*-*-*- [MAX PLAYERS (同時に接続できる最大人数)] -*-*-*-*-

${player_hint}
EOS
echo -n "Max players (Default: ${max_players}): "
read -r input
if [ "$input" != "" ]; then
  positive_num_validation "$input"
  max_players=$input
fi
if [ "$max_players" -gt "$player_warn_over" ]; then
  echo "[WARN] ${max_players} 人はメモリ ${memory_label} に収まらない可能性があります。"
fi

cat <<EOS

-*-*-*-*- [SEED (シード値を入力。入力しない場合はランダム)] -*-*-*-*-

EOS
echo -n "Seed (Default: random): "
read -r seed
if [ "$seed" != "" ]; then
  if [[ ! ("$seed" =~ ^[-0-9][0-9]+$) ]]; then
    echo "[ERROR] シード値は数字で入力して下さい。"
    exit 1
  fi
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
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw_id\"}]"

  # This replaces the rule list rather than adding to it, so SSH has to be
  # restated here or the instance becomes unreachable.
  oci network security-list update --security-list-id "$sl_id" --force \
    --ingress-security-rules '[
      {"protocol":"6","source":"0.0.0.0/0","isStateless":false,
       "tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
      {"protocol":"17","source":"0.0.0.0/0","isStateless":false,
       "udpOptions":{"destinationPortRange":{"min":19132,"max":19132}}}
    ]'

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

# SETUP ==========
# Done over SSH rather than with cloud-init. user_data only runs on the first
# boot, so anything built that way could only be changed by replacing the
# instance, and giving up an Ampere A1 can mean not getting another one. This
# path also works on an instance that already exists, and can be re-run.
echo -n "  接続を待機中 "
# -T because without it a remote tool can decide it is talking to a terminal and
# start emitting cursor control, which lands in the middle of the progress dots.
ssh_opts=(-T -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)

(
  # RUNNING only means the machine is up; sshd accepts connections a little
  # after that.
  for _ in $(seq 1 60); do
    if ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" true 2> /dev/null; then
      exit 0
    fi
    sleep 5
  done
  exit 1
) &
ssh_status=0
wait_with_dots $! || ssh_status=$?

if [ "$ssh_status" -ne 0 ]; then
  echo " 失敗"
  cat <<EOS

[ERROR] サーバーに接続できませんでした。

  ssh -i ${ssh_key} ubuntu@${external_ip}

EOS
  exit 1
fi
echo " 完了"

# The settings live in this script, which systemd runs on every boot. Rendered
# here so that create and a later config change cannot drift apart.
run_script=$(mktemp)
render_startup_script "$run_script"
# Carried over base64 so that quotes and backslashes in the settings survive
# the trip through two shells.
run_b64=$(base64 -w0 < "$run_script")
rm -f "$run_script"

echo -n "  Minecraft を導入中 "
setup_log=$(mktemp)
# The here document is deliberately unquoted: run_b64 has to be substituted here
# so that the script arrives with the settings already in it. It is the only
# expansion in the block, and the systemd unit below carries no $ of its own.
# shellcheck disable=SC2087
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" "sudo bash -s" > "$setup_log" 2>&1 <<EOS &
set -e
export DEBIAN_FRONTEND=noninteractive
# Same reason as -T above: with a terminal type set, apt draws progress with
# escape sequences.
export TERM=dumb

apt-get update
apt-get install -y docker.io

# The image ships with iptables rules that drop everything except SSH, so
# opening the port in the security list alone leaves the server unreachable.
if ! iptables -C INPUT -p udp --dport 19132 -j ACCEPT 2> /dev/null; then
  iptables -I INPUT -p udp --dport 19132 -j ACCEPT
  if command -v netfilter-persistent > /dev/null; then
    netfilter-persistent save
  fi
fi

mkdir -p /opt/minecraft
echo '${run_b64}' | base64 -d > /opt/minecraft/run.sh
chmod +x /opt/minecraft/run.sh

# oneshot with RemainAfterExit: run.sh starts a detached container that has its
# own restart policy, so there is no foreground process for systemd to track.
cat > /etc/systemd/system/minecraft.service <<'UNIT'
[Unit]
Description=Minecraft Bedrock server
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/minecraft/run.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now minecraft.service
EOS
setup_status=0
wait_with_dots $! || setup_status=$?

if [ "$setup_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] Minecraft の導入に失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$setup_log"
  echo "--------------------------------------------------------------------"
  rm -f "$setup_log"
  exit 1
fi
rm -f "$setup_log"
echo " 完了"

echo ""
echo -n "マインクラフト起動中 "

# The Bedrock binary is downloaded on the first container start, so this waits
# on a download as well as a boot. The third argument is where the answered
# details are written, and without it the summary below has nothing to show.
mc_info=$(mktemp)
if ! wait_for_server "$external_ip" 900 "$mc_info"; then
  rm -f "$mc_info"
  cat <<EOS

[WARN] 15 分待ちましたが、サーバーが応答しませんでした。

導入は完了しています。起動に時間がかかっているだけかもしれません。
下記でログを確認できます。

  ssh -i ${ssh_key} ubuntu@${external_ip} 'sudo docker logs mc-server | tail -30'

EOS
  exit 1
fi

# shellcheck disable=SC1090
. "$mc_info"
rm -f "$mc_info"

cat <<EOS

サーバーの作成が完了しました。

################################################################################
${external_ip}
################################################################################

上記の IP アドレスとポート 19132 で接続してください。

--------------------------------------------------------------------
 サーバー情報
--------------------------------------------------------------------
 IP アドレス  : ${external_ip}
 ポート       : 19132
 エディション : 統合版 (Bedrock)
 バージョン   : ${MC_VERSION:-(取得できませんでした)}
 インスタンス : ${SERVER_NAME}
 シェイプ     : ${shape_label}
 リージョン   : $(echo "$availability_domain" | cut -d: -f2)

--------------------------------------------------------------------
 注意
--------------------------------------------------------------------
 ・許可リストは無効です。この IP を知っていれば誰でも参加できます。
 ・サーバーを停止・起動すると IP アドレスが変わります。
 ・下り通信は 10TB/月 まで無料です。

管理用のコマンドです。

  ssh -i ${ssh_key} ubuntu@${external_ip}
  sudo docker logs mc-server | tail -30

EOS
