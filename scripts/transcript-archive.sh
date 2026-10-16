# Claude transcript archive. Sourced by aib.
#
# Claude Code deletes ~/.claude/projects/*/*.jsonl after cleanupPeriodDays (~30 days), so
# the raw conversation behind each curated session record used to vanish. aib keeps a
# private, verified gzip copy outside git plus a metadata-only digest.
#
# Design (council 20261016_140213_79393): the hooks only record intent — Claude Code kills
# a SessionEnd hook after ~0.9s — and a detached worker copies, verifies and digests under
# a per-uuid lock. State lives in one global directory so any barrack's SessionStart can
# retry what an earlier worker could not finish. Nothing here touches session records.
#
# Layout under AIB_ARCHIVE_DIR (0700, files 0600):
#   claude/<uuid>.jsonl.gz            transcript; replaced only when the new copy extends it
#   claude/<uuid>.<sha12>.jsonl.gz    a rewritten (non-prefix) copy, kept beside the old one
#   .state/<uuid>                     key=value: state, src, sids, attempts, last_error, ...
#   .digest/<uuid>.json               metadata only — no prompts, paths, commands or output
#   .lock/<uuid>/pid                  worker lock; reclaimed when the pid is dead
#   .log, .pruned.log

AIB_ARCHIVE_DIR="${AIB_ARCHIVE_DIR:-$HOME/.aib/archive}"
_ARCH_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
_ARCH_PAYLOAD=""
_ARCH_MAX_ATTEMPTS=5

_arch_mkdir() { (umask 077; mkdir -p "$1") 2>/dev/null; }
_arch_sha_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
_arch_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

_arch_projects_dir() {
    local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    [ -d "$base/projects" ] || return 1
    (cd "$base/projects" && pwd -P)
}

# Hook payload (Claude Code passes JSON on stdin). EOF arrives immediately from Claude;
# the timeout only guards manual runs whose stdin never closes.
_arch_read_payload() {
    _ARCH_PAYLOAD=""
    [ -t 0 ] && return 0
    IFS= read -r -d '' -t 1 _ARCH_PAYLOAD || true
    _ARCH_PAYLOAD="${_ARCH_PAYLOAD:0:65536}"
}

