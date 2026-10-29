#!/usr/bin/env bash
#
# Offline tests for voxtype-cleanup. The guards replay cleanup-cases.json, the
# answers every port must give, the local, opencode, anthropic, groq and pi backends are
# checked for sending what cleanup.json says, and each dictation is handed to a
# registered history inbox, and a timed test says what happened. A stand-in
# curl and pi on PATH answer for llama-server, OpenCode Go, Groq and pi, so nothing
# leaves the machine and no model is needed.
# Needs bash, jq and awk. Exit status 0 when every check passes.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -P "$HERE/../.." && pwd)"
RULES="$ROOT/cleanup.json"
CASES="$ROOT/cleanup-cases.json"
# The filter sits beside tests/ in the release repo, and where install.sh looks
# for it in the monorepo it is developed in.
CLEANUP="$HERE/../voxtype-cleanup"
[[ -f $CLEANUP ]] || CLEANUP="$(cd -P "$ROOT/../.." && pwd)/omarchy/files/home/local/bin/voxtype-cleanup"

# The caller's own tunables must not move a limit under test.
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep '^VOXTYPE_')

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
# llama-server: /health answers unless STUB_HEALTH=down; a completion is kept
# and answered with STUB_ANSWER. OpenCode Go: the same, as a message after a
# thinking block, with the headers and arguments kept too, and STUB_PLACEMENT
# as its Cf-Placement. The answer goes to -o's file when there is one, as curl
# does, and STUB_STATUS=fail fails a call once it is sent, with STUB_HTTP as
# the status line it dumps.
printf '%s\0' "$@" >"$STUB_DIR/curl-args"
: >"$STUB_DIR/headers"
out='' dump='' url=''
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) dump="$2"; shift ;;
    -H) if [[ $2 == @* ]]; then cat "${2#@}" >>"$STUB_DIR/headers"; else printf '%s\n' "$2" >>"$STUB_DIR/headers"; fi
        shift ;;
    -A|--connect-timeout|--max-time|--data-binary) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in
  */health) [[ ${STUB_HEALTH:-} != down ]] || exit 7; exit 0 ;;
  */v1/responses)
    body="$(jq -cn --arg answer "$STUB_ANSWER" --arg status "${STUB_RESPONSE_STATUS:-completed}"       '{status: $status, output: [{type: "reasoning", content: []}, {type: "message", content: [{type: "output_text", text: $answer}]}], usage: {input_tokens: 700, output_tokens: 18}}')" ;;
  */v1/chat/completions)
    body="$(jq -cn --arg answer "$STUB_ANSWER" '{choices: [{message: {content: $answer}}],
      usage: {prompt_tokens: 700, completion_tokens: 18}, timings: {prompt_ms: 12.5, predicted_ms: 80}}')" ;;
  */v1/messages)
    body="$(jq -cn --arg answer "$STUB_ANSWER" '{content: [{type: "thinking", thinking: "Not the answer."},
      {type: "text", text: $answer}], usage: {input_tokens: 791, output_tokens: 18}}')"
    if [[ -n $dump ]]; then
      { printf 'HTTP/2 200\r\ncontent-type: application/json\r\n'
        [[ -z ${STUB_PLACEMENT:-} ]] || printf 'cf-placement: %s\r\n' "$STUB_PLACEMENT"
        printf '\r\n'; } >"$dump"
    fi ;;
  *) exit 7 ;;
esac
cat >"$STUB_DIR/request.json"
if [[ ${STUB_STATUS:-} == fail ]]; then
  [[ -z $dump || -z ${STUB_HTTP:-} ]] || printf 'HTTP/2 %s\r\n\r\n' "$STUB_HTTP" >"$dump"
  exit 22
fi
if [[ -n $out ]]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
EOF
cat >"$work/bin/pi" <<'EOF'
#!/usr/bin/env bash
cat >"$STUB_DIR/pi-stdin"
printf '%s\0' "$@" >"$STUB_DIR/pi-args"
printf '%s' "$STUB_ANSWER"
EOF
# The notifier keeps each call, one argument per line, and answers with id 7.
# systemctl: llama-server is installed unless STUB_UNIT=none, and a start is kept.
cat >"$work/bin/notify" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; printf -- '--\n'; } >>"$STUB_DIR/notified"
printf '7'
STUB
cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$2" in
  cat) [[ ${STUB_UNIT:-} != none ]] ;;
  start) printf '%s\n' "$3" >>"$STUB_DIR/started" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/curl" "$work/bin/pi" "$work/bin/notify" "$work/bin/systemctl"

