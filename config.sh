#!/usr/bin/env bash
set -e

script_dir=$(dirname "${0}")
# shellcheck source=functions.sh
. "$script_dir/functions.sh"
# shellcheck source=const.sh
. "$script_dir/const.sh"

SERVER_NAME=minecraft
ssh_key=~/.ssh/id_rsa
ssh_opts=(-T -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)

echo ""
echo "==================== Minecraft の設定変更 ===================="
echo ""

for cmd in oci ssh; do
  if ! command -v "$cmd" > /dev/null; then
    echo "[ERROR] '$cmd' が見つかりません。Oracle Cloud Shell で実行して下さい。"
    exit 1
  fi
done

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
  # The id itself is only needed in here: everything after this talks to the
  # machine over SSH.
  printf 'shape=%q\n' \
    "$(oci compute instance get --instance-id "$id" --query 'data.shape' --raw-output)"
  vnic_id=$(oci compute instance list-vnics --instance-id "$id" \
    --query 'data[0].id' --raw-output)
  printf 'external_ip=%q\n' \
    "$(oci network vnic get --vnic-id "$vnic_id" --query 'data."public-ip"' --raw-output)"
) > "$find_out" 2> "$find_log" &
wait_with_dots $! || true

shape=""
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

# The advice on how many players fit depends on the machine, and the two shapes
# differ by an order of magnitude in memory.
case "$shape" in
  *A1*)
    memory_label="12GB"
    player_warn_over=20
    player_hint="メモリが 12GB あるため、10 人程度までは余裕があります。"
    ;;
  *)
    memory_label="1GB"
    player_warn_over=4
    player_hint="メモリが 1GB しかないため、3 人程度が実用上の上限です。
より多くで遊ぶ場合は Ampere A1 で作り直して下さい。"
    ;;
esac

# CURRENT SETTINGS ==========
# Taken from the container's environment rather than server.properties: those
# variables are what the next restart will write into the file, so they are the
# values actually in force.
echo -n "  現在の設定を読み込み中 "
env_out=$(mktemp)
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo docker inspect mc-server --format '{{range .Config.Env}}{{println .}}{{end}}'" \
  > "$env_out" 2> /dev/null &
wait_with_dots $! || true

current_of() {
  grep -E "^$1=" "$env_out" 2> /dev/null | head -1 | cut -d= -f2- | tr -d '\r'
}

server_name=$(current_of SERVER_NAME)
game_mode=$(current_of GAMEMODE)
difficulty=$(current_of DIFFICULTY)
allow_cheat=$(current_of ALLOW_CHEATS)
permission=$(current_of DEFAULT_PLAYER_PERMISSION_LEVEL)
max_players=$(current_of MAX_PLAYERS)
view_distance=$(current_of VIEW_DISTANCE)
# The world already exists, so the seed cannot be changed. Carried through
# unaltered so that regenerating the run script does not drop it.
seed=$(current_of LEVEL_SEED)

force_gamemode=$(current_of FORCE_GAMEMODE)
allow_list=$(current_of ALLOW_LIST)
allow_list_users=$(current_of ALLOW_LIST_USERS)
tick_distance=$(current_of TICK_DISTANCE)
player_idle_timeout=$(current_of PLAYER_IDLE_TIMEOUT)
chat_restriction=$(current_of CHAT_RESTRICTION)
disable_player_interaction=$(current_of DISABLE_PLAYER_INTERACTION)
texturepack_required=$(current_of TEXTUREPACK_REQUIRED)
disable_custom_skins=$(current_of DISABLE_CUSTOM_SKINS)
rm -f "$env_out"

# Minecraft's own defaults, for a server built before a setting was added: the
# listing has to show what is actually in force, not what a new build would use.
force_gamemode=${force_gamemode:-false}
allow_list=${allow_list:-false}
tick_distance=${tick_distance:-4}
player_idle_timeout=${player_idle_timeout:-30}
chat_restriction=${chat_restriction:-None}
disable_player_interaction=${disable_player_interaction:-false}
texturepack_required=${texturepack_required:-false}
disable_custom_skins=${disable_custom_skins:-false}
view_distance=${view_distance:-32}

if [ -z "$server_name" ]; then
  echo " 失敗"
  cat <<EOS

