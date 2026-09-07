# Troubleshooting

The failure modes below are silent by nature: each one presents as something
other than what it is. They are ordered by how often each is reported.

## The grant that stays ticked while failing (macOS)

**Symptom:** dictation types nothing, or the daemon transcribes silence as
"Thank you", while System Settings shows Microphone/Input Monitoring/
Accessibility ticked for Voxtype.

**Cause:** TCC keys a grant to the code's *designated requirement*. An ad-hoc
signature (which `voxtype setup app-bundle` applies every run) has no stable
requirement. Its cdhash changes with every rebuild, and the old grants keep
matching the old cdhash while the checkbox lies. This is why the installer
re-signs the bundle with a stable self-signed certificate.

**Fix:** confirm what the requirement currently is:

```sh
codesign -d -r- /Applications/Voxtype.app   # must name "certificate leaf", not a bare cdhash
```

If it moved (an upstream re-install re-signed ad-hoc behind your back),
re-run the installer, then reset and re-grant per service:

```sh
tccutil reset Accessibility io.voxtype.daemon
tccutil reset ListenEvent   io.voxtype.daemon   # Input Monitoring's real name
tccutil reset Microphone    io.voxtype.daemon
```

## The daemon's PATH

**Symptom (macOS):** every dictation comes back **uncleaned** (disfluencies
intact), silently, forever.

**Cause:** the daemon runs from Login Items, so its PATH is launchd's minimal
`/usr/bin:/bin:/usr/sbin:/sbin`, and Homebrew's `jq` (a filter dependency)
and `~/.local/bin` are invisible to it. The filter's dependency guard fires and
passes the raw text through, which is exactly its designed failure mode.

The installer patches `LSEnvironment.PATH` into the app bundle for exactly
this (and the filter hard-codes the common Homebrew paths), but an inherited
environment can beat `LSEnvironment`: `open -a` propagates the caller's
environment when there is one, so a daemon launched from a terminal can carry
that terminal's PATH instead. Check what the running daemon actually has:

```sh
ps -wwE -o command -p "$(pgrep -x voxtype-bin | head -1)" | tr ' ' '\n' | grep ^PATH=
```

Fix: restart clean with `pkill -x voxtype-bin; env -i /usr/bin/open -a Voxtype`,
or log out and back in (the at-login launch is the clean-environment case by
construction).

**On Linux** the same class of issue exists with the systemd user service:
the filter is resolved by absolute path (`output.post_process.command`), but
anything it shells out to needs the session PATH, which is why the payload
resolves its notifier by absolute path too.

## `VOXTYPE_CONTEXT` is no longer yours

**Symptom:** a per-project vocabulary exported as `VOXTYPE_CONTEXT` has no
effect; or "cleanup got slower" with nothing changed.

**Cause:** newer voxtype builds `env_remove` `VOXTYPE_CONTEXT` and then set it
themselves to the *previous dictation's text*. A value you export never
arrives, and if the filter read it, a string changing every dictation would
invalidate llama.cpp's cached prompt prefix every time.

**Fix:** use `VOXTYPE_CLEANUP_CONTEXT`. The installers check for the old name
in the voxtype binary and warn (`grep -oE 'VOXTYPE_[A-Z_]+'` with a prefix
match, because Rust packs string literals together and the exact-match check
that named this variable wrongly in the first place misses it).

## The tap that returns silence, and noErr (macOS meeting mode)

**Symptom:** a meeting exports with a You section and an empty/garbage Remote
section; `voxtype-loopback-macos --self-test` captures zeros with no error
anywhere.

**Cause:** tccd checks the **responsible app**, `Voxtype.app`, for
`NSAudioCaptureUsageDescription` before allowing a CoreAudio process tap.
Without the key the refusal is silent: `noErr` from every API, then all-zero
buffers. The installer patches the key in and re-signs; running the shim from
a **terminal** reproduces the same silence even with the key present, because
the terminal is the responsible app there and declares nothing.

**Fix:** confirm the key, re-grant, and judge only from a real meeting:

```sh
plutil -extract NSAudioCaptureUsageDescription raw -o - /Applications/Voxtype.app/Contents/Info.plist
tccutil reset AudioCapture io.voxtype.daemon   # then start a meeting: it prompts at AudioDeviceStart
voxtype-meeting start; sleep 5; voxtype-meeting stop
voxtype meeting export latest --speakers       # both You and Remote sections
```

Related tripwire: if the shim is missing from the daemon's PATH,
`loopback_device = "auto"` logs `No monitor source found, using mic only`
and records **your half only**. `voxtype-meeting start` refuses unless the
shim exists, and watches the daemon log for exactly that line for 3 s after
starting, precisely so this cannot be silent.

## Cleanup passes everything through unchanged

**That is the design, not a bug.** The filter's one rule is never to lose the
user's words, so a down/slow/rejecting backend degrades to the raw transcript
(a refused connection costs 1 to 9 ms). To find which layer is degrading:

```sh
curl -sf http://127.0.0.1:8088/health          # the server itself
systemctl --user status llama-server           # Linux
tail ~/Library/Logs/voxtype-llama-server.log   # macOS
VOXTYPE_CLEANUP_MIN_WORDS=1 VOXTYPE_CLEANUP_TIMEOUT=30 bash -c \
  'printf "so um like test" | voxtype-cleanup'
```

On Linux, a `llama-server` that lists GPU devices but refuses every model
with `make_cpu_buft_list: no CPU backend found` is the
[optional-dependency trap](install-linux.md#the-llamacpp-trap); install
`ggml-cpu`.

## Dictation cleanup got slow (Linux)

If nothing changed in the stack, check **which GPU** the model is on:

```sh
systemctl --user status llama-server    # the ExecStartPre guard fires loudly on an enumeration flip
llama-server --list-devices
```

`--device` names by enumeration index; the generated unit's `ExecStartPre`
asserts the index still maps to the vendor seen at install time, so a flip
stops the unit instead of quietly parking the model on an iGPU. Re-run the
installer (or pin `LLAMA_DEVICE`) to re-bake the guard against the new order.

Also on the slow path: the first dictation after a vocabulary edit pays a
full prompt eval (the cached prefix was invalidated once, by design), and a
cold Mesa shader cache costs seconds of Vulkan recompilation after reboot.

## Whisper types vocabulary words nobody said

Near-silent audio plus a long `whisper.initial_prompt` is the recipe: whisper
echoes the prompt back as if spoken. The guards: keep VAD enabled (it rejects
the silence in the first place), keep `[misheard]` short (the installer warns
past 40 terms), and put everything whisper merely *misspells* in
`[misspelled]` instead, where the cleanup model fixes them with neither the
cap nor the echo risk. See
[configuration](configuration.md#where-the-vocabulary-lives).

## The OSD panel is blank or doubled (macOS)

The macOS OSD runs as its **own** LaunchAgent reading the same
`/tmp/voxtype/audio.sock` the daemon binds. `osd.enabled` stays `false`
("the daemon must not spawn a frontend") because the daemon's supervisor
resolves its child inside the sealed app bundle or on a PATH that excludes
`~/.local/bin`. A doubled panel means a second daemon holds the socket:
usually a leftover `voxtype setup launchd` agent racing the Login Item
(check `~/Library/LaunchAgents/io.voxtype.daemon.plist`; the installer warns
about it). A blank panel with notifications also missing means neither
feedback channel is alive; restore them with
`voxtype config set output.notification.on_recording_start true`.