# A native Windows jq writes CRLF; these checks compare text.
jqt() { jq "$@" | tr -d '\r'; }

# run_cleanup <backend> <raw> <answer> [rules file] [arguments]
# Its own data directory, so a dictation never reaches this machine's history,
# and its own pi folder and runtime directory, so this machine's key is never read.
run_cleanup() {
  rm -f "$work/request.json" "$work/pi-stdin" "$work/pi-args" "$work/curl-args" "$work/headers"
  printf '%s' "$2" | PATH="$work/bin:$PATH" STUB_DIR="$work" STUB_ANSWER="$3" \
    VOXTYPE_DATA_ROOT="$work/data" PI_CODING_AGENT_DIR="$work/pi-agent" XDG_RUNTIME_DIR="$work" \
    VOXTYPE_CLEANUP_BACKEND="$1" VOXTYPE_CLEANUP_FILE="${4-$RULES}" \
    VOXTYPE_CLEANUP_NOTIFY_AFTER=60000 VOXTYPE_CLEANUP_NOTIFIER="$work/bin/notify" \
    bash "$CLEANUP" "${@:5}" 2>"$work/stderr"
}

passed=0 failed=0
check() { # check <name> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n  expected: <%s>\n  actual:   <%s>\n' "$1" "$2" "$3"
  fi
}

# --- the shared cases ----------------------------------------------------------
count="$(jqt '.cases | length' "$CASES")"
(( count >= 12 )) || check 'cleanup-cases.json holds every case' '12 or more' "$count"
while IFS= read -r -d '' name && IFS= read -r -d '' link && IFS= read -r -d '' raw &&
      IFS= read -r -d '' cleaned && IFS= read -r -d '' expect; do
  check "case: $name" "$expect" "$(run_cleanup "$link" "$raw" "$cleaned")"