[ERROR] 現在の設定を読み込めませんでした。
        サーバーが起動しているか確認して下さい。

  ssh -i ${ssh_key} ubuntu@${external_ip} 'sudo docker ps'

EOS
  exit 1
fi
echo " 完了"

# Returns the 1-based position of a value in the remaining arguments, so the
# current setting can be offered as the menu default.
index_of() {
  local needle=$1
  shift
  local i=1
  local v
  for v in "$@"; do
    if [ "$v" == "$needle" ]; then
      echo "$i"
      return
    fi
    i=$((i + 1))
  done
  echo 1
}

# The server stores these as true/false, but every menu below is phrased as
# ON/OFF, so the listings are put in the same terms as the questions.
on_off() {
  if [ "$1" == "true" ]; then echo "ON" ; else echo "OFF" ; fi
}

# The before and after listings show the same fields. Printing them from one
# place keeps a newly added setting from appearing in only one of the two,
# which would hide it at exactly the moment the user is checking their work.
print_settings() {
  cat <<EOS
サーバー名   : ${server_name}
ゲームモード : ${game_mode}
難易度       : ${difficulty}
チート       : $(on_off "$allow_cheat")
参加者の権限 : ${permission}
最大人数     : ${max_players}
描画距離     : ${view_distance}

[詳細設定]
シミュレーション距離   : ${tick_distance}
放置切断の分数         : ${player_idle_timeout}
ゲームモードの強制     : $(on_off "$force_gamemode")
許可リスト             : $(on_off "$allow_list")$(if [ "$allow_list" == "true" ]; then echo " (${allow_list_users:-未登録})" ; fi)
チャット制限           : ${chat_restriction}
プレイヤー干渉の無効化 : $(on_off "$disable_player_interaction")
テクスチャパックの強制 : $(on_off "$texturepack_required")
自作スキンの禁止       : $(on_off "$disable_custom_skins")
EOS
}

cat <<EOS

-*-*-*-*- [現在の設定] -*-*-*-*-

インスタンス : ${SERVER_NAME} (${shape})
$(print_settings)

変更したい項目だけ入力してください。
そのまま Enter を押すと現在の値を保ちます。
EOS

# SERVER NAME ==========
cat <<EOS

-*-*-*-*- [SERVER NAME (マインクラフトサーバー名)] -*-*-*-*-

EOS
echo -n "Server name (Default: ${server_name}): "
read -r input
if [ "$input" != "" ]; then server_name=$input ; fi

# GAME MODE ==========
game_mode_default=$(index_of "$game_mode" "${game_mode_list[@]}")
cat <<EOS

-*-*-*-*- [GAME MODE (ゲームモードを選択)] -*-*-*-*-

[1] survival (サバイバル)
[2] creative (クリエイティブ)
[3] adventure (アドベンチャー)
EOS
echo -n "Select game mode (Default: ${game_mode_default}): "
read -r input
if [ "$input" == "" ]; then input=$game_mode_default ; fi
num_validation "$input" 3
game_mode=${game_mode_list[$input-1]}

# DIFFICULTY ==========
difficulty_default=$(index_of "$difficulty" "${difficulty_list[@]}")
cat <<EOS

-*-*-*-*- [DIFFICULTY (難易度を選択)] -*-*-*-*-

[1] peaceful (ピースフル)
[2] easy (イージー)
[3] normal (ノーマル)
[4] hard (ハード)
EOS
echo -n "Difficulty (Default: ${difficulty_default}): "
read -r input
if [ "$input" == "" ]; then input=$difficulty_default ; fi
num_validation "$input" 4
difficulty=${difficulty_list[$input-1]}

# CHEAT ==========
allow_cheat_default=$(index_of "$allow_cheat" "${allow_cheat_list[@]}")
cat <<EOS

-*-*-*-*- [CHEAT (チートを有効にするかどうか)] -*-*-*-*-

[1] ON (有効)
[2] OFF (無効)
EOS
echo -n "Allow cheat? (Default: ${allow_cheat_default}): "
read -r input
if [ "$input" == "" ]; then input=$allow_cheat_default ; fi
num_validation "$input" 2
allow_cheat=${allow_cheat_list[$input-1]}

# PERMISSION ==========
permission_default=$(index_of "$permission" "${permission_num_list[@]}")
cat <<EOS

