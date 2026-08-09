################################################################################
# Writes the server run script to the given path.
#
# The settings live in this script rather than in server.properties, because the
# image rewrites server.properties from these environment variables on every
# container start. Editing the file directly is undone by the next restart;
# changing this script and restarting is what actually sticks.
#
# The script is placed at /opt/minecraft/run.sh on the instance and run by a
# systemd unit at every boot. cloud-init cannot take its place: user_data runs
# only on the first boot, so rewriting it later would have no effect until the
# instance was recreated.
#
# create.sh and config.sh both go through here so that a settings change cannot
# drift from what a fresh build would produce.
#
# Reads: server_name, game_mode, difficulty, allow_cheat, max_players,
#        view_distance, permission, seed, and the advanced settings below.
#
# Every setting carries a default here, so create.sh can leave the advanced ones
# alone and config.sh can still change them later without the two drifting.
#
# The defaults are Minecraft's own except for two, which are set for the free
# tier: VIEW_DISTANCE (32 -> 5) and PLAYER_IDLE_TIMEOUT (30 -> 5). Both bound
# outbound traffic, which is what the 1 GB monthly allowance runs out of first.
#
# Those two are the only ones left to set. Everything else that moves traffic
# already ships at its cheapest value: TICK_DISTANCE is at the bottom of its
# 4-12 range, CLIENT_SIDE_CHUNK_GENERATION_ENABLED already hands terrain
# generation to the client, COMPRESSION_THRESHOLD of 1 already compresses
# everything, COMPRESSION_ALGORITHM is zlib rather than the weaker-compressing
# snappy, and EMIT_SERVER_TELEMETRY is off. None are set here, so that they
# follow Minecraft rather than freezing today's value.
#
# Arguments:
#   1: Path to write to
# Returns:
#   None
################################################################################
function render_startup_script() {
  local out=$1

  # Most settings come from a fixed menu or are checked as numbers, but the
  # server name, the seed and the allow list are typed in freely, and a
  # Minecraft gamertag may well contain a space. Unquoted, a space splits the
  # docker run arguments and the stray word is taken as the image name, so the
  # container silently never starts. Quote those three for the generated script.
  local q_server_name q_seed q_allow_list_users
  # shellcheck disable=SC2154
  printf -v q_server_name '%q' "${server_name:-ydak}"
  # shellcheck disable=SC2154
  printf -v q_seed '%q' "${seed:-}"
  # shellcheck disable=SC2154
  printf -v q_allow_list_users '%q' "${allow_list_users:-}"

  # The remaining settings are read from the caller's scope rather than passed
  # in: there are sixteen of them, and positional arguments would be easy to
  # transpose.
  # shellcheck disable=SC2154
  cat > "$out" <<EOS
#!/bin/bash
mkdir -p /var/minecraft
cd /var/minecraft/ || exit 1
docker volume create mc-volume

# The Bedrock binary is downloaded at container start and is always current,
# but it runs against the libraries baked into this image. Pinning the image
# would leave those to age, so pull it again on every boot.
#
# Pull first and replace the container only if that succeeded: a failed pull
# then leaves the running container untouched.
if docker pull itzg/minecraft-bedrock-server:latest; then
  # --restart=always may have started the old container already. Stop it
  # gracefully first. The image turns SIGTERM into a clean 'stop', while
  # removing it outright can leave the world half written.
  docker stop -t 60 mc-server > /dev/null 2>&1
  docker rm -f mc-server > /dev/null 2>&1
fi

if ! docker inspect mc-server > /dev/null 2>&1; then
  docker run -d -it --name mc-server --restart=always -e EULA=TRUE -e SERVER_NAME=$q_server_name -e GAMEMODE=${game_mode:-survival} -e FORCE_GAMEMODE=${force_gamemode:-false} -e DIFFICULTY=${difficulty:-normal} -e ALLOW_CHEATS=${allow_cheat:-false} -e ALLOW_LIST=${allow_list:-false} -e ALLOW_LIST_USERS=$q_allow_list_users -e MAX_PLAYERS=${max_players:-2} -e VIEW_DISTANCE=${view_distance:-5} -e TICK_DISTANCE=${tick_distance:-4} -e PLAYER_IDLE_TIMEOUT=${player_idle_timeout:-5} -e DEFAULT_PLAYER_PERMISSION_LEVEL=${permission:-member} -e CHAT_RESTRICTION=${chat_restriction:-None} -e DISABLE_PLAYER_INTERACTION=${disable_player_interaction:-false} -e TEXTUREPACK_REQUIRED=${texturepack_required:-false} -e DISABLE_CUSTOM_SKINS=${disable_custom_skins:-false} -e LEVEL_SEED=$q_seed -p 19132:19132/udp -v mc-volume:/data itzg/minecraft-bedrock-server:latest
fi
EOS
}

################################################################################
# Prints a dot a second until the given process exits.
#
# Arguments:
#   1: Process id to wait for
# Returns:
#   The exit status of that process
################################################################################
function wait_with_dots() {
  local pid=$1
  local status=0

  # Start at three so the label never sits on its own for a moment, then add one
  # a second from there.
  echo -n "..."

  while kill -0 "$pid" 2> /dev/null; do
    echo -n "."
    sleep 1
  done

  # The process has already gone, but bash keeps its status until it is reaped.
  wait "$pid" || status=$?
  return $status
}

################################################################################
# Prints a dot a second for the given number of seconds.
#
# Arguments:
#   1: Seconds to wait
# Returns:
#   None
################################################################################
function sleep_with_dots() {
  local seconds=$1
  local i

  for ((i = 0; i < seconds; i++)); do
    echo -n "."
    sleep 1
  done
}

