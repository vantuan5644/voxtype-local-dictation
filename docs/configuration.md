# Configuration

Three layers, in increasing order of churn: the voxtype config keys the
installers assert, the environment variables the runtime scripts read, and
the shared vocabulary file.

## The asserted voxtype keys

Both installers run a `get → compare → set` loop over exactly these keys.
Nothing else is touched, because voxtype rewrites the whole `config.toml` on
every `config set` and every `voxtype configure` save, so asserting a snapshot
would revert the engine, model, GPU, and OSD choices you make in the TUI
later. That is also why `whisper.model` is deliberately absent: choose it
through the TUI and it survives every re-run.

| Key | macOS | Linux | Why |
|---|---|---|---|
| `hotkey.enabled` / `hotkey.mode` | `true` / `push_to_talk` | same | the whole point |
| `hotkey.key` | `FN` | `RIGHTALT` | fn is free on macOS (no chord modifier: no keypress while held can close a window); Right Alt stays reachable and VAD makes its stray modifier-presses harmless |
| `whisper.language` | `en` | `en` | bilingual values were tried and reverted |
| `text.filter_filler_words` | `true` | same | voxtype's own stripper; free, and still works when the cleanup times out |
| `vad.enabled` / `vad.backend` | `true` / `whisper` | same | Silero VAD rejects silence-only recordings before they reach whisper, the guard that makes stray presses harmless |
| `meeting.enabled` | follows `--with-meeting` | `true` | off when the shim is absent, because a meeting that silently records only your own half is worse than a loud refusal |
| `audio.pause_media` | `false` | `false` | replaced by ducking (below) |
| `audio.duck_media` | — | `true` | lower other streams instead of stopping them: no music bleed into the mic, and a stray chord costs a dip-and-recover rather than a pause/resume |
| `audio.duck_media_volume_percent` | — | `10` | an **amplitude** percent, not the pactl meter number (pactl shows the cube root, so 10 lands at −20 dB) |
| `output.notification.on_recording_{start,stop}` | off with the OSD, on without | `false` | with a live OSD panel they are redundant; on Linux Right-Alt chords fired them constantly |
| `osd.enabled` | `false` | `true` | on macOS `false` means "the daemon must not spawn a frontend", and the OSD runs as its own LaunchAgent reading the daemon's socket feed; on Linux the daemon's own OSD is the feedback channel |
| `output.post_process.command` | `~/.local/bin/voxtype-cleanup` | same | the cleanup filter |
| `whisper.initial_prompt` | **generated** | **generated** | built from `[misheard]` in `vocabulary.conf` (see below) |

Report-only (rejected by `config set`, so the installers warn instead of
set): `output.post_process.timeout_ms = 60000`. Add it under
`[output.post_process]` by hand. It must stay far above the filter's own
ceiling (5 s local, 20 s cloud): the filter falls back to the raw text on
every failure path, and voxtype killing it first would lose that guarantee.

A restart is needed for hotkey changes to take effect, so the installers only
restart the daemon when a key actually changed.

## The cleanup filter

`voxtype-cleanup` reads raw transcription on stdin and writes cleaned text on
stdout. **The one rule: never lose the user's words.** Every failure path
prints the original text unchanged: backend down, timeout, non-zero exit, empty
answer, an answer that grew, shrank, or dropped content words. Three
structural guards enforce it after the model answers (length growth cap,
length shrink floor, content-word survival), plus a token budget of ~2 tokens
per spoken word before the call.

### Backends

`VOXTYPE_CLEANUP_BACKEND` selects one of five:

| Backend | What it is | Latency character |
|---|---|---|
| `local` (default) | llama.cpp on `127.0.0.1:8088` holding Qwen3-4B resident | ~145 ms p50 on a desktop GPU, ~950 ms on an M1 Pro; the reason this design exists |
| `claude` | `claude -p` (Haiku by default) | 5 to 30 s and high variance; explicit choice, never a fallback |
| `codex` | `codex exec` one-shot | same; sandboxed read-only |
| `openai` | any OpenAI-compatible endpoint | whatever the endpoint costs |
| `off` | passthrough | ~0 ms |

The fallback is **always the raw text**. Falling back from a 5 s local timeout
to a 20 s cloud call would re-import the latency the local backend exists to
remove.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `VOXTYPE_CLEANUP_BACKEND` | `local` | see table above |
| `VOXTYPE_CLEANUP_ENDPOINT` | `http://127.0.0.1:8088` | base URL for `local`/`openai` |
| `VOXTYPE_CLEANUP_LOCAL_MODEL` | `qwen3-4b-instruct-2507` | the alias llama-server was started with |
| `VOXTYPE_CLEANUP_MODEL` | `haiku` / `gpt-4o-mini` | cloud model name |
| `VOXTYPE_CLEANUP_API_KEY` | — | bearer token for the `openai` backend |
| `VOXTYPE_CLEANUP_CODEX_PROFILE` | `luna` | codex profile |
| `VOXTYPE_CLEANUP_MIN_WORDS` | 3 local / 6 cloud | below this, pass through untouched |
| `VOXTYPE_CLEANUP_TIMEOUT` | 5 s local / 20 s cloud | per-call ceiling |
| `VOXTYPE_CLEANUP_MAX_GROWTH` | 3 | cleaned/raw length ratio that means the model editorialised |
| `VOXTYPE_CLEANUP_MIN_SHRINK` | 55 % local / 45 % cloud | floor the cleaned text must keep |
| `VOXTYPE_CLEANUP_KEEP_WORDS` | 70 | % of raw content words that must survive |
| `VOXTYPE_CLEANUP_MAX_NEW_WORDS` | 0 | words the answer may have that the raw text did not |
| `VOXTYPE_CLEANUP_NOTIFY_AFTER` | 1200 ms | progress toast appears only past this wait |
| `VOXTYPE_CLEANUP_CONTEXT` | — | extra context appended to the system prompt (see below) |
| `VOXTYPE_CONTEXT_LOCAL_ONLY` | `1` | drop the context on cloud backends |