-*-*-*-*- [PERMISSION (サーバーに参加するユーザー全員の権限)] -*-*-*-*-

[1] visitor (訪問者)
[2] member (メンバー)
[3] operator (管理者)
EOS
echo -n "Default permission (Default: ${permission_default}): "
read -r input
if [ "$input" == "" ]; then input=$permission_default ; fi
num_validation "$input" 3
permission=${permission_num_list[$input-1]}

# MAX PLAYERS ==========
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

# VIEW DISTANCE ==========
cat <<EOS

-*-*-*-*- [VIEW DISTANCE (描画距離。単位はチャンク)] -*-*-*-*-

大きくすると遠くまで見えますが、メモリと CPU を多く使います。
Minecraft の既定は 32 です。下り通信は 10TB/月 あるため、
通信量のために抑える必要はありません。指定できるのは 5 以上です。
EOS
echo -n "View distance (Default: ${view_distance}): "
read -r input
if [ "$input" != "" ]; then
  positive_num_validation "$input"
  if [ "$input" -lt 5 ]; then
    echo "[ERROR] 5 以上を指定して下さい。"
    exit 1
  fi
  view_distance=$input
fi

# ADVANCED ==========
# Kept behind a prompt so the common case stays short. Everything here is
# preserved untouched when skipped.
cat <<EOS

-*-*-*-*- [詳細設定] -*-*-*-*-

ゲームモードの強制、許可リスト、放置切断、チャット制限などを変更できます。
必要なければ、そのまま Enter で飛ばせます。
EOS
echo -n "詳細設定も変更しますか? [y/N]: "
read -r advanced_yn

if [ "$advanced_yn" == "y" ]; then
  # FORCE GAMEMODE ==========
  force_gamemode_default=$(index_of "$force_gamemode" "${bool_list[@]}")
  cat <<EOS

-*-*-*-*- [FORCE GAMEMODE (ゲームモードの強制)] -*-*-*-*-

ON にすると、参加者が個別に設定していても、上のゲームモードを強制します。
[1] ON (強制する)
[2] OFF (各自の設定を尊重する)
EOS
  echo -n "Force gamemode? (Default: ${force_gamemode_default}): "
  read -r input
  if [ "$input" == "" ]; then input=$force_gamemode_default ; fi
  num_validation "$input" 2
  force_gamemode=${bool_list[$input-1]}

  # ALLOW LIST ==========
  allow_list_default=$(index_of "$allow_list" "${bool_list[@]}")
  cat <<EOS

-*-*-*-*- [ALLOW LIST (許可リスト)] -*-*-*-*-

ON にすると、登録した人しか参加できなくなります。
IP アドレスが漏れても他人が入れないため、安全性が上がります。
[1] ON (登録した人だけ参加できる)
[2] OFF (IP を知っていれば誰でも参加できる)
EOS
  echo -n "Allow list? (Default: ${allow_list_default}): "
  read -r input
  if [ "$input" == "" ]; then input=$allow_list_default ; fi
  num_validation "$input" 2
  allow_list=${bool_list[$input-1]}

  if [ "$allow_list" == "true" ]; then
    cat <<EOS

-*-*-*-*- [ALLOW LIST USERS (参加を許可する人)] -*-*-*-*-

参加する人のゲーマータグを、カンマ区切りで入力してください。
自分を含め、参加する人を全員書いてください。ここに無い人は入れません。

  例: AbroadOdin46554, Steve2024

区切りはカンマだけです。空白では区切りません。
ゲーマータグ自体に空白が含まれる場合は、そのまま書いてください。
表示されているとおりに、大文字と小文字も含めて正確に入力してください。
ゲーマータグは Minecraft のフレンド一覧か、Xbox のプロフィールで確認できます。
EOS
    if [ -n "$allow_list_users" ]; then
      echo "現在の登録: ${allow_list_users}"
    fi
    echo -n "Allowed players: "
    read -r input
    if [ "$input" != "" ]; then
      if ! input=$(normalize_allow_list_users "$input"); then
        cat <<EOS

[ERROR] ゲーマータグだけの書き方と、XUID を付けた書き方が混ざっています。
        どちらかに統一してください。

  ゲーマータグだけ : AbroadOdin46554, Steve2024
  XUID を付ける    : AbroadOdin46554:2535453759792258, Steve2024:2535465783925712

