# Development

## Request flow

1. The Enter widget catches lines starting with `@ ` before Zsh parses them. Other commands run normally and are collected by `preexec`.
2. `@` adds those commands to the question. The first request starts Codex in a `zpty`; later requests go to the same process. If it has exited, the plugin resumes its saved conversation.
3. The plugin forwards Codex's output and the user's keystrokes. A completion callback tells it when to return control to Zsh.
4. On shell exit, the plugin removes its temporary state directory. Each shell has its own Codex session.

`zsh-codex-assistant.plugin.zsh` handles these steps. `session-notify.zsh` handles the callback.

## Completion callback

Codex calls `session-notify.zsh` after a turn. The helper finds that conversation's rollout file and accepts it only when its metadata says `source: cli`. This avoids treating title generation or subagent turns as the user's reply. The helper then writes the conversation ID and turn ID to a private state file using an atomic rename. The plugin waits for the turn ID to change.

This depends on Codex's rollout filenames and metadata format. If the callback never arrives, the plugin waits until interrupted or until Codex exits.

## Terminal behavior

Prompts are sent as bracketed paste. Ctrl-C is forwarded to Codex. The plugin uses `--no-alt-screen` and filters scrollback erase sequences so earlier output remains visible. It resets terminal modes before returning to Zsh.

## Checks

```sh
zsh -n zsh-codex-assistant.plugin.zsh
zsh -n session-notify.zsh
git diff --check
```

These check syntax and whitespace. They do not exercise the live PTY or Codex callback.

## Known limits

- A nonblocking PTY write can report success after sending only part of a large prompt. A slow-reader check delivered 11,776 of 200,000 bytes.
- A delayed callback can be mistaken for the current turn. This was seen in a simulation, not confirmed end to end.
- Local slash commands may produce no completion callback.
- Terminal resize is not forwarded to Codex.
- Directory changes are sent with `/cd` without waiting for acknowledgment.
- Collected shell commands are not filtered for secrets or Zsh history exclusions.