# _arch_validate_transcript <path> <uuid>: print the canonical path. Returns 3 when the
# file no longer exists (after the name checks), 1 when it must not be read: not under
# <claude>/projects/<one dir>/, not named <uuid>.jsonl, or a symlink.
_arch_validate_transcript() {
    local p="${1:-}" uuid="${2:-}" proj dir
    case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
    [[ "$uuid" =~ $_ARCH_UUID_RE ]] || return 1
    [[ "$p" == /* ]] || return 1
    [ "${p##*/}" = "${uuid}.jsonl" ] || return 1
    if [ ! -e "$p" ] && [ ! -L "$p" ]; then return 3; fi
    [ -f "$p" ] && [ ! -L "$p" ] || return 1
    proj="$(_arch_projects_dir)" || return 1
    dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    [ "$(dirname "$dir")" = "$proj" ] || return 1
    printf '%s/%s.jsonl\n' "$dir" "$uuid"
}

_arch_state_file() { printf '%s/.state/%s' "$AIB_ARCHIVE_DIR" "$1"; }
_arch_state_get() { sed -n "s/^$2=//p" "$(_arch_state_file "$1")" 2>/dev/null | tail -n 1; }

# _arch_state_set <uuid> key=value...: atomic merge (values must be single-line).
_arch_state_set() {
    local uuid="$1" f content kv tmp; shift
    f="$(_arch_state_file "$uuid")"
    _arch_mkdir "$AIB_ARCHIVE_DIR/.state" || return 1
    content="$(cat "$f" 2>/dev/null || true)"
    for kv in "$@" "updated_at="; do
        content="$(printf '%s\n' "$content" | grep -v "^${kv%%=*}=" || true)"
    done
    tmp="$(mktemp "$f.XXXXXX" 2>/dev/null)" || return 1
    {
        [ -n "$content" ] && printf '%s\n' "$content"
        for kv in "$@"; do printf '%s\n' "$kv"; done
        printf 'updated_at=%s\n' "$(date +%s)"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# _arch_register <uuid> <src> <sid> <cwd>: remember a transcript and mark it pending.
_arch_register() {
    local uuid="$1" src="$2" sid="${3:-}" cwd="${4:-}" sids
    sids="$(_arch_state_get "$uuid" sids)"
    if [ -n "$sid" ]; then
        case ",$sids," in *",$sid,"*) ;; *) sids="${sids:+$sids,}$sid" ;; esac
    fi
    _arch_state_set "$uuid" "state=pending" "src=$src" "sids=$sids" ${cwd:+"cwd=$cwd"}
}

_arch_lock() {
    local d="$AIB_ARCHIVE_DIR/.lock/$1" pid age
    _arch_mkdir "$AIB_ARCHIVE_DIR/.lock" || return 1
    if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; return 0; fi
    pid="$(cat "$d/pid" 2>/dev/null || true)"
    if [ -z "$pid" ]; then   # holder may be between mkdir and writing its pid
        age=$(( $(date +%s) - $(_arch_mtime "$d" || date +%s) ))
        [ "$age" -lt 5 ] && return 1
    elif kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    rm -rf "$d"; rm -f "$AIB_ARCHIVE_DIR/claude/.tmp.$1."* 2>/dev/null
    mkdir "$d" 2>/dev/null || return 1
    echo $$ > "$d/pid"
}
_arch_unlock() { rm -rf "$AIB_ARCHIVE_DIR/.lock/$1"; }

_arch_fail() {   # _arch_fail <uuid> <reason> [tmp...]
    local uuid="$1" reason="$2"; shift 2
    rm -f "$@" 2>/dev/null
    _arch_state_set "$uuid" "state=failed" "last_error=$reason" || true
    return 1
}

# _arch_store <uuid> <copy> <sha> <size>: write the copy as a verified gzip. Prints the
# file name written, or nothing when an identical copy is already stored.
_arch_store() {
    local uuid="$1" copy="$2" sha="$3" size="$4" dir="$AIB_ARCHIVE_DIR/claude" main old_sha old_size dest gz
    main="$dir/$uuid.jsonl.gz"; dest="$main"
    if [ -f "$main" ]; then
        old_sha="$(_arch_state_get "$uuid" main_sha)"; old_size="$(_arch_state_get "$uuid" main_size)"
        if [ -z "$old_sha" ] || [ -z "$old_size" ]; then
            old_sha="$(gzip -dc "$main" | shasum -a 256 | cut -d' ' -f1)"
            old_size="$(gzip -dc "$main" | wc -c | tr -d ' ')"
        fi
        if [ "$sha" = "$old_sha" ]; then
            dest=""
        elif [ "$size" -gt "$old_size" ] && [ "$(head -c "$old_size" "$copy" | shasum -a 256 | cut -d' ' -f1)" = "$old_sha" ]; then
            dest="$main"                                   # resume appended: extend in place
        else
            dest="$dir/$uuid.${sha:0:12}.jsonl.gz"           # rewritten: keep both
            [ -f "$dest" ] && dest=""
        fi
    fi
    [ -n "$dest" ] || return 0
    gz="$copy.gz"
    gzip -c "$copy" > "$gz" 2>/dev/null || { rm -f "$gz"; return 1; }
    [ "$(gzip -dc "$gz" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)" = "$sha" ] || { rm -f "$gz"; return 1; }
    chmod 600 "$gz"
    mv -f "$gz" "$dest" || { rm -f "$gz"; return 1; }
    [ "$dest" = "$main" ] && _arch_state_set "$uuid" "main_sha=$sha" "main_size=$size"
    printf '%s\n' "${dest##*/}"
}

# Metadata-only digest. Tokens are deduplicated by message.id (Claude Code repeats usage on
# every record of a multi-block message); sidechain records are only counted; MCP tool
# names are collapsed to "mcp" so server names do not leak.
_ARCH_DIGEST_JQ='
reduce (inputs | select(length > 0) | (fromjson? // {"__bad": true})) as $r (
  {bad: 0, first: null, last: null, models: {}, prompts: 0, turns: 0, seen: {}, tools: {},
   errors: 0, side: 0, tok: {input: 0, output: 0, cache_creation: 0, cache_read: 0}};
  if ($r | type) != "object" or $r.__bad then .bad += 1
  else
    (if $r.timestamp and .first == null then .first = $r.timestamp else . end)
    | (if $r.timestamp then .last = $r.timestamp else . end)
    | if $r.isSidechain == true then .side += 1
      elif $r.type == "user" and ($r.isMeta | not) then
        ($r.message.content) as $c
        | if ($c | type) == "string" then .prompts += 1
          elif ($c | type) == "array" then
            if any($c[]; .type? == "tool_result")
            then .errors += ([$c[] | select(.type? == "tool_result" and .is_error == true)] | length)
            elif any($c[]; .type? == "text") then .prompts += 1
            else . end
          else . end
      elif $r.type == "assistant" then
        ($r.message.id // "") as $id
        | (if $r.message.model then .models[$r.message.model] = true else . end)
        | .tools = reduce ([$r.message.content[]? | select(.type? == "tool_use") | .name // "?"][]) as $n
            (.tools; .[($n | if startswith("mcp__") then "mcp" else . end)] += 1)
        | if $id == "" or (.seen[$id] | not) then
            (if $id != "" then .seen[$id] = true else . end)
            | .turns += 1
            | .tok.input += ($r.message.usage.input_tokens // 0)
            | .tok.output += ($r.message.usage.output_tokens // 0)
            | .tok.cache_creation += ($r.message.usage.cache_creation_input_tokens // 0)
            | .tok.cache_read += ($r.message.usage.cache_read_input_tokens // 0)
          else . end
      else . end
  end)
| {schema: 1, scope: "cumulative", claude_session_id: $uuid, source_sha256: $sha, archive: $archive,
   first_ts: .first, last_ts: .last, models: (.models | keys), user_prompts: .prompts,
   assistant_turns: .turns, tool_calls: .tools, tool_errors: .errors, tokens: .tok,
   sidechain_records: .side, parse_failures: .bad}
'
_arch_digest() {   # _arch_digest <uuid> <copy> <sha> <archive-name>
    local out="$AIB_ARCHIVE_DIR/.digest/$1.json" tmp
    _arch_mkdir "$AIB_ARCHIVE_DIR/.digest" || return 1
    tmp="$(mktemp "$out.XXXXXX" 2>/dev/null)" || return 1
    if jq -n -R --arg uuid "$1" --arg sha "$3" --arg archive "$4" "$_ARCH_DIGEST_JQ" < "$2" > "$tmp" 2>/dev/null \
        && jq -e '.schema == 1' "$tmp" >/dev/null 2>&1; then
        chmod 600 "$tmp"; mv -f "$tmp" "$out"
    else
        rm -f "$tmp"; return 1
    fi
}

# _arch_process <uuid>: one archive pass (caller holds the lock).
_arch_process() {
    local uuid="$1" src canon vrc=0 state size mtime attempts dir copy sha csize written latest
    src="$(_arch_state_get "$uuid" src)"; state="$(_arch_state_get "$uuid" state)"
    canon="$(_arch_validate_transcript "$src" "$uuid")" || vrc=$?
    if [ "$vrc" -eq 3 ]; then
        case "$state" in succeeded|pruned) ;; *) _arch_state_set "$uuid" "state=source_missing" ;; esac
        return 0
    fi
    [ "$vrc" -eq 0 ] || { _arch_fail "$uuid" invalid_source; return 1; }
    size="$(wc -c < "$canon" | tr -d ' ')"; mtime="$(_arch_mtime "$canon")"
    if [ "$state" = succeeded ] && [ "$(_arch_state_get "$uuid" src_size)" = "$size" ] \
        && [ "$(_arch_state_get "$uuid" src_mtime)" = "$mtime" ]; then
        return 0
    fi
    attempts=$(( $(_arch_state_get "$uuid" attempts || echo 0) + 0 + 1 ))
    _arch_state_set "$uuid" "state=running" "attempts=$attempts" || return 1
    command -v gzip >/dev/null 2>&1 || { _arch_fail "$uuid" no_gzip; return 1; }
    dir="$AIB_ARCHIVE_DIR/claude"
    _arch_mkdir "$dir" || { _arch_fail "$uuid" archive_dir_unwritable; return 1; }
    copy="$(mktemp "$dir/.tmp.$uuid.XXXXXX" 2>/dev/null)" || { _arch_fail "$uuid" tmp_failed; return 1; }
    cp "$canon" "$copy" 2>/dev/null || { _arch_fail "$uuid" copy_failed "$copy"; return 1; }
    sha="$(_arch_sha_file "$copy")"; csize="$(wc -c < "$copy" | tr -d ' ')"
    [ -n "$sha" ] || { _arch_fail "$uuid" hash_failed "$copy"; return 1; }
    written="$(_arch_store "$uuid" "$copy" "$sha" "$csize")" || { _arch_fail "$uuid" store_or_verify_failed "$copy" "$copy.gz"; return 1; }
    latest="${written:-$(_arch_state_get "$uuid" archive)}"; latest="${latest:-$uuid.jsonl.gz}"
    local digest_state=ok
    _arch_digest "$uuid" "$copy" "$sha" "$latest" || digest_state=failed
    rm -f "$copy"
    if [ -n "$written" ]; then
        _arch_state_set "$uuid" "state=succeeded" "src_size=$size" "src_mtime=$mtime" "src_sha=$sha" \
            "archive=$latest" "archived_at=$(date +%s)" "digest_state=$digest_state" "last_error=" "attempts=0"
    else
        _arch_state_set "$uuid" "state=succeeded" "src_size=$size" "src_mtime=$mtime" "src_sha=$sha" \
            "archive=$latest" "digest_state=$digest_state" "last_error=" "attempts=0"
    fi
}

_arch_run_one() {
    local uuid="${1:-}" rc=0
    [[ "$uuid" =~ $_ARCH_UUID_RE ]] || { log_err "Usage: aib archive run <claude-session-uuid>|--pending"; return 1; }
    [ -f "$(_arch_state_file "$uuid")" ] || { log_err "Unknown transcript: $uuid"; return 1; }
    _arch_lock "$uuid" || return 0          # another worker has it
    _arch_process "$uuid" || rc=$?
    _arch_unlock "$uuid"
    return "$rc"
}

# Retry everything not finished: new/changed sources, failures under the attempt cap.
_arch_run_pending() {
    local f uuid state
    [ -d "$AIB_ARCHIVE_DIR/.state" ] || return 0
    for f in "$AIB_ARCHIVE_DIR/.state/"*; do
        uuid="${f##*/}"; [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        state="$(_arch_state_get "$uuid" state)"
        case "$state" in
            pruned|source_missing) continue ;;
            failed) [ "$(_arch_state_get "$uuid" attempts)" -ge "$_ARCH_MAX_ATTEMPTS" ] 2>/dev/null && continue ;;
        esac
        _arch_run_one "$uuid" || true
    done
}

# _arch_spawn <archive run args...>: detached worker (survives the CLI exiting).
_arch_spawn() {
    [ -n "${AIB_ARCHIVE_NO_WORKER:-}" ] && return 0
    if [ "${AIB_ARCHIVE_SYNC:-}" = 1 ]; then
        if [ "${1:-}" = --pending ]; then _arch_run_pending; else _arch_run_one "$1"; fi >/dev/null 2>&1 || true
        return 0
    fi
    _arch_mkdir "$AIB_ARCHIVE_DIR" || return 0
    (cd / && nohup "$SCRIPT_DIR/aib" archive run "$@" </dev/null >>"$AIB_ARCHIVE_DIR/.log" 2>&1 &) 2>/dev/null || true
}

# _arch_hook <SessionStart|SessionEnd> <aib-session-id>: Claude hooks only. Never fails.
_arch_hook() {
    local event="$1" sid="$2" uuid src canon cwd
    [ -n "$_ARCH_PAYLOAD" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    uuid="$(printf '%s' "$_ARCH_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)" || return 0
    src="$(printf '%s' "$_ARCH_PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)" || return 0
    cwd="$(pwd -P)"
    canon="$(_arch_validate_transcript "$src" "$uuid")" || return 0
    _arch_register "$uuid" "$canon" "$sid" "$cwd" || return 0
    if [ "$event" = SessionEnd ]; then _arch_spawn "$uuid"; else _arch_spawn --pending; fi
    return 0
}

_arch_backfill() {
    local all=false proj barrack f uuid cwd n=0 failed=0
    [ "${1:-}" = --all ] && all=true
    proj="$(_arch_projects_dir)" || { log_warn "No Claude projects directory; nothing to back up"; return 0; }
    barrack="$(pwd -P)"
    for f in "$proj"/*/*.jsonl; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        uuid="${f##*/}"; uuid="${uuid%.jsonl}"
        [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        cwd=""
        if ! $all; then
            cwd="$(head -n 200 "$f" 2>/dev/null | jq -R -r 'fromjson? | select(type == "object" and .cwd != null) | .cwd' 2>/dev/null | head -n 1 || true)"
            [ "$cwd" = "$barrack" ] || case "$cwd" in "$barrack"/*) ;; *) continue ;; esac
        fi
        _arch_register "$uuid" "$f" "" "$cwd" || { failed=$((failed + 1)); continue; }
        _arch_run_one "$uuid" || failed=$((failed + 1))
        n=$((n + 1))
    done
    log_ok "Backfill: ${n} transcript(s) checked, ${failed} failed — see aib archive status"
    [ "$failed" -eq 0 ]
}

_arch_status() {
    local f uuid st ok=0 pend=0 fail=0 miss=0 pruned=0 run=0 size oldest="" at
    if [ ! -d "$AIB_ARCHIVE_DIR/.state" ]; then
        echo "archive: empty — ${AIB_ARCHIVE_DIR}"
        return 0
    fi
    for f in "$AIB_ARCHIVE_DIR/.state/"*; do
        uuid="${f##*/}"; [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        st="$(_arch_state_get "$uuid" state)"
        case "$st" in
            succeeded) ok=$((ok + 1)) ;; pending) pend=$((pend + 1)) ;; running) run=$((run + 1)) ;;
            failed) fail=$((fail + 1)) ;; source_missing) miss=$((miss + 1)) ;; pruned) pruned=$((pruned + 1)) ;;
        esac
        at="$(_arch_state_get "$uuid" archived_at)"
        if [ -n "$at" ] && [ "$st" = succeeded ] && { [ -z "$oldest" ] || [ "$at" -lt "$oldest" ]; }; then oldest="$at"; fi
    done
    echo "archive: ${ok} succeeded, ${pend} pending, ${run} running, ${fail} failed, ${miss} source_missing, ${pruned} pruned — ${AIB_ARCHIVE_DIR}"
    size="$(du -sh "$AIB_ARCHIVE_DIR/claude" 2>/dev/null | cut -f1)"
    echo "  size: ${size:-0}  oldest archive: $([ -n "$oldest" ] && date -r "$oldest" '+%Y-%m-%d' 2>/dev/null || echo -)"
    echo "  Archives are plaintext transcripts (0600, outside git) and may contain secrets. Retention is unlimited until you run: aib archive prune --older-than <days>"
    if [ "$fail" -gt 0 ]; then
        for f in "$AIB_ARCHIVE_DIR/.state/"*; do
            uuid="${f##*/}"
            [ "$(_arch_state_get "$uuid" state)" = failed ] && echo "  failed ${uuid}: $(_arch_state_get "$uuid" last_error) (attempts $(_arch_state_get "$uuid" attempts))"
        done | head -n 10
    fi
    return 0
}