EOS
        exit 1
      fi
      allow_list_users=$input
    fi

    if [ -z "$allow_list_users" ]; then
      cat <<EOS

[ERROR] 一人も登録されていないため、このままでは誰も参加できなくなります。
        参加する人のゲーマータグを入力してください。

EOS
      exit 1
    fi
  else
    # The image forces the allow list back on whenever this is non-empty, so it
    # has to be cleared for 'off' to take effect. The world keeps its own copy
    # of the list, but it is rewritten from this on every start anyway.
    allow_list_users=""
  fi

  # TICK DISTANCE ==========
  cat <<EOS

-*-*-*-*- [TICK DISTANCE (シミュレーション距離。単位はチャンク)] -*-*-*-*-

プレイヤーから何チャンク先まで世界を動かすかです。
大きくすると遠くの装置が動きますが、負荷が上がります。
既定の 4 が最小値です。上げると CPU の負荷が増えます。
統合版のサーバーは box64 による変換を挟んで動いているため、
コア数ほどの余裕はありません。上げるなら 6 前後から試して下さい。
接続中のプレイヤーから離れた装置を動かしたい場合に使います。
指定できるのは 4 から 12 です。
EOS
  echo -n "Tick distance (Default: ${tick_distance}): "
  read -r input
  if [ "$input" != "" ]; then
    positive_num_validation "$input"
    if [ "$input" -lt 4 ] || [ "$input" -gt 12 ]; then
      echo "[ERROR] 4 から 12 の範囲で指定して下さい。"
      exit 1
    fi
    tick_distance=$input
  fi

  # PLAYER IDLE TIMEOUT ==========
  cat <<EOS

-*-*-*-*- [PLAYER IDLE TIMEOUT (放置時の切断までの分数)] -*-*-*-*-

操作しないまま指定の分数が過ぎると切断されます。
0 を指定すると切断しません。
装置を動かし続けたい場合は 0 にして下さい。ticking area は
同じディメンションに最低 1 人いないと動かず、切断されると止まります。
EOS
  echo -n "Idle timeout (Default: ${player_idle_timeout}): "
  read -r input
  if [ "$input" != "" ]; then
    if [[ ! ("$input" =~ ^[0-9]+$) ]]; then
      echo "[ERROR] 0 以上の数字を入力して下さい。"
      exit 1
    fi
    player_idle_timeout=$input
  fi

  # CHAT RESTRICTION ==========
  chat_restriction_default=$(index_of "$chat_restriction" "${chat_restriction_list[@]}")
  cat <<EOS

-*-*-*-*- [CHAT RESTRICTION (チャットの制限)] -*-*-*-*-

[1] None (制限しない)
[2] Dropped (発言できるが誰にも届かない)
[3] Disabled (チャット欄そのものを出さない)
EOS
  echo -n "Chat restriction (Default: ${chat_restriction_default}): "
  read -r input
  if [ "$input" == "" ]; then input=$chat_restriction_default ; fi
  num_validation "$input" 3
  chat_restriction=${chat_restriction_list[$input-1]}

  # DISABLE PLAYER INTERACTION ==========
  disable_player_interaction_default=$(index_of "$disable_player_interaction" "${bool_list[@]}")
  cat <<EOS

-*-*-*-*- [DISABLE PLAYER INTERACTION (プレイヤー同士の干渉を無効化)] -*-*-*-*-

ON にすると、押し合いや攻撃などの相互作用が無くなります。
[1] ON (干渉しない)
[2] OFF (通常どおり)
EOS
  echo -n "Disable interaction? (Default: ${disable_player_interaction_default}): "
  read -r input
  if [ "$input" == "" ]; then input=$disable_player_interaction_default ; fi
  num_validation "$input" 2
  disable_player_interaction=${bool_list[$input-1]}

  # TEXTUREPACK REQUIRED ==========
  texturepack_required_default=$(index_of "$texturepack_required" "${bool_list[@]}")
  cat <<EOS

-*-*-*-*- [TEXTUREPACK REQUIRED (テクスチャパックの強制)] -*-*-*-*-

