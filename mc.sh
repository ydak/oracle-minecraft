#!/usr/bin/env bash
#
# Bootstrap for oracle-minecraft. Run it in the Oracle Cloud Shell.
#
#   curl -fsSL https://raw.githubusercontent.com/ydak/oracle-minecraft/main/mc.sh | bash
#
# The scripts in this repository source functions.sh and const.sh from their own
# directory, so a single file cannot be piped straight into a shell. This
# downloads the repository into a temporary directory, asks what to do, and
# hands over to the matching script.
#
set -e

REPO="ydak/oracle-minecraft"
REF="${REF:-main}"
ACTION="${1:-}"

# backup and restore are not ported yet. The menu offers only what exists, so
# that choosing an entry cannot fail with a missing file.
action_list=(create update config delete)

usage() {
  cat <<EOS
Usage (CloudShell):

  curl -fsSL https://raw.githubusercontent.com/ydak/oracle-minecraft/main/mc.sh | bash

Then pick what to do from the menu.
(その後、メニューから操作を選択します。)

  create   Create a Minecraft server (マインクラフトサーバーを作成)
  update   Update Minecraft and the host (マインクラフトとホストを更新)
  config   Change server settings (マインクラフトの設定を変更)
  delete   Delete the server (マインクラフトサーバーを削除)

An action can also be given directly, which skips the menu.
(操作を引数で直接指定すると、メニューを省略できます。)

  ... | bash -s -- create
  ... | bash -s -- config

Set REF to use a branch or tag other than main.
(REF を指定すると main 以外のブランチ・タグを利用できます。)
EOS
}

case "$ACTION" in
  "" | create | update | config | delete) ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    echo "[ERROR] Unknown action: $ACTION"
    echo "        (不明な操作です。create / update / config / delete のいずれかを指定して下さい。)"
    echo ""
    usage
    exit 1
    ;;
esac

for cmd in curl tar; do
  if ! command -v "$cmd" > /dev/null; then
    echo "[ERROR] '$cmd' is required but was not found."
    echo "        ('$cmd' が見つかりません。)"
    exit 1
  fi
done

# When this script is piped into a shell, stdin is the pipe rather than the
# terminal, so the menu below and the prompts in create.sh would read whatever
# is left of this script instead of the user's answer.
#
# The fix is NOT `exec < /dev/tty`. The shell is reading this very script from
# stdin, so replacing stdin makes it read the remaining lines from the terminal
# and hang forever, before even reaching the first echo. Redirect per command
# instead: that is undone as soon as the command returns, leaving the shell's
# own read of this script alone.
tty_available=0
if [ -c /dev/tty ] && (: < /dev/tty) 2> /dev/null; then
  tty_available=1
fi

echo ""
echo "==================== Minecraft サーバー管理 ===================="
echo ""

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# The repository name and branch mean nothing to someone who just wants a
# Minecraft server, so they are kept out of the way unless a specific ref was
# asked for, in which case showing it is how that choice gets confirmed.
if [ "$REF" == "main" ]; then
  echo -n "準備中 "
else
  echo -n "準備中 (${REF}) "
fi

# pipefail is scoped to this subshell so that a failed download is caught here
# rather than being masked by tar's exit status. functions.sh is not available
# yet, so the dot loop is written out rather than calling wait_with_dots.
(set -o pipefail
 curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${REF}" \
   | tar xz -C "$work_dir" --strip-components=1) > /dev/null 2>&1 &
download_pid=$!
echo -n "..."
while kill -0 "$download_pid" 2> /dev/null; do
  echo -n "."
  sleep 1
done
download_status=0
wait "$download_pid" || download_status=$?

if [ "$download_status" -ne 0 ]; then
  echo " 失敗"
  cat <<EOS

[ERROR] 必要なファイルを取得できませんでした。
        通信環境を確認して、もう一度お試しください。
        (Failed to download ${REPO} (${REF}).)

EOS
  exit 1
fi
echo " 完了"

# shellcheck source=functions.sh
. "${work_dir}/functions.sh"

# ACTION ==========
if [ "$ACTION" == "" ]; then
  if [ "$tty_available" == "0" ]; then
    echo "[ERROR] No terminal is available, so the menu cannot be shown."
    echo "        (端末が無いためメニューを表示できません。)"
    echo "        Pass the action directly: ... | bash -s -- create"
    echo "        (操作を引数で指定して下さい。)"
    exit 1
  fi

  cat <<EOS

-*-*-*-*- [ACTION (操作を選択)] -*-*-*-*-

[1] create  (マインクラフトサーバーを作成)
[2] update  (マインクラフトとホストを更新)
[3] config  (マインクラフトの設定を変更)
[4] delete  (マインクラフトサーバーを削除)
EOS
  echo -n "Select action (Default: 1): "
  read -r action_num < /dev/tty
  if [ "$action_num" == "" ]; then action_num=1 ; fi
  num_validation "$action_num" 4
  ACTION=${action_list[$action_num-1]}
fi

if [ ! -f "${work_dir}/${ACTION}.sh" ]; then
  echo "[ERROR] ${ACTION}.sh was not found in ${REPO} (${REF})."
  echo "        (${ACTION}.sh が見つかりませんでした。)"
  exit 1
fi

# Same reasoning as above: give the child the terminal through a redirect on
# this one command. Without a terminal, feed it /dev/null so that its prompts
# hit EOF and fall back to their defaults, rather than eating whatever is left
# of this script on stdin.
if [ "$tty_available" == "1" ]; then
  bash "${work_dir}/${ACTION}.sh" < /dev/tty
else
  bash "${work_dir}/${ACTION}.sh" < /dev/null
fi
