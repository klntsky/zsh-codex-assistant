# Development

## Files and flow

- `zsh-codex-assistant.plugin.zsh` defines `@`, collects commands through Zsh's `preexec` hook, and relays input/output to a persistent `zpty` process.
- `session-notify.zsh` receives Codex's completion notification and writes the conversation ID and turn ID to a two-line state file.

The first request starts Codex with `Act as a shell assistant`, followed by any collected shell commands, then the user's question. History and the question are separated by `---`. Later requests reuse the process. If it exits, the next request resumes the saved conversation ID when available.

The completion helper searches Codex's session files for the notified conversation and checks the first metadata record for a CLI source. This filters notifications from internal title generation and subagents. It depends on Codex's rollout filenames and metadata format.

The helper writes an owner-only temporary file and renames it over the state file. The plugin polls for a changed completion token. The state directory is created with `mktemp -d`; the shell-exit hook removes its state file and directory. Zsh owns the child PTY's lifecycle.

## Configuration and terminal handling

The Enter widget reads lines beginning with `@ ` before shell parsing. It saves
the original line in history, displays it through `POSTDISPLAY`, and accepts an
empty input buffer. A `precmd` hook takes the pending question, clears it, and
calls `@ "$prompt"` directly.
Ordinary commands call the saved `accept-line` widget.

History recall brings back the original text for editing and resubmission.
Continuation prompts retain normal shell parsing. This interception applies to
interactive line editing; calls from scripts use normal shell quoting.
Load after other Enter customizations; keys bound to
widgets that bypass `accept-line` also bypass this interception.

Startup reads `ZSH_CODEX_ASSISTANT_MODEL` and `ZSH_CODEX_ASSISTANT_PROFILE`, adding shell-quoted CLI arguments for nonempty values. An existing process keeps its startup settings.

The plugin overrides Codex's `notify` command with its helper, enables animations, disables raw-output mode, and uses `--no-alt-screen` to retain scrollback. Approval, terminal-title, and TUI notification settings come from Codex configuration.

Prompts are sent as bracketed paste followed by Enter. Ctrl-C is forwarded to the child. Before returning to Zsh, the plugin resets terminal input/display modes. Bells pass through unchanged.

Before each request, a screenful of newlines moves the current display into scrollback. The cursor returns to the top, and a reused Codex process receives Ctrl-L to redraw. Output filtering removes `ESC[3J` and `ESC[?3J` (saved-line erasure), buffering partial sequences across reads. Ordinary screen and line erasures still reach the terminal so the TUI can redraw. This adds blank space between invocations; retained output remains subject to the terminal's scrollback limit.

## Checks

```sh
zsh -n zsh-codex-assistant.plugin.zsh
zsh -n session-notify.zsh
zsh -fic 'source tests/terminal-output.zsh'
git diff --check
```

The output-filter tests cover split sequences, repeated erasures, colors, bells, Unicode, and redirected output. Further regression cases include consecutive questions, restart/resume, cancellation, history ordering, and unset/empty/quoted model and profile overrides. Stub Codex for transport tests to avoid model requests.

## Known limitations

- Nonblocking `zpty` writes can report success after sending only part of a large prompt. A slow-reader test delivered 11,776 of 200,000 bytes with status 0. Reliable buffered writes are still needed, especially with uncapped history.
- Completion detection accepts any changed turn token. A simulated delayed callback exposed a potential race; an end-to-end reproduction remains unconfirmed.
- A missing or rejected completion callback can leave the plugin waiting. Local slash commands may also produce no completion callback.
- Terminal dimensions are set at startup; resizing is not forwarded.
- Directory synchronization sends `/cd` and the question without waiting for acknowledgment.
- Command history is collected independently of Zsh's saved-history exclusions. It has no secret filtering.
- Session state belongs to one shell. A newly opened shell starts its own conversation.