ON にすると、サーバーのテクスチャパックの使用を参加者に強制します。
[1] ON (強制する)
[2] OFF (各自の設定を尊重する)
EOS
  echo -n "Texturepack required? (Default: ${texturepack_required_default}): "
  read -r input
  if [ "$input" == "" ]; then input=$texturepack_required_default ; fi
  num_validation "$input" 2
  texturepack_required=${bool_list[$input-1]}

  # DISABLE CUSTOM SKINS ==========
  disable_custom_skins_default=$(index_of "$disable_custom_skins" "${bool_list[@]}")
  cat <<EOS

-*-*-*-*- [DISABLE CUSTOM SKINS (自作スキンの禁止)] -*-*-*-*-

ON にすると、外部で作られた自作スキンを使えなくします。
不適切なスキンを防ぎたい場合に使います。
[1] ON (禁止する)
[2] OFF (許可する)
EOS
  echo -n "Disable custom skins? (Default: ${disable_custom_skins_default}): "
  read -r input
  if [ "$input" == "" ]; then input=$disable_custom_skins_default ; fi
  num_validation "$input" 2
  disable_custom_skins=${bool_list[$input-1]}
fi

cat <<EOS

-*-*-*-*- [変更後の設定] -*-*-*-*-

$(print_settings)

この内容で設定を変更します。
反映にはサーバーの再起動が必要なため、接続中のプレイヤーは全員切断されます。
ワールドのデータはそのまま残ります。
EOS

echo -n "よろしいですか? [y/N]: "
read -r config_yn
if [ "$config_yn" != "y" ]; then exit 1 ; fi

echo ""

# The settings live in /opt/minecraft/run.sh, which systemd runs on every boot.
# Rewriting server.properties would be undone by the next container start, which
# rebuilds it from these variables.
#
# No reboot here, unlike the GCP build: the run script is a file on the machine
# rather than instance metadata, so restarting the unit is enough.
run_script=$(mktemp)
render_startup_script "$run_script"
run_b64=$(base64 -w0 < "$run_script")
rm -f "$run_script"

echo -n "  設定の書き込み中 "
apply_log=$(mktemp)
# Unquoted on purpose: run_b64 has to be substituted before the script is sent.
# shellcheck disable=SC2087
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" "sudo bash -s" > "$apply_log" 2>&1 <<EOS &
set -e
echo '${run_b64}' | base64 -d > /opt/minecraft/run.sh
chmod +x /opt/minecraft/run.sh
EOS
apply_status=0
wait_with_dots $! || apply_status=$?

if [ "$apply_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] 設定の書き込みに失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$apply_log"
  echo "--------------------------------------------------------------------"
  rm -f "$apply_log"
  exit 1
fi
echo " 完了"

echo -n "  再起動中 "
# run.sh stops and replaces the container itself, so restarting the unit is all
# that is needed. The world lives in a docker volume and is untouched.
ssh "${ssh_opts[@]}" "ubuntu@${external_ip}" \
  "sudo systemctl restart minecraft.service" > "$apply_log" 2>&1 &
restart_status=0
wait_with_dots $! || restart_status=$?

if [ "$restart_status" -ne 0 ]; then
  echo " 失敗"
  echo ""
  echo "[ERROR] 再起動に失敗しました。"
  echo "--------------------------------------------------------------------"
  cat "$apply_log"
  echo "--------------------------------------------------------------------"
  rm -f "$apply_log"
  exit 1
fi
rm -f "$apply_log"
echo " 完了"

echo ""
echo -n "マインクラフト再起動中 "

mc_info=$(mktemp)
if wait_for_server "$external_ip" 900 "$mc_info"; then
  # shellcheck disable=SC1090
  . "$mc_info"
  rm -f "$mc_info"
  cat <<EOS

設定の変更が完了しました！

################################################################################
${external_ip}
################################################################################

 バージョン : ${MC_VERSION:-(取得できませんでした)}

EOS
else
  rm -f "$mc_info"
  cat <<EOS

[WARN] 15 分待ちましたが、サーバーが応答しませんでした。

設定は書き込まれています。起動に時間がかかっているだけかもしれません。
下記でログを確認できます。

  ssh -i ${ssh_key} ubuntu@${external_ip} 'sudo docker logs mc-server | tail -30'

EOS
  exit 1
fi