_arch_show() {
    local key="${1:-}" uuid="" f sids
    [ -n "$key" ] || { log_err "Usage: aib archive show <claude-session-uuid|aib-session-id>"; return 1; }
    if [[ "$key" =~ $_ARCH_UUID_RE ]]; then
        uuid="$key"
    else
        for f in "$AIB_ARCHIVE_DIR/.state/"*; do
            sids="$(sed -n 's/^sids=//p' "$f" 2>/dev/null | tail -n 1)"
            case ",$sids," in *",$key,"*) uuid="${f##*/}"; break ;; esac
        done
    fi
    [ -n "$uuid" ] && [ -f "$(_arch_state_file "$uuid")" ] || { log_err "No archived transcript for: $key"; return 1; }
    echo "claude_session_id: $uuid"
    grep -E '^(state|sids|cwd|archive|archived_at|src_sha|digest_state|attempts|last_error)=' "$(_arch_state_file "$uuid")"
    echo "file: $AIB_ARCHIVE_DIR/claude/$(_arch_state_get "$uuid" archive)"
    [ -f "$AIB_ARCHIVE_DIR/.digest/$uuid.json" ] && jq . "$AIB_ARCHIVE_DIR/.digest/$uuid.json"
    return 0
}

_arch_prune() {
    local days="" f uuid at cutoff n=0
    [ "${1:-}" = --older-than ] && days="${2:-}"
    [[ "$days" =~ ^[0-9]+$ ]] || { log_err "Usage: aib archive prune --older-than <days>"; return 1; }
    [ -d "$AIB_ARCHIVE_DIR/.state" ] || { log_info "Archive is empty"; return 0; }
    cutoff=$(( $(date +%s) - days * 86400 ))
    for f in "$AIB_ARCHIVE_DIR/.state/"*; do
        uuid="${f##*/}"; [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        [ "$(_arch_state_get "$uuid" state)" = pruned ] && continue
        at="$(_arch_state_get "$uuid" archived_at)"
        [[ "$at" =~ ^[0-9]+$ ]] && [ "$at" -lt "$cutoff" ] || continue
        _arch_lock "$uuid" || continue
        rm -f "$AIB_ARCHIVE_DIR/claude/$uuid.jsonl.gz" "$AIB_ARCHIVE_DIR/claude/$uuid."*.jsonl.gz "$AIB_ARCHIVE_DIR/.digest/$uuid.json"
        _arch_state_set "$uuid" "state=pruned" "pruned_at=$(date +%s)"
        printf '%s %s archived_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$uuid" "$at" >> "$AIB_ARCHIVE_DIR/.pruned.log"
        _arch_unlock "$uuid"
        n=$((n + 1))
    done
    log_ok "Pruned ${n} archive(s) older than ${days} days (logged in ${AIB_ARCHIVE_DIR}/.pruned.log)"
}

cmd_archive() {
    case "${1:-}" in
        run)      shift; if [ "${1:-}" = --pending ]; then _arch_run_pending; else _arch_run_one "${1:-}"; fi ;;
        backfill) shift; _arch_backfill "$@" ;;
        status)   _arch_status ;;
        show)     shift; _arch_show "${1:-}" ;;
        prune)    shift; _arch_prune "$@" ;;
        *) log_err "Usage: aib archive <run <uuid>|run --pending|backfill [--all]|status|show <uuid|sid>|prune --older-than <days>>"; return 1 ;;
    esac
}