done < <(jq -j '.cases[] | .name, "\u0000", .link, "\u0000", .raw, "\u0000", .cleaned, "\u0000",
                .expect, "\u0000"' "$CASES")

# --- what the local server is sent -------------------------------------------------
raw='um so can you check the tailscale status on the mini pc you know'
answer='So can you check the Tailscale status on the mini PC?'
check 'local answer typed' "$answer" "$(run_cleanup local "$raw" "$answer")"
sent="$work/request.json"
if [[ -f $sent ]]; then
  check 'local request starts with the instructions' true \
    "$(jqt --slurpfile r "$RULES" '.messages[0].content | startswith($r[0].instructions | join("\n"))' "$sent")"
  check 'local request carries every example' "$(jqt '2 + 2 * (.examples | length)' "$RULES")" \
    "$(jqt '.messages | length' "$sent")"
  check 'local request wraps an example' \
    "$(jqt -r '.transcript | split("{text}") | join("um so can you check the uh tailscale status on the mini pc you know")' "$RULES")" \
    "$(jqt -r '.messages[1].content' "$sent")"
  check 'local request wraps the dictation' "$(printf '<transcript>\n%s\n</transcript>' "$raw")" \
    "$(jqt -r '.messages[-1].content' "$sent")"
  check 'local request token budget' \
    "$(jqt --argjson n "$(wc -w <<<"$raw")" '$n * .request.max_tokens_per_word + .request.max_tokens_extra' "$RULES")" \
    "$(jqt '.max_tokens' "$sent")"
  check 'local request sampling' "$(jqt -c '[.request.temperature, .request.top_p]' "$RULES")" \
    "$(jqt -c '[.temperature, .top_p]' "$sent")"
  check 'local request keeps its cache' true "$(jqt '.cache_prompt' "$sent")"
else
  check 'local request sent' 'a request' 'none'
fi

# --- what pi is sent -------------------------------------------------------------
check 'pi answer typed' "$answer" "$(run_cleanup pi "$raw" "$answer")"
if [[ -f $work/pi-args ]]; then
  check 'pi gets the dictation on stdin' "$(printf '<transcript>\n%s\n</transcript>' "$raw")" \
    "$(cat "$work/pi-stdin")"
  mapfile -d '' args <"$work/pi-args"
  prompt=''
  for i in "${!args[@]}"; do
    [[ ${args[i]} == --system-prompt ]] && prompt="${args[i + 1]}"
  done
  first="$(jqt -r '.examples[0] | "Input:\n<transcript>\n\(.raw)\n</transcript>\nOutput:\n\(.cleaned)"' "$RULES")"
  check 'pi prompt lists the examples' yes \
    "$([[ $prompt == *$'\n\nExamples:\n\n'"$first"* ]] && echo yes || echo no)"
  check 'pi prompt starts with the instructions' yes \
    "$([[ $prompt == "$(jqt -r '.instructions | join("\n")' "$RULES")"* ]] && echo yes || echo no)"
else
  check 'pi called' 'a call' 'none'
fi

# --- what OpenCode Go is sent ----------------------------------------------------
check 'opencode without a key types the text' "$raw" "$(run_cleanup opencode "$raw" "$answer")"
check 'opencode without a key sends nothing' no "$([[ -f $work/request.json ]] && echo yes || echo no)"
mkdir -p "$work/pi-agent"
printf '{"opencode-go": {"type": "api_key", "key": "from-pi"}}' >"$work/pi-agent/auth.json"
check 'opencode answer typed' "$answer" "$(run_cleanup opencode "$raw" "$answer")"
if [[ -f $work/request.json ]]; then
  check "opencode reads pi's key" 'x-api-key: from-pi' "$(grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
  check 'opencode keeps the key out of argv' no "$(grep -q from-pi "$work/curl-args" && echo yes || echo no)"
  check 'opencode names itself' voxtype-cleanup/1.0 \
    "$(mapfile -d '' a <"$work/curl-args"; for i in "${!a[@]}"; do [[ ${a[i]} == -A ]] && printf '%s' "${a[i + 1]}"; done)"
  session="$(grep -i '^x-opencode-session:' "$work/headers" | sed 's/^[^:]*: //')"
  check 'opencode session ID' yes "$([[ $session =~ ^voxtype-[0-9a-f]{32}$ ]] && echo yes || echo no)"
  run_cleanup opencode "$raw" "$answer" >/dev/null
  check 'opencode keeps its session ID' "$session" \
    "$(grep -i '^x-opencode-session:' "$work/headers" | sed 's/^[^:]*: //')"
  check 'opencode model' qwen3.8-flash "$(jqt -r '.model' "$work/request.json")"
  check 'opencode turns thinking off' disabled "$(jqt -r '.thinking.type' "$work/request.json")"
  check 'opencode system prompt apart' true \
    "$(jqt --slurpfile r "$RULES" '(.system | startswith($r[0].instructions | join("\n")))
      and ([.messages[].role] | index("system") == null)' "$work/request.json")"
  check 'opencode carries every example' "$(jqt '1 + 2 * (.examples | length)' "$RULES")" \
    "$(jqt '.messages | length' "$work/request.json")"
  check 'opencode sends no llama.cpp field' null "$(jqt '.cache_prompt' "$work/request.json")"
  check 'opencode token budget has the thinking room' \
    "$(jqt --argjson n "$(wc -w <<<"$raw")" '$n * .request.max_tokens_per_word + .request.max_tokens_extra
      + .request.max_tokens_thinking' "$RULES")" "$(jqt '.max_tokens' "$work/request.json")"
else
  check 'opencode request sent' 'a request' 'none'
fi
check 'opencode prefers its own key' 'x-api-key: own' \
  "$(VOXTYPE_CLEANUP_OPENCODE_KEY=own run_cleanup opencode "$raw" "$answer" >/dev/null
     grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
printf 'from-file\n' >"$work/opencode-key"
check 'opencode key file wins over pi' 'x-api-key: from-file' \
  "$(VOXTYPE_CLEANUP_OPENCODE_KEY_FILE="$work/opencode-key" run_cleanup opencode "$raw" "$answer" >/dev/null
     grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
check 'opencode key variable wins over the file' 'x-api-key: own' \
  "$(VOXTYPE_CLEANUP_OPENCODE_KEY=own VOXTYPE_CLEANUP_OPENCODE_KEY_FILE="$work/opencode-key" \
       run_cleanup opencode "$raw" "$answer" >/dev/null
     grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
check 'opencode missing key file falls back to pi' 'x-api-key: from-pi' \
  "$(VOXTYPE_CLEANUP_OPENCODE_KEY_FILE="$work/none" run_cleanup opencode "$raw" "$answer" >/dev/null
     grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
rm -f "$work/opencode-key"
check 'opencode empty answer types the text' "$raw" "$(run_cleanup opencode "$raw" '')"
check 'opencode failure types the text' "$raw" "$(STUB_STATUS=fail run_cleanup opencode "$raw" "$answer")"

# --- what Anthropic is sent ------------------------------------------------------
# The Messages API as for OpenCode Go, on the user's own key, without the
# temperature and top_p claude-haiku-5-5 refuses, and without thinking room.
printf ' from-file\n' >"$work/anthropic-key"
check 'anthropic without a key types the text' "$raw" "$(run_cleanup anthropic "$raw" "$answer")"
check 'anthropic without a key sends nothing' no "$([[ -f $work/request.json ]] && echo yes || echo no)"
check 'anthropic answer typed' "$answer" \
  "$(VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE="$work/anthropic-key" run_cleanup anthropic "$raw" "$answer")"
if [[ -f $work/request.json ]]; then
  check 'anthropic reads the key from its file' 'x-api-key: from-file' \
    "$(grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
  check 'anthropic keeps the key out of argv' no "$(grep -q from-file "$work/curl-args" && echo yes || echo no)"
  check 'anthropic names its API version' 'anthropic-version: 2023-06-01' \
    "$(grep -i '^anthropic-version:' "$work/headers" | tr -d '\r')"
  check 'anthropic is sent no OpenCode Go session' '' "$(grep -i '^x-opencode-session:' "$work/headers")"
  check 'anthropic goes to Anthropic' yes \
    "$(tr '\0' '\n' <"$work/curl-args" | grep -qx 'https://api.anthropic.com/v1/messages' && echo yes || echo no)"
  check 'anthropic model' claude-haiku-5-5 "$(jqt -r '.model' "$work/request.json")"
  check 'anthropic turns thinking off' disabled "$(jqt -r '.thinking.type' "$work/request.json")"
  check 'anthropic sends no temperature, top_p or llama.cpp field' '[null,null,null]' \
    "$(jqt -c '[.temperature, .top_p, .cache_prompt]' "$work/request.json")"
  check 'anthropic system prompt apart' true \
    "$(jqt --slurpfile r "$RULES" '(.system | startswith($r[0].instructions | join("\n")))
        and ([.messages[] | select(.role == "system")] | length == 0)' "$work/request.json")"
  check 'anthropic carries every example' "$(jqt '1 + 2 * (.examples | length)' "$RULES")" \
    "$(jqt '.messages | length' "$work/request.json")"
  check 'anthropic token budget has no thinking room' \
    "$(jqt --argjson n "$(wc -w <<<"$raw")" '$n * .request.max_tokens_per_word + .request.max_tokens_extra' \
      "$RULES")" "$(jqt '.max_tokens' "$work/request.json")"
else
  check 'anthropic request sent' 'a request' 'none'
fi
check 'anthropic key variable wins over the file' 'x-api-key: own' \
  "$(VOXTYPE_CLEANUP_ANTHROPIC_KEY=own VOXTYPE_CLEANUP_ANTHROPIC_KEY_FILE="$work/anthropic-key" \
       run_cleanup anthropic "$raw" "$answer" >/dev/null
     grep -i '^x-api-key:' "$work/headers" | tr -d '\r')"
