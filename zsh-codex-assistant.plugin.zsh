[[ -o interactive ]] || return
typeset -g _ZCA_LOADED=1

# zpty is bundled with zsh; each interactive shell owns one named Codex PTY.
zmodload zsh/zpty || {
  print -u2 'zsh-codex-assistant: zsh/zpty unavailable'
  return 1
}
zmodload zsh/zselect || return 1

typeset -g _zca_pty=${_zca_pty:-"zsh-codex-assistant-$$"}
typeset -g _zca_cwd=${_zca_cwd-}
typeset -ga _zca_shell_delta
typeset -g _zca_plugin_dir=${${(%):-%x}:A:h}
typeset -g _zca_session_dir=${_zca_session_dir-}
typeset -g _zca_session_id=${_zca_session_id-}
typeset -g _zca_completed_turn=${_zca_completed_turn-}
typeset -g _zca_had_turn=${_zca_had_turn:-0}

_zca_read_session() {
  local saved completed
  if [[ -n $_zca_session_dir && -r $_zca_session_dir/id ]]; then
    {
      IFS= read -r saved
      IFS= read -r completed
    } < "$_zca_session_dir/id"
    if [[ $saved =~ '^[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}$' ]]; then
      _zca_session_id=$saved
      if [[ $completed =~ '^[[:alnum:]_-]+$' ]]; then
        _zca_completed_turn="$saved/$completed"
      fi
    fi
  fi
}

