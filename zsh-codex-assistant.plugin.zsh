[[ -o interactive ]] || return

# Each shell gives Codex its own virtual terminal, managed by Zsh's zpty module.
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
typeset -g _zca_output_pending=${_zca_output_pending-}

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
  # Paste the whole prompt, then press Enter. This keeps multiline input together.
  _zca_write $'\e[200~'"$1"$'\e[201~\r'
}

_zca_start() {
  _zca_alive && return 0
  _zca_read_session

  # Release the old terminal's name before starting a replacement.
  zpty -d "$_zca_pty" 2>/dev/null

  (( $+commands[codex] )) || {
    print -u2 'zsh-codex-assistant: codex not found'
    return 127
  }

  if [[ -z ${TERM-} || $TERM == dumb ]]; then
    print -u2 'zsh-codex-assistant: a supported interactive terminal is required (TERM is unset or dumb)'
    return 1
  fi

  # Give Codex the terminal size before it draws its interface.
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

  # Keep replies in the scrollback and have the helper record each finished turn.
  local cmd="stty rows $rows cols $cols; command codex -C ${(q)PWD} --no-alt-screen \
-c 'tui.raw_output_mode=false' \
-c 'tui.animations=true'"
  cmd+=" -c ${(q)notify_config}"

  # Apply optional model and profile overrides when starting Codex.
  if [[ -n ${ZSH_CODEX_ASSISTANT_MODEL-} ]]; then
    cmd+=" --model=${(q)ZSH_CODEX_ASSISTANT_MODEL}"
  fi
  if [[ -n ${ZSH_CODEX_ASSISTANT_PROFILE-} ]]; then
    cmd+=" --profile=${(q)ZSH_CODEX_ASSISTANT_PROFILE}"
  fi

  # Pass the first prompt at startup so Codex handles it once it's ready.
  if [[ -n $_zca_session_id ]]; then
    cmd+=" resume -- ${(q)_zca_session_id}"
    [[ -n ${1-} ]] && cmd+=" ${(q)1}"
  else
    local initial_prompt='Act as a shell assistant'
    [[ -n ${1-} ]] && initial_prompt+=$'\n\n'"$1"
    cmd+=" -- ${(q)initial_prompt}"
  fi
  # Read output as it arrives to keep the interface responsive.
  _zca_output_pending=''
  zpty -b "$_zca_pty" "$cmd" || return 1
  _zca_cwd=$PWD
}

_zca_sync_cwd() {
  [[ $PWD == $_zca_cwd ]] && return 0

  # Keep the running Codex session in the shell's current directory.
  _zca_submit "/cd $PWD" || return 1
  _zca_cwd=$PWD
}

_zca_interrupt() {
  # Send Ctrl-C to Codex to interrupt the current reply.
  _zca_alive && _zca_write $'\003'
}

_zca_output() {
  emulate -L zsh
  local data="$_zca_output_pending$1" output='' prefix
  _zca_output_pending=''

  # Filter scrollback erasure, keeping partial sequences for the next read.
  while [[ $data == *$'\e'* ]]; do
    prefix=${data%%$'\e'*}
    output+=$prefix
    data=${data#"$prefix"}
    case $data in
      $'\e[3J'*) data=${data[5,-1]} ;;
      $'\e[?3J'*) data=${data[6,-1]} ;;
      $'\e'|$'\e['|$'\e[3'|$'\e[?'|$'\e[?3')
        _zca_output_pending=$data
        data=''
        break ;;
      *) output+=$'\e'; data=${data[2,-1]} ;;
    esac
  done
  print -nr -- "$output$data"
}

_zca_prepare_screen() {
  emulate -L zsh
  [[ -t 1 ]] || return 0
  local rows=${LINES:-24}
  (( rows > 0 )) || rows=24
  # Push the shell output into scrollback and give Codex a fresh screen.
  repeat $rows print
  print -nr -- $'\e[H'
}