check "anthropic never takes pi's OpenCode Go key" "$raw" "$(run_cleanup anthropic "$raw" "$answer")"
check 'anthropic failure types the text' "$raw" \
  "$(STUB_STATUS=fail VOXTYPE_CLEANUP_ANTHROPIC_KEY=own run_cleanup anthropic "$raw" "$answer")"
rm -f "$work/anthropic-key"

# --- what Groq is sent -----------------------------------------------------------
printf 'sk-openai-fixture\n' >"$work/openai-key"
check 'openai answer typed' "$answer" \
  "$(VOXTYPE_CLEANUP_OPENAI_KEY_FILE="$work/openai-key" run_cleanup openai "$raw" "$answer")"
check 'openai endpoint uses Responses' yes "$(grep -q 'https://api.openai.com/v1/responses' "$work/curl-args" && echo yes || echo no)"
check 'openai storage disabled' false "$(jqt -r .store "$work/request.json")"
check 'openai default model' gpt-6-luna "$(jqt -r .model "$work/request.json")"
check 'openai no sampling parameters' '[null,null]' "$(jqt -c '[.temperature,.top_p]' "$work/request.json")"
check 'openai keeps key out of argv' no "$(grep -q sk-openai-fixture "$work/curl-args" && echo yes || echo no)"
check 'openai incomplete answer keeps raw text' "$raw" \
  "$(STUB_RESPONSE_STATUS=incomplete VOXTYPE_CLEANUP_OPENAI_KEY_FILE="$work/openai-key" run_cleanup openai "$raw" "$answer")"