################################################################################
# Receives a string and check if it is a specified number.
# If it is not a valid number, exits with error code 1.
#
# Arguments:
#   1: Received input
#   2: Valid max number
# Returns:
#   None
################################################################################
function num_validation() {
  local received=$1
  local max_num=$2

  if [ "$received" != "" ]; then
    if [[ ! ("$received" =~ ^[1-$max_num]$) ]]; then
      echo "[ERROR] Enter valid number. (数字を正しく入力して下さい。)"
      exit 1
    fi
  fi
}

################################################################################
# Receives a string and checks if it is a positive integer.
# Used where the answer is not a menu choice, so num_validation, which only
# accepts a single digit within a range, does not fit.
# If it is not valid, exits with error code 1.
#
# Arguments:
#   1: Received input
# Returns:
#   None
################################################################################
function positive_num_validation() {
  local received=$1

  if [[ ! ("$received" =~ ^[1-9][0-9]*$) ]]; then
    echo "[ERROR] Enter a number of 1 or more. (1 以上の数字を入力して下さい。)"
    exit 1
  fi
}

################################################################################
# Normalizes a comma separated allow list, dropping empty entries and the
# spaces around each one. Only the surrounding spaces go: a gamertag may itself
# contain one.
#
# An entry is either a bare gamertag or 'gamertag:xuid'. The image picks
# between the two by looking for a colon anywhere in the whole string, not per
# entry, so one entry in the second form turns every entry in the first form
# into a null xuid and those players stop matching. Mixing the two is refused
# here rather than producing an allow list that silently omits people.
#
# Arguments:
#   1: The list as typed
# Returns:
#   0 and prints the normalized list, or 1 if the two forms are mixed
################################################################################
function normalize_allow_list_users() {
  local raw=$1
  local -a entries
  local entry out="" total=0 with_xuid=0

  # read -a rather than word splitting on IFS: an unquoted expansion would also
  # expand a gamertag containing '*' against the file system.
  IFS=',' read -r -a entries <<< "$raw"

  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    if [ -z "$entry" ]; then continue ; fi

    total=$((total + 1))
    case "$entry" in *:*) with_xuid=$((with_xuid + 1)) ;; esac

    if [ -z "$out" ]; then out=$entry ; else out="${out},${entry}" ; fi
  done

  if [ "$with_xuid" -ne 0 ] && [ "$with_xuid" -ne "$total" ]; then
    return 1
  fi

  echo "$out"
}

################################################################################
# Waits until the Bedrock server answers a RakNet unconnected ping.
# Prints a dot every second while waiting.
#
# This probes UDP 19132 from the outside, so it covers the whole path at once:
# the firewall rule, the container, and the server itself. No SSH key needed.
#
# Arguments:
#   1: External IP address of the server
#   2: Timeout in seconds
#   3: Optional path to write the answered details to, as shell assignments
# Returns:
#   0 if the server answered, 1 on timeout
################################################################################
function wait_for_server() {
  local ip=$1
  local timeout=$2
  local info_path=${3:-}

  if ! command -v python3 > /dev/null; then
    echo ""
    echo "[WARN] python3 not found. Skipping the health check."
    echo "       (python3 が無いためヘルスチェックを省略します。)"
    return 0
  fi

  python3 - "$ip" "$timeout" "$info_path" <<'PYEOF'
import shlex
import socket
import struct
import sys
import time

# OFFLINE_MESSAGE_DATA_ID. Every RakNet offline packet carries this.
MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
PORT = 19132

ip = sys.argv[1]
deadline = time.time() + int(sys.argv[2])
info_path = sys.argv[3] if len(sys.argv) > 3 else ""

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
# Kept under the one second tick so that the probe and the wait together still
# land on a dot a second, rather than drifting out to two.
sock.settimeout(0.8)
next_tick = time.time()

# Same three-dot head start as wait_with_dots, so both read the same way.
sys.stdout.write("...")
sys.stdout.flush()

while time.time() < deadline:
    # ID_UNCONNECTED_PING: id(1) + time(8) + magic(16) + client guid(8)
    ping = b"\x01" + struct.pack(">Q", int(time.time() * 1000)) + MAGIC + struct.pack(">Q", 0)
    try:
        sock.sendto(ping, (ip, PORT))
        data, _ = sock.recvfrom(4096)
    except Exception:
        data = b""

    # ID_UNCONNECTED_PONG: id(1) + time(8) + server guid(8) + magic(16) + motd
    if data[:1] == b"\x1c" and len(data) > 35:
        length = struct.unpack(">H", data[33:35])[0]
        fields = data[35:35 + length].decode("utf-8", "replace").split(";")
        print("")
        if len(fields) >= 6:
            print("  Server name : %s" % fields[1])
            print("  Version     : %s" % fields[3])
            print("  Players     : %s/%s" % (fields[4], fields[5]))
            # The MOTD is whatever the operator typed, so quote every value
            # before it is sourced back into the shell.
            if info_path:
                lines = [
                    "MC_NAME=" + shlex.quote(fields[1]),
                    "MC_VERSION=" + shlex.quote(fields[3]),
                    "MC_MAX_PLAYERS=" + shlex.quote(fields[5]),
                    "",
                ]
                with open(info_path, "w", encoding="utf-8") as fh:
                    fh.write(chr(10).join(lines))
        sys.exit(0)

    sys.stdout.write(".")
    sys.stdout.flush()
    next_tick += 1.0
    remaining = next_tick - time.time()
    if remaining > 0:
        time.sleep(remaining)

print("")
sys.exit(1)
PYEOF
}