_zca_drain() {
  local chunk

  # Show any output that's already waiting, including bells.
  while zpty -rt "$_zca_pty" chunk 2>/dev/null; do
    _zca_output "$chunk"
  done
}

_zca_wait() {
  local previous_turn=${1-} chunk key cancelled=0
  setopt localtraps

  # Ctrl-C interrupts Codex and returns to the shell with status 130.
  trap '_zca_interrupt; cancelled=1' INT

  while _zca_alive; do
    (( cancelled )) && return 130
    if zpty -r "$_zca_pty" chunk; then
      _zca_output "$chunk"
    fi
    (( cancelled )) && return 130

    # Return when the helper records a different completed turn.
    _zca_read_session
    if [[ -n $_zca_completed_turn && $_zca_completed_turn != $previous_turn ]]; then
      # Give Codex a moment to draw the end of the reply.
      zselect -t 5 2>/dev/null
      _zca_drain
      return 0
    fi

    # Pass through keystrokes and terminal responses, including during login.
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

  # Put the shell history before the user's question.
  if (( ${#_zca_shell_delta} )); then
    prompt=$'New shell history context (may not be relevant):\n'"${(F)_zca_shell_delta}"$'\n\n---\n\n'"$prompt"
  fi

  _zca_prepare_screen
  if _zca_alive; then
    # Redraw the persistent UI on the fresh screen.
    _zca_write $'\f' || return
    _zca_sync_cwd || return
    _zca_submit "$prompt" || return
  else
    _zca_start "$prompt" || return
  fi
  _zca_shell_delta=()
  _zca_wait "$previous_turn"
}

# Send a question to the shell's Codex session.
function @ {
  if (( $# == 0 )); then
    print -u2 -- 'Usage: @ <prompt>'
    return 2
  fi

  {
    _zca_ask "$*"
  } always {
    _zca_read_session
    # Restore the terminal for Zsh while Codex stays running.
    if [[ -t 1 ]]; then
      print -nr -- $'\e[?2026l\e[?1004l\e[?2004l\e[<u\e[>4;0m\e[?25h\e[0m'
    fi
    if _zca_alive; then
      print -u2 -- 'Codex keeps running in the background. Type "@ your prompt" to continue.'
    fi
  }
}

_zca_preexec() {
  [[ $1 == '@' || $1 == '@ '* || $1 == '\@ '* ]] && return

  # Save shell commands to include with the next question.
  _zca_shell_delta+=("$1")
}

_zca_accept_line() {
  emulate -L zsh
  if [[ -z $PREBUFFER && $BUFFER == '@ '* ]]; then
    # Keep the typed line in history and on screen while accepting an empty line.
    print -rs -- "$BUFFER"
    typeset -g _zca_pending_prompt=${BUFFER#'@ '}
    local shown=$BUFFER
    BUFFER=''
    (( $+functions[_zsh_autosuggest_clear] )) && _zsh_autosuggest_clear
    POSTDISPLAY=$shown
    zle .accept-line
    return
  fi
  zle _zca_original_accept_line
}

_zca_precmd() {
  emulate -L zsh
  if (( ${+_zca_pending_prompt} )); then
    local prompt=$_zca_pending_prompt
    unset _zca_pending_prompt
    @ "$prompt"
  fi
  return 0
}

# Keep the existing Enter handler, including customizations from other plugins.
if (( ! ${+widgets[_zca_original_accept_line]} )); then
  zle -A accept-line _zca_original_accept_line
  zle -N accept-line _zca_accept_line
fi

typeset -ga preexec_functions
(( ${preexec_functions[(Ie)_zca_preexec]} )) || preexec_functions+=(_zca_preexec)
typeset -ga precmd_functions
(( ${precmd_functions[(Ie)_zca_precmd]} )) || precmd_functions+=(_zca_precmd)
typeset -ga zshexit_functions
(( ${zshexit_functions[(Ie)_zca_cleanup]} )) || zshexit_functions+=(_zca_cleanup)