check 'openai no key keeps raw text' "$raw" "$(run_cleanup openai "$raw" "$answer")"

printf '  from-file\n' >"$work/groq-key"
check 'groq without a key types the text' "$raw" "$(run_cleanup groq "$raw" "$answer")"
check 'groq without a key sends nothing' no "$([[ -f $work/request.json ]] && echo yes || echo no)"
check 'groq answer typed' "$answer" \
  "$(VOXTYPE_CLEANUP_GROQ_KEY_FILE="$work/groq-key" run_cleanup groq "$raw" "$answer")"
if [[ -f $work/request.json ]]; then
  check 'groq reads the key from its file' 'Authorization: Bearer from-file' \
    "$(grep -i '^authorization:' "$work/headers" | tr -d '\r')"
  check 'groq keeps the key out of argv' no "$(grep -q from-file "$work/curl-args" && echo yes || echo no)"
  check 'groq model' openai/gpt-oss-20b "$(jqt -r '.model' "$work/request.json")"
  check 'groq reasons at low effort' low "$(jqt -r '.reasoning_effort' "$work/request.json")"
  check 'groq starts with the instructions' true \
    "$(jqt --slurpfile r "$RULES" '.messages[0] | .role == "system" and
        (.content | startswith($r[0].instructions | join("\n")))' "$work/request.json")"
  check 'groq carries every example' "$(jqt '2 + 2 * (.examples | length)' "$RULES")" \
    "$(jqt '.messages | length' "$work/request.json")"
  check 'groq token budget has the thinking room' \
    "$(jqt --argjson n "$(wc -w <<<"$raw")" \
      '$n * .request.max_tokens_per_word + .request.max_tokens_extra + .request.max_tokens_thinking' "$RULES")" \
    "$(jqt '.max_completion_tokens' "$work/request.json")"
  check 'groq sends no max_tokens or llama.cpp field' '[null,null]' \
    "$(jqt -c '[.max_tokens, .cache_prompt]' "$work/request.json")"
else
  check 'groq request sent' 'a request' 'none'
fi
check 'groq prefers its own key' 'Authorization: Bearer own' \
  "$(VOXTYPE_CLEANUP_GROQ_KEY=own VOXTYPE_CLEANUP_GROQ_KEY_FILE="$work/groq-key" \
      run_cleanup groq "$raw" "$answer" >/dev/null
    grep -i '^authorization:' "$work/headers" | tr -d '\r')"
check 'groq failure types the text' "$raw" \
  "$(STUB_STATUS=fail VOXTYPE_CLEANUP_GROQ_KEY=own run_cleanup groq "$raw" "$answer")"

# --- the recorded choice ---------------------------------------------------------
# Without the variable, the first link of the data root's cleanup-backend.
mkdir -p "$work/data"
printf ' Groq , local\r\n' >"$work/data/cleanup-backend"
check 'the recorded choice is used' "$answer" \
  "$(VOXTYPE_CLEANUP_GROQ_KEY=own run_cleanup '' "$raw" "$answer")"
