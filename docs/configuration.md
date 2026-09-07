# Configuration

Three layers, in increasing order of churn: the voxtype config keys the
installers assert, the environment variables the runtime scripts read, and
the shared vocabulary file.

## The asserted voxtype keys

Both installers run a `get → compare → set` loop over exactly these keys.
Nothing else is touched — voxtype rewrites the whole `config.toml` on every
`config set` and every `voxtype configure` save, so asserting a snapshot
would revert the engine, model, GPU, and OSD choices you make in the TUI
later. That is also why `whisper.model` is deliberately absent: choose it
through the TUI and it survives every re-run.

| Key | macOS | Linux | Why |
|---|---|---|---|
| `hotkey.enabled` / `hotkey.mode` | `true` / `push_to_talk` | same | the whole point |
| `hotkey.key` | `FN` | `RIGHTALT` | fn is free on macOS (no chord modifier: no keypress while held can close a window); Right Alt stays reachable and VAD makes its stray modifier-presses harmless |
| `whisper.language` | `en` | `en` | bilingual values were tried and reverted |
| `text.filter_filler_words` | `true` | same | voxtype's own stripper; free, and still works when the cleanup times out |
| `vad.enabled` / `vad.backend` | `true` / `whisper` | same | Silero VAD rejects silence-only recordings before they reach whisper — the guard that makes stray presses harmless |
| `meeting.enabled` | follows `--with-meeting` | `true` | off when the shim is absent, because a meeting that silently records only your own half is worse than a loud refusal |
| `audio.pause_media` | `false` | `false` | replaced by ducking (below) |
| `audio.duck_media` | — | `true` | lower other streams instead of stopping them: no music bleed into the mic, and a stray chord costs a dip-and-recover rather than a pause/resume |
| `audio.duck_media_volume_percent` | — | `10` | an **amplitude** percent, not the pactl meter number (pactl shows the cube root — 10 lands at −20 dB) |
| `output.notification.on_recording_{start,stop}` | off with the OSD, on without | `false` | with a live OSD panel they are redundant; on Linux Right-Alt chords fired them constantly |
| `osd.enabled` | `false` | `true` | on macOS `false` means "the daemon must not spawn a frontend" — the OSD runs as its own LaunchAgent reading the daemon's socket feed; on Linux the daemon's own OSD is the feedback channel |
| `output.post_process.command` | `~/.local/bin/voxtype-cleanup` | same | the cleanup filter |
| `whisper.initial_prompt` | **generated** | **generated** | built from `[misheard]` in `vocabulary.conf` — see below |

Report-only (rejected by `config set`, so the installers warn instead of
set): `output.post_process.timeout_ms = 60000` — add it under
`[output.post_process]` by hand. It must stay far above the filter's own
ceiling (5 s local, 20 s cloud): the filter falls back to the raw text on
every failure path, and voxtype killing it first would lose that guarantee.

A restart is needed for hotkey changes to take effect, so the installers only
restart the daemon when a key actually changed.

## The cleanup filter

`voxtype-cleanup` reads raw transcription on stdin and writes cleaned text on
stdout. **The one rule: never lose the user's words.** Every failure path —
backend down, timeout, non-zero exit, empty answer, an answer that grew,
shrank, or dropped content words — prints the original text unchanged. Three
structural guards enforce it after the model answers (length growth cap,
length shrink floor, content-word survival), plus a token budget of ~2 tokens
per spoken word before the call.

### Backends

`VOXTYPE_CLEANUP_BACKEND` selects one of five:

| Backend | What it is | Latency character |
|---|---|---|
| `local` (default) | llama.cpp on `127.0.0.1:8088` holding Qwen3-4B resident | ~0.1–0.4 s; the reason this design exists |
| `claude` | `claude -p` (Haiku by default) | 5–30 s and high variance; explicit choice, never a fallback |
| `codex` | `codex exec` one-shot | same; sandboxed read-only |
| `openai` | any OpenAI-compatible endpoint | whatever the endpoint costs |
| `off` | passthrough | ~0 ms |

The fallback is **always the raw text** — falling back from a 5 s local
timeout to a 20 s cloud call would re-import the latency the local backend
exists to remove.

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
| `VOXTYPE_CLEANUP_NOTIFY_AFTER` | 1200 ms | progress toast appears only past this wait |
| `VOXTYPE_CLEANUP_CONTEXT` | — | extra context appended to the system prompt (see below) |
| `VOXTYPE_CONTEXT_LOCAL_ONLY` | `1` | drop the context on cloud backends |

`voxtype-meeting summarize` adds `VOXTYPE_MEETING_SUMMARY_{BACKEND,ENDPOINT,
MODEL,TIMEOUT,CHUNK_WORDS,CODEX_PROFILE}` with the same local-first,
cloud-only-by-choice shape.

## Where the vocabulary lives

**One file: `vocabulary.conf`, installed to `~/.config/voxtype/`.** A
technical term is typed there once and nowhere else — never into an installer
and never into a prompt. Two consumers read it through one parser
(`voxtype-vocab`), and they are **not interchangeable**:

- `[misheard]` → `whisper.initial_prompt`, written by the installer. An
  initial prompt is capped (whisper.cpp truncates silently) and, on
  near-silent audio, whisper's failure mode is to **echo it back as if it had
  been spoken** — so every term there is damage the day VAD misses one. This
  list is kept short on purpose; a guard warns past 40 terms.
- `[misheard]` + `[misspelled]` → the "Prefer these spellings" rule in
  voxtype-cleanup's system prompt, appended at dictation time. Uncapped, no
  echo risk, and stable between dictations so it stays inside llama.cpp's
  cached prompt prefix.

Default to `[misspelled]` (whisper hears it right and writes it wrong —
"pytorch"); promote a term to `[misheard]` only after watching whisper turn
it into *different words* ("butter FS" for btrfs). After editing, re-run the
installer for the host to push the `[misheard]` half into
`whisper.initial_prompt`; the cleanup half goes live the moment the file is
saved.

Per-project terms do not belong in this file at all — use
`VOXTYPE_CLEANUP_CONTEXT`.
