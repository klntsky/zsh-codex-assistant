# Codex runs this helper when a reply finishes:
#   zsh -f session-notify.zsh <state-file> <notification-json>
#
# The plugin reads two lines from the state file:
#   1. Conversation ID, used to resume the chat.
#   2. Turn ID, used to tell when a new reply has finished.
# The directory must already exist. Exit 0 means saved or skipped;
# other exit codes mean bad input or a file error.

# Start with standard Zsh settings.
emulate -LR zsh
[[ $# == 2 && -d ${1:h} ]] || exit 1
local state_file=$1 notification_json=$2

# Check the conversation ID before using it in a filename search.
local match mbegin mend
local pattern='"thread-id"[[:space:]]*:[[:space:]]*"([[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12})"'
[[ $notification_json =~ $pattern ]] || exit 1
local session_id=$match[1]

# Find the saved conversation. This relies on Codex's session-file layout.
# `(N)` gives an empty list when the search finds nothing.
local -a rollouts=("${CODEX_HOME:-$HOME/.codex}"/sessions/**/rollout-*-${session_id}.jsonl(N))
(( ${#rollouts} == 1 )) || exit 0
# The first line identifies the session's source. Together, these checks
# filter out notifications from title generation and subagents.
local metadata
IFS= read -r metadata < "$rollouts[1]" || exit 1
[[ $metadata =~ '"source"[[:space:]]*:[[:space:]]*"cli"' ]] || exit 0

# Remember which reply finished within this conversation.
pattern='"turn-id"[[:space:]]*:[[:space:]]*"([[:alnum:]_-]+)"'
[[ $notification_json =~ $pattern ]] || exit 1
local turn_id=$match[1]

# Keep the file private. Replace it in one step so the shell always reads
# a complete pair of IDs. Each reply replaces the previous record.
umask 077
print -rl -- "$session_id" "$turn_id" > "$state_file.$$" || exit 1
command mv -f -- "$state_file.$$" "$state_file"
