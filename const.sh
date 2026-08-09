# These arrays are consumed by the scripts that source this file. ShellCheck
# analyses each file on its own, so it cannot see those uses from here.
# shellcheck disable=SC2034

game_mode_list=(survival creative adventure)
difficulty_list=(peaceful easy normal hard)
allow_cheat_list=(true false)
permission_num_list=(visitor member operator)

# Used by the advanced settings, which are all either on/off or a small set of
# named values.
bool_list=(true false)
chat_restriction_list=(None Dropped Disabled)

# Names of what the scripts build, and how they reach it. Kept here rather than
# repeated in each script: five copies of the same ssh options is five chances
# for one of them to be left behind when the others change.
SERVER_NAME=minecraft
VCN_NAME=minecraft-vcn
SUBNET_NAME=minecraft-subnet
IGW_NAME=minecraft-igw
BUCKET=minecraft-backup

# Where the container's /data lands on the host.
VOLUME_PATH=/var/lib/docker/volumes/mc-volume/_data

# -T because without it a remote tool can decide it is talking to a terminal and
# start emitting cursor control, which lands in the middle of the progress dots.
ssh_key=~/.ssh/id_rsa
ssh_opts=(-T -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10)