### Meeting summaries

`voxtype-meeting summarize` defaults the *other* way round from the dictation
filter, because a transcript is a far heavier job than a dictation. Its
backend is an ordered chain, tried left to right, first valid JSON wins.

| variable | default | |
|---|---|---|
| `VOXTYPE_MEETING_SUMMARY_BACKEND` | `codex,claude,local` | ordered chain, or `off` |
| `VOXTYPE_MEETING_SUMMARY_ENDPOINT` | `http://127.0.0.1:8088` | base URL for the `local` link |
| `VOXTYPE_MEETING_SUMMARY_LOCAL_MODEL` | `qwen3-4b-instruct-2507` | alias llama-server was started with |
| `VOXTYPE_MEETING_SUMMARY_CLAUDE_MODEL` | `sonnet` | model for the `claude` link |
| `VOXTYPE_MEETING_SUMMARY_TIMEOUT` | 120 s local / 300 s cloud | per call |
| `VOXTYPE_MEETING_SUMMARY_CHUNK_WORDS` | 1400 | ~2,000 tokens, sized to `--ctx-size 4096` |
| `VOXTYPE_MEETING_SUMMARY_CODEX_PROFILE` | `luna` | profile for the `codex` link |
| `VOXTYPE_MEETING_SUMMARY_MODEL` | — | back-compat; honoured only for a one-link chain |

**`local` may only be the last link.** `local,claude` is refused, so a local
server that is merely down can never escalate a transcript onto the network —
the chain falls back toward the machine and never away from it.

Set `VOXTYPE_MEETING_SUMMARY_BACKEND=local` to keep a meeting entirely
offline. A single value means that one backend with no catch behind it, which
is exactly what the variable meant before chains existed.

## Where the vocabulary lives

**One file: `vocabulary.conf`, installed to `~/.config/voxtype/`.** A
technical term is typed there once and nowhere else, never into an installer
and never into a prompt. Two consumers read it through one parser
(`voxtype-vocab`), and they are **not interchangeable**:

- `[misheard]` → `whisper.initial_prompt`, written by the installer. An
  initial prompt is capped (whisper.cpp truncates silently) and, on
  near-silent audio, whisper's failure mode is to **echo it back as if it had
  been spoken**, so every term there is damage the day VAD misses one. This
  list is kept short on purpose; a guard warns past 40 terms.
- `[misheard]` + `[misspelled]` → the "Prefer these spellings" rule in
  voxtype-cleanup's system prompt, appended at dictation time. Uncapped, no
  echo risk, and stable between dictations so it stays inside llama.cpp's
  cached prompt prefix.

Default to `[misspelled]` (whisper hears it right and writes it wrong, as with
"pytorch"); promote a term to `[misheard]` only after watching whisper turn
it into *different words* ("butter FS" for btrfs).

### Adding a term

`voxtype-vocab` is both the parser and the maintenance command:

```bash
voxtype-vocab add btrfs        # -> [misspelled], then applies
voxtype-vocab add -m Hyprland  # -> [misheard] instead
voxtype-vocab add -n foo bar   # several terms, skip the apply
voxtype-vocab edit             # $EDITOR on the source, applies if it changed
voxtype-vocab apply            # just re-apply
voxtype-vocab list             # both sections, with counts and resolved paths
voxtype-vocab path             # where the source is, and how apply runs
```

It edits the **source** copy in the checkout, not the installed
`~/.config/voxtype/vocabulary.conf`. That distinction is the reason the command
exists: editing the installed copy looks like it works, because the cleanup
filter re-reads it on the very next dictation, and is then silently reverted
the next time the installer runs. Duplicates are refused case-insensitively,
and the 40-term `[misheard]` warning fires as you spend the budget.

Applying is still "re-run the installer for this host" — the installer records
which one, and where the source lives, in
`~/.config/voxtype/vocab-source.conf` as it installs. `voxtype-vocab path`
prints what it resolved; `VOXTYPE_VOCAB_SOURCE` and `VOXTYPE_VOCAB_APPLY`
override it. Nothing host-specific is baked into the script, so the same one
works on Omarchy (`apply.sh --only voxtype`), Linux and macOS.

Doing it by hand is unchanged: edit the checkout's `vocabulary.conf` and re-run
the installer. The `[misheard]` half needs that re-run to reach
`whisper.initial_prompt`; the cleanup half goes live the moment the file is
saved.

Per-project terms do not belong in this file at all; use
`VOXTYPE_CLEANUP_CONTEXT`.