check 'its first link answers' 'Authorization: Bearer own' \
  "$(grep -i '^authorization:' "$work/headers" | tr -d '\r')"
check 'the variable comes first' 'none' \
  "$(VOXTYPE_CLEANUP_GROQ_KEY=own run_cleanup local "$raw" "$answer" >/dev/null
    grep -i '^authorization:' "$work/headers" || echo none)"
printf 'off' >"$work/data/cleanup-backend"
check 'a recorded off types the text' "$raw" "$(run_cleanup '' "$raw" "$answer")"
rm -f "$work/data/cleanup-backend"
check 'no choice is local' "$answer" "$(run_cleanup '' "$raw" "$answer")"
check 'no choice sends to the local server' true \
  "$(jqt '.cache_prompt' "$work/request.json" 2>/dev/null)"

# --- a timed test ----------------------------------------------------------------
timing="$work/timing.json"
timed() { VOXTYPE_CLEANUP_TIMING_FILE="$timing" run_cleanup "$@"; }
names() { jqt -r '[.marks[].name] | join(" ")' "$timing"; }
rm -f "$timing"
check 'timed: the text is typed' "$answer" "$(timed opencode "$raw" "$answer")"
check 'timed: opencode answered' opencode "$(jqt -r .link "$timing")"
check 'timed: changed' changed "$(jqt -r .outcome "$timing")"
check 'timed: the steps' 'began rules opencode:answered opencode:guarded done' "$(names)"
check 'timed: marks go forward' true "$(jqt '[.marks[].at] | . == sort and all(. > 1700000000000000)' "$timing")"
check 'timed: tokens in' 791 "$(jqt -r .server.usage.input_tokens "$timing")"
check 'timed: no placement, no served_from' false "$(jqt '.server | has("served_from")' "$timing")"
STUB_PLACEMENT=remote-DUB timed opencode "$raw" "$answer" >/dev/null
check 'timed: served from' remote-DUB "$(jqt -r .server.served_from "$timing")"
mv "$work/pi-agent/auth.json" "$work/pi-agent/auth.json.off"
timed opencode "$raw" "$answer" >/dev/null
check 'timed: no key says so' 'kept|opencode: no OpenCode Go key' \
  "$(jqt -r '.outcome + "|" + (.why | join("; "))' "$timing")"
timed groq "$raw" "$answer" >/dev/null
check 'timed: no Groq key says so' 'kept|groq: no Groq key' \
  "$(jqt -r '.outcome + "|" + (.why | join("; "))' "$timing")"
VOXTYPE_CLEANUP_GROQ_KEY=own timed groq "$raw" "$answer" >/dev/null
check 'timed groq: the steps' 'began rules groq:answered groq:guarded done' "$(names)"
check 'timed groq: tokens in' 700 "$(jqt -r .server.usage.prompt_tokens "$timing")"
mv "$work/pi-agent/auth.json.off" "$work/pi-agent/auth.json"
timed local "$raw" "$answer" >/dev/null
check 'timed local: the steps' 'began rules local:checked local:answered local:guarded done' "$(names)"
check "timed local: llama.cpp's own timings" 80 "$(jqt -r .server.timings.predicted_ms "$timing")"
check 'timed: unchanged' unchanged "$(timed local "$answer" "$answer" >/dev/null; jqt -r .outcome "$timing")"
STUB_HEALTH=down timed local "$raw" "$answer" >/dev/null
check 'timed: kept, the server is down' 'kept|local: the server is not running' \
  "$(jqt -r '.outcome + "|" + (.why | join("; "))' "$timing")"
timed local "$raw" 'Hello.' >/dev/null
check 'timed: kept, a guard said why' 'kept|local: the answer shrank too far|null' \
  "$(jqt -r '.outcome + "|" + (.why | join("; ")) + "|" + (.link | tostring)' "$timing")"