_zca_config_string() {
  REPLY=${1//\\/\\\\}
  REPLY=${REPLY//\"/\\\"}
  REPLY=${REPLY//$'\n'/\\n}
  REPLY=${REPLY//$'\r'/\\r}
  REPLY=${REPLY//$'\t'/\\t}
  REPLY=\"$REPLY\"
}

_zca_cleanup() {
  [[ -n $_zca_session_dir ]] || return 0
  command rm -f -- "$_zca_session_dir/id"
  command rmdir -- "$_zca_session_dir" 2>/dev/null
}

_zca_alive() {
  zpty -t "$_zca_pty" 2>/dev/null
}

_zca_write() {
  zpty -w -n "$_zca_pty" "$1"
}

_zca_submit() {
  # Bracketed paste keeps multiline text as one Codex submission; CR presses Enter.
  _zca_write $'\e[200~'"$1"$'\e[201~\r'
}

_zca_start() {
  _zca_alive && return 0
  _zca_read_session

  # Never silently replace a completed conversation when its ID could not be saved.
  if (( _zca_had_turn )) && [[ -z $_zca_session_id ]]; then
    print -u2 'zsh-codex-assistant: session ID unavailable; use codex resume to recover the conversation'
    return 1
  fi

  # A terminated process still reserves its PTY name until explicitly removed.
  zpty -d "$_zca_pty" 2>/dev/null

  (( $+commands[codex] )) || {
    print -u2 'zsh-codex-assistant: codex not found'
    return 127
  }

  if [[ -z ${TERM-} || $TERM == dumb ]]; then
    print -u2 'zsh-codex-assistant: a supported interactive terminal is required (TERM is unset or dumb)'
    return 1
  fi

  # zpty starts with a 0x0 window; set its size before Codex initializes its UI.
  local rows=${LINES:-24} cols=${COLUMNS:-80}
  (( rows > 0 )) || rows=24
  (( cols > 0 )) || cols=80

  if [[ -z $_zca_session_dir ]]; then
    _zca_session_dir=$(mktemp -d "${TMPDIR:-/tmp}/zsh-codex-assistant.XXXXXXXX") || return 1
  fi
  local REPLY notify_config='notify=["zsh","-f",'
  _zca_config_string "$_zca_plugin_dir/session-notify.zsh"
  notify_config+="$REPLY,"
  _zca_config_string "$_zca_session_dir/id"
  notify_config+="$REPLY]"

  # --no-alt-screen leaves output visible; notify records actual turn completion.
  local cmd="stty rows $rows cols $cols; command codex -C ${(q)PWD} --no-alt-screen -a never \
-c 'tui.raw_output_mode=false' \
-c 'tui.animations=true' \
-c 'tui.terminal_title=[]' \
-c 'tui.notifications=[\"agent-turn-complete\"]' \
-c 'tui.notification_method=\"bel\"' \
-c 'tui.notification_condition=\"always\"'"
  cmd+=" -c ${(q)notify_config}"

  # Initial input must survive startup, terminal probing, and onboarding screens.
  if [[ -n $_zca_session_id ]]; then
    cmd+=" resume -- ${(q)_zca_session_id}"
    [[ -n ${1-} ]] && cmd+=" ${(q)1}"
  else
    local initial_prompt='Act as a shell assistant'
    [[ -n ${1-} ]] && initial_prompt+=$'\n\n'"$1"
    cmd+=" -- ${(q)initial_prompt}"
  fi
  # Nonblocking reads deliver terminal output even when it has no trailing newline.
  zpty -b "$_zca_pty" "$cmd" || return 1
  _zca_cwd=$PWD
}

_zca_sync_cwd() {
  [[ $PWD == $_zca_cwd ]] && return 0

  # The Codex process is long-lived, so explicitly move its working directory with the shell.
  _zca_submit "/cd $PWD" || return 1
  _zca_cwd=$PWD
}

_zca_interrupt() {
  # Interrupt the current Codex turn without killing the persistent Codex process.
  _zca_alive && _zca_write $'\003'
}

_zca_drain() {
  local chunk

  # Print already-buffered terminal output without ringing terminal bells.
  while zpty -rt "$_zca_pty" chunk 2>/dev/null; do
    chunk=${chunk//$'\a'/}
    print -nr -- "$chunk"
  done
}

_zca_wait() {
  local previous_turn=${1-} chunk key cancelled=0
  setopt localtraps

  # Ctrl-C is forwarded to Codex, then this shell command returns 130.
  trap '_zca_interrupt; cancelled=1' INT

  while _zca_alive; do
    (( cancelled )) && return 130
    if zpty -r "$_zca_pty" chunk; then
      if (( cancelled )); then
        chunk=${chunk//$'\a'/}
        print -nr -- "$chunk"
        return 130
      fi

      chunk=${chunk//$'\a'/}
      print -nr -- "$chunk"
    elif (( cancelled )); then
      return 130
    fi

    # A queued BEL or replayed terminal output cannot complete the current prompt.
    _zca_read_session
    if [[ -n $_zca_completed_turn && $_zca_completed_turn != $previous_turn ]]; then
      _zca_had_turn=1
      # Let the TUI render the final response after the notification callback.
      zselect -t 5 2>/dev/null
      _zca_drain
      return 0
    fi

    # Forward terminal replies and input for login/trust screens as well as turns.
    if [[ -t 0 ]]; then
      if read -rsk1 -t 0.03 key; then
        [[ $key == $'\n' ]] && key=$'\r'
        _zca_write "$key"
      fi
    else
      zselect -t 3 2>/dev/null
    fi
  done

  _zca_drain
  (( cancelled )) && return 130
  print -u2 'zsh-codex-assistant: codex exited'
  return 1
}

_zca_ask() {
  emulate -L zsh
  local prompt=$1
  _zca_read_session
  local previous_turn=$_zca_completed_turn

  # Give Codex shell history it could not otherwise observe. Terminal output is never captured.
  if (( ${#_zca_shell_delta} )); then
    prompt=$'New shell history context (may not be relevant):\n'"${(F)_zca_shell_delta}"$'\n\n---\n\n'"$prompt"
  fi

  if _zca_alive; then
    _zca_sync_cwd || return
    _zca_submit "$prompt" || return
  else
    _zca_start "$prompt" || return
  fi
  _zca_shell_delta=()
  _zca_wait "$previous_turn"
}

_zca_interactive() {
  emulate -L zsh
  local chunk key
  setopt localtraps
  trap '_zca_interrupt' INT

  _zca_start || return
  _zca_sync_cwd || return

  print -u2 -- $'\n[zsh-codex-assistant: Ctrl-] returns to zsh]\n'
  _zca_write $'\f'

  # Small relay loop: PTY output -> terminal, terminal keystrokes -> the same live Codex PTY.
  while _zca_alive; do
    while zpty -rt "$_zca_pty" chunk 2>/dev/null; do
      print -nr -- "$chunk"
    done

    if read -rsk1 -t 0.03 key; then
      while true; do
        # Ctrl-] detaches from Codex but leaves the process and conversation alive.
        if [[ $key == $'\035' ]]; then
          print
          return 0
        fi

        [[ $key == $'\n' ]] && key=$'\r'
        _zca_write "$key"
        read -rsk1 -t 0 key || break
      done
    fi
  done

  print
}

# Explicit entry point: pass a prompt, or attach to the live session with bare @.
function @ {
  {
    if (( $# )); then
      _zca_ask "$*"
    else
      _zca_interactive
    fi
  } always {
    _zca_read_session
    # Codex remains alive, so undo its terminal input modes when returning to Zsh.
    if [[ -t 1 ]]; then
      print -nr -- $'\e[?2026l\e[?1004l\e[?2004l\e[<u\e[>4;0m\e[?25h\e[0m'
    fi
  }
}

_zca_preexec() {
  [[ $1 == '@' || $1 == '@ '* ]] && return

  # Keep only recent commands executed directly by zsh; they are sent on the next Codex turn.
  _zca_shell_delta+=("$1")
  (( ${#_zca_shell_delta} > 20 )) && shift _zca_shell_delta
}

typeset -ga preexec_functions
(( ${preexec_functions[(Ie)_zca_preexec]} )) || preexec_functions+=(_zca_preexec)
typeset -ga zshexit_functions
(( ${zshexit_functions[(Ie)_zca_cleanup]} )) || zshexit_functions+=(_zca_cleanup)
