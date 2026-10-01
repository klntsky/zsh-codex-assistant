# Development

## Files and flow

- `zsh-codex-assistant.plugin.zsh` defines `@`, collects commands through Zsh's `preexec` hook, and relays input/output to a persistent `zpty` process.
- `session-notify.zsh` receives Codex's completion notification and writes the conversation ID and turn ID to a two-line state file.

The first request starts Codex with `Act as a shell assistant`, followed by any collected shell commands, then the user's question. History and the question are separated by `---`. Later requests reuse the process. If it exits, the next request resumes the saved conversation ID when available.

The completion helper searches Codex's session files for the notified conversation and checks the first metadata record for a CLI source. This filters notifications from internal title generation and subagents. It depends on Codex's rollout filenames and metadata format.

The helper writes an owner-only temporary file and renames it over the state file. The plugin polls for a changed completion token. The state directory is created with `mktemp -d`; the shell-exit hook removes its state file and directory. Zsh owns the child PTY's lifecycle.

## Configuration and terminal handling

The Enter widget reads lines beginning with `@ ` before shell parsing and quotes
the question as one argument. It saves and calls the previous `accept-line`
widget. This follows the prefix-interception approach in
[zsh-ai](https://github.com/matheusml/zsh-ai/blob/main/lib/widget.zsh) and the
binding-preservation approach in
[Zsh-Opencode-Tab](https://github.com/alberti42/Zsh-Opencode-Tab).

Submitted history uses an escaped `\@` command with a shell-quoted argument.
Recalling it executes the original question without another quoting pass.
Continuation prompts retain normal shell parsing. This interception applies to
interactive line editing; calls from scripts use normal shell quoting.
Load after other Enter customizations; keys bound to
widgets that bypass `accept-line` also bypass this interception.

Startup reads `ZSH_CODEX_ASSISTANT_MODEL` and `ZSH_CODEX_ASSISTANT_PROFILE`, adding shell-quoted CLI arguments for nonempty values. An existing process keeps its startup settings.

The plugin overrides Codex's `notify` command with its helper, enables animations, disables raw-output mode, and uses `--no-alt-screen` to retain scrollback. Approval, terminal-title, and TUI notification settings come from Codex configuration.

Prompts are sent as bracketed paste followed by Enter. Ctrl-C is forwarded to the child. Before returning to Zsh, the plugin resets terminal input/display modes. Bells pass through unchanged.

## Checks

```sh
zsh -n zsh-codex-assistant.plugin.zsh
zsh -n session-notify.zsh
git diff --check
```

There is currently no committed automated test suite. Useful regression cases are consecutive questions, restart/resume, cancellation, history ordering, bell forwarding, and unset/empty/quoted model and profile overrides. Stub Codex for transport tests to avoid model requests.

## Known limitations

- Nonblocking `zpty` writes can report success after sending only part of a large prompt. A slow-reader test delivered 11,776 of 200,000 bytes with status 0. Reliable buffered writes are still needed, especially with uncapped history.
- Completion detection accepts any changed turn token. A simulated delayed callback exposed a potential race; an end-to-end reproduction remains unconfirmed.
- A missing or rejected completion callback can leave the plugin waiting. Local slash commands may also produce no completion callback.
- Terminal dimensions are set at startup; resizing is not forwarded.
- Directory synchronization sends `/cd` and the question without waiting for acknowledgment.
- Command history is collected independently of Zsh's saved-history exclusions. It has no secret filtering.
- Session state belongs to one shell. A newly opened shell starts its own conversation.