check 'timed: the guards were timed' 'began rules local:checked local:answered local:guarded done' "$(names)"
STUB_STATUS=fail timed local "$raw" "$answer" >/dev/null
check 'timed: kept, the call failed' 'local: the call failed (22)' "$(jqt -r '.why | join("; ")' "$timing")"
check 'timed: a failure is marked' 'began rules local:checked local:failed done' "$(names)"
timed off "$raw" "$answer" >/dev/null
check 'timed: off' 'kept|cleanup is off' "$(jqt -r '.outcome + "|" + (.why | join("; "))' "$timing")"
timed local 'restart it' "$answer" >/dev/null
check 'timed: too short to send' short "$(jqt -r .outcome "$timing")"
rm -f "$timing"
run_cleanup local "$raw" "$answer" >/dev/null
check 'untimed: no timing file' no "$([[ -e $timing ]] && echo yes || echo no)"

# --- when cleanup is down --------------------------------------------------------
# Said once per reason, with llama-server offered while it is installed; a
# click (--use-local) starts it, and the switch holds while it answers.
notified() { cat "$work/notified" 2>/dev/null; }
said() { [[ $(notified) == *"$1"* ]] && echo yes || echo no; }
is_on() { [[ -f $work/voxtype-cleanup-local ]] && echo yes || echo no; }
rm -f "$work/notified" "$work/voxtype-cleanup-down" "$work/voxtype-cleanup-local" "$work/started"
mv "$work/pi-agent/auth.json" "$work/pi-agent/auth.json.off"
check 'down: the text is typed' "$raw" "$(run_cleanup opencode "$raw" "$answer")"
check 'down: the user is told' yes "$(said 'Dictation cleanup is down')"
check 'down: and why' yes "$(said 'opencode: no OpenCode Go key. Dictations are typed as said.')"
check 'down: llama-server is offered' yes \
  "$(said "$(printf -- '--exec\n%s\n--use-local' "$(realpath "$CLEANUP")")")"
rm -f "$work/notified"
run_cleanup opencode "$raw" "$answer" >/dev/null
check 'down: the same reason is said once' '' "$(notified)"
mv "$work/pi-agent/auth.json.off" "$work/pi-agent/auth.json"
STUB_STATUS=fail STUB_HTTP=401 run_cleanup opencode "$raw" "$answer" >/dev/null
check 'down: a refused key says so' yes "$(said 'opencode: the key was refused (HTTP 401)')"
check 'down: a new reason replaces the last' yes "$(said "$(printf -- '-r\n7')")"
rm -f "$work/notified" "$work/voxtype-cleanup-down"
STUB_STATUS=fail STUB_HTTP=503 VOXTYPE_CLEANUP_GROQ_KEY=own run_cleanup groq "$raw" "$answer" >/dev/null
check 'down: an outage says its status' yes "$(said 'groq: the call failed (HTTP 503)')"
rm -f "$work/notified" "$work/voxtype-cleanup-down"
STUB_UNIT=none STUB_HEALTH=down run_cleanup local "$raw" "$answer" >/dev/null
check 'down: local is said too' yes "$(said 'local: the server is not running')"
check 'down: no llama-server, nothing offered' no "$(said '--exec')"
rm -f "$work/notified" "$work/voxtype-cleanup-down"
run_cleanup local "$raw" 'Hello.' >/dev/null
check 'a guard is not an outage' '' "$(notified)"
check 'a short dictation is not an outage' '' "$(run_cleanup opencode 'do it' 'Do it.' >/dev/null; notified)"
check 'no notifier, still typed' "$raw" \
  "$(STUB_HEALTH=down VOXTYPE_CLEANUP_NOTIFIER='' run_cleanup local "$raw" "$answer")"

