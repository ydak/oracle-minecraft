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
