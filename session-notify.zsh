# Record the session and completed turn together; terminal BEL is not a protocol.
emulate -LR zsh
[[ $# == 2 && -d ${1:h} ]] || exit 1
local match mbegin mend
local pattern='"thread-id"[[:space:]]*:[[:space:]]*"([[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12})"'
[[ $2 =~ $pattern ]] || exit 1
local session_id=$match[1]

# Internal title-generation jobs also emit notifications, but have no saved CLI
# conversation. Subagents have a different source. Neither may detach this TUI
# or replace its resume ID.
local -a rollouts=("${CODEX_HOME:-$HOME/.codex}"/sessions/**/rollout-*-${session_id}.jsonl(N))
(( ${#rollouts} == 1 )) || exit 0
local metadata
IFS= read -r metadata < "$rollouts[1]" || exit 1
[[ $metadata =~ '"source"[[:space:]]*:[[:space:]]*"cli"' ]] || exit 0

pattern='"turn-id"[[:space:]]*:[[:space:]]*"([[:alnum:]_-]+)"'
[[ $2 =~ $pattern ]] || exit 1
local turn_id=$match[1]
umask 077
print -rl -- "$session_id" "$turn_id" > "$1.$$" || exit 1
command mv -f -- "$1.$$" "$1"