rm -f "$work/notified"
run_cleanup '' '' '' "$RULES" --use-local
check 'use-local: it succeeds' 0 "$?"
check 'use-local: llama-server started' llama-server.service "$(cat "$work/started" 2>/dev/null)"
check 'use-local: the switch is on' yes "$(is_on)"
check 'use-local: the user is told' yes "$(said 'Dictation cleanup is local')"
check 'switch: a cloud choice cleans locally' "$answer" "$(run_cleanup opencode "$raw" "$answer")"
check 'switch: on the local server' true "$(jqt '.cache_prompt' "$work/request.json" 2>/dev/null)"
check 'switch: off stays off' "$raw" "$(run_cleanup off "$raw" "$answer")"
STUB_HEALTH=down run_cleanup opencode "$raw" "$answer" >/dev/null
check 'switch: a stopped server ends it' no "$(is_on)"
check 'switch: then the choice applies' qwen3.8-flash "$(jqt -r '.model' "$work/request.json" 2>/dev/null)"
rm -f "$work/notified"
check 'use-local: a server that never answers fails' '1 no' \
  "$(STUB_HEALTH=down VOXTYPE_CLEANUP_LOCAL_WAIT=1 run_cleanup '' '' '' "$RULES" --use-local >/dev/null; echo "$? $(is_on)")"
check 'use-local: and says so' yes "$(said 'llama-server is not answering')"
rm -f "$work/notified" "$work/voxtype-cleanup-down" "$work/voxtype-cleanup-local" "$work/started"

# --- limits and broken rules -----------------------------------------------------
check 'off types the text' "$raw" "$(run_cleanup off "$raw" "$answer")"
check 'short dictation typed as said' 'do it' "$(run_cleanup local 'do it' 'Do it.')"
check 'short dictation not sent' no "$([[ -f $work/request.json ]] && echo yes || echo no)"
check 'environment overrides a limit' "$raw" \
  "$(VOXTYPE_CLEANUP_MIN_WORDS=50 run_cleanup local "$raw" "$answer")"
check 'rules found beside the checkout' "$answer" "$(run_cleanup local "$raw" "$answer" '')"
check 'missing rules type the text' "$raw" "$(run_cleanup local "$raw" "$answer" "$work/none.json")"
check 'missing rules say so' yes "$([[ -s $work/stderr ]] && echo yes || echo no)"
jq '.schema = 2' "$RULES" >"$work/newer.json"
check 'unknown rules type the text' "$raw" "$(run_cleanup local "$raw" "$answer" "$work/newer.json")"
jq '.links.local.min_words = "3"' "$RULES" >"$work/text-limit.json"
check 'a limit that is not a number types the text' "$raw" \
  "$(run_cleanup local "$raw" "$answer" "$work/text-limit.json")"

# --- the handoff to a dictation history ------------------------------------------
inbox="$work/data/inbox"
events() { find "$inbox" -name '*.json' 2>/dev/null | sort; }
run_cleanup local "$raw" "$answer" >/dev/null
check 'no registration, no event' '' "$(events)"
mkdir -p "$work/data"
printf '{"schema": 1, "inbox": "%s"}' "$inbox" >"$work/data/dictation-history.json"
check 'registered: the answer is still typed' "$answer" "$(run_cleanup local "$raw" "$answer")"
event="$(events)"
if [[ -n $event && $event != *$'\n'* ]]; then
  check 'event holds the cleaned text' "$answer" "$(jqt -r .text "$event")"
  check 'event holds the raw text' "$raw" "$(jqt -r .raw_text "$event")"
  check 'event shape' true "$(jqt '.schema == 1 and (.id | test("^[0-9a-f]{32}$"))
    and (.created_at | type == "number" and . > 1700000000)' "$event")"
  check 'event named by its id' "$(jqt -r .id "$event").json" "${event##*/}"
else
  check 'one event per dictation' 'one file' "${event:-none}"
fi
rm -f "$inbox"/*.json
run_cleanup off "$raw" "$answer" >/dev/null
check 'a dictation typed as said is handed over too' "$raw" "$(jqt -r .text "$(events)")"
rm -f "$inbox"/*.json
run_cleanup local '   ' "$answer" >/dev/null
check 'whitespace is no dictation' '' "$(events)"
VOXTYPE_HISTORY_DISABLED=1 run_cleanup local "$raw" "$answer" >/dev/null
check 'history disabled, no event' '' "$(events)"
rm -rf "$inbox"
printf 'occupied' >"$inbox"
check 'storage failure: the text is still typed' "$answer" "$(run_cleanup local "$raw" "$answer")"
check 'storage failure says so' yes "$(grep -q 'could not be saved' "$work/stderr" && echo yes || echo no)"
check 'no partial file left' '' "$(find "$work/data" -name '*.tmp')"

printf '%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
