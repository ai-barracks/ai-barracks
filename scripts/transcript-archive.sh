# Claude transcript archive. Sourced by aib.
#
# Claude Code deletes ~/.claude/projects/*/*.jsonl after cleanupPeriodDays (~30 days), so
# the raw conversation behind each curated session record used to vanish. aib keeps a
# private, verified gzip copy outside git plus a metadata-only digest.
#
# Design (council 20261016_140213_79393, Codex review): hooks only drop an immutable intent
# file — Claude Code kills a SessionEnd hook after ~0.9s — and a detached worker merges
# intents and copies, verifies and digests under a per-uuid lock. Only the lock holder
# writes state, so no update is lost. Session records are never touched.
#
# Layout under AIB_ARCHIVE_DIR (dirs 0700, files 0600):
#   claude/<uuid>.jsonl.gz          transcript; replaced only when the new copy extends it
#   claude/<uuid>.<sha>.jsonl.gz    a rewritten (non-prefix) copy, kept beside the old one
#   .intent/<uuid>.<ts>.<pid>.<n>   hook intents (src/sid/cwd), merged by the worker
#   .state/<uuid>                   key=value, written only under the lock
#   .digest/<uuid>.json             metadata only — no prompts, paths, commands or output
#   .lock/<uuid>/owner              "<pid>.<token>"; dead or >1h-old owners are reclaimed
#   .log, .pruned.log

AIB_ARCHIVE_DIR="${AIB_ARCHIVE_DIR:-$HOME/.aib/archive}"
_ARCH_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
_ARCH_PAYLOAD=""
_ARCH_MAX_ATTEMPTS=5
_ARCH_LOCK_TOKEN=""
_ARCH_END_DONE=""

_arch_mkdir() { (umask 077; mkdir -p "$1") 2>/dev/null && chmod 700 "$1" 2>/dev/null; }
_arch_sha_file() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
# Sub-second mtime so a same-length rewrite within one second is still noticed.
_arch_mtime() { stat -f %Fm "$1" 2>/dev/null || stat -c %.9Y "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
_arch_age() { echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s) )); }

# _arch_gz_sha <gz>: sha256 of the decompressed content; fails on any gzip error.
_arch_gz_sha() {
    local out
    gzip -t "$1" 2>/dev/null || return 1
    out="$(set -o pipefail; gzip -dc "$1" 2>/dev/null | shasum -a 256)" || return 1
    printf '%s\n' "${out%% *}"
}

_arch_projects_dir() {
    local base="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    [ -d "$base/projects" ] || return 1
    (cd "$base/projects" && pwd -P)
}

# Hook payload from stdin: stop as soon as the JSON object is complete, at 64 KiB, or after
# 0.3s — whichever comes first — so a writer that never closes stdin cannot eat the
# SessionEnd budget. (perl ships with macOS; shasum itself is a perl script.)
_arch_read_payload() {
    _ARCH_PAYLOAD=""
    [ -t 0 ] && return 0
    if command -v perl >/dev/null 2>&1; then
        _ARCH_PAYLOAD="$(perl -e '
            use IO::Select; use Time::HiRes qw(time);
            my $s = IO::Select->new(\*STDIN); my ($b, $d) = ("", time + 0.3);
            while (length($b) < 65536) {
                my $left = $d - time; last if $left <= 0;
                last unless $s->can_read($left);
                my $n = sysread(STDIN, my $c, 65536 - length($b)); last if !$n;
                $b .= $c; last if $b =~ /\}\s*\z/;
            }
            print $b;' 2>/dev/null)" || _ARCH_PAYLOAD=""
    else
        IFS= read -r -d '' -t 1 _ARCH_PAYLOAD || true
        _ARCH_PAYLOAD="${_ARCH_PAYLOAD:0:65536}"
    fi
}

# _arch_validate_transcript <path> <uuid>: print the canonical path and return 0, or
# return 3 (still printing the path) when the file does not exist yet but its directory is
# a valid <claude>/projects/<one dir>. Returns 1 for anything that must not be read:
# outside that tree, not named <uuid>.jsonl, a symlink, or a path with a line break.
_arch_validate_transcript() {
    local p="${1:-}" uuid="${2:-}" proj dir
    case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
    case "$p" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [[ "$uuid" =~ $_ARCH_UUID_RE ]] || return 1
    [[ "$p" == /* ]] || return 1
    [ "${p##*/}" = "${uuid}.jsonl" ] || return 1
    [ -L "$p" ] && return 1
    proj="$(_arch_projects_dir)" || return 1
    dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    [ "$(dirname "$dir")" = "$proj" ] || return 1
    printf '%s/%s.jsonl\n' "$dir" "$uuid"
    [ -e "$p" ] || return 3
    [ -f "$p" ] || return 1
}

_arch_state_file() { printf '%s/.state/%s' "$AIB_ARCHIVE_DIR" "$1"; }
_arch_state_get() { sed -n "s/^$2=//p" "$(_arch_state_file "$1")" 2>/dev/null | tail -n 1; }

# _arch_state_set <uuid> key=value...: atomic merge. Call only while holding the lock.
_arch_state_set() {
    local uuid="$1" f content kv tmp; shift
    for kv in "$@"; do case "$kv" in *$'\n'*|*$'\r'*) return 1 ;; esac; done
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

# _arch_intent <uuid> <src> <sid> <cwd>: immutable intent; safe without the lock.
_arch_intent() {
    local uuid="$1" src="$2" sid="${3:-}" cwd="${4:-}" dir="$AIB_ARCHIVE_DIR/.intent" tmp
    [[ "$uuid" =~ $_ARCH_UUID_RE ]] || return 1
    case "$src$sid$cwd" in *$'\n'*|*$'\r'*) return 1 ;; esac
    [ -z "$sid" ] || _aib_valid_sid "$sid" || sid=""
    _arch_mkdir "$dir" || return 1
    tmp="$(mktemp "$dir/.new.XXXXXX" 2>/dev/null)" || return 1
    printf 'src=%s\nsid=%s\ncwd=%s\n' "$src" "$sid" "$cwd" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$dir/$uuid.$(date +%s).$$.$RANDOM" 2>/dev/null || { rm -f "$tmp"; return 1; }
}
_arch_has_intent() { ls "$AIB_ARCHIVE_DIR/.intent/$1."* >/dev/null 2>&1; }

# Merge this uuid's intents into its state (lock held). Prints "1" if any was merged.
_arch_merge_intents() {
    local uuid="$1" f src sid cwd sids merged=0
    sids="$(_arch_state_get "$uuid" sids)"; src="$(_arch_state_get "$uuid" src)"; cwd="$(_arch_state_get "$uuid" cwd)"
    for f in "$AIB_ARCHIVE_DIR/.intent/$uuid."*; do
        [ -f "$f" ] || continue
        src="$(sed -n 's/^src=//p' "$f" | tail -n 1)"
        sid="$(sed -n 's/^sid=//p' "$f" | tail -n 1)"
        [ -n "$(sed -n 's/^cwd=//p' "$f")" ] && cwd="$(sed -n 's/^cwd=//p' "$f" | tail -n 1)"
        if [ -n "$sid" ]; then case ",$sids," in *",$sid,"*) ;; *) sids="${sids:+$sids,}$sid" ;; esac; fi
        merged=1
    done
    if [ "$merged" = 1 ]; then
        _arch_state_set "$uuid" "state=pending" "src=$src" "sids=$sids" "cwd=$cwd" || return 1
        rm -f "$AIB_ARCHIVE_DIR/.intent/$uuid."* 2>/dev/null
    fi
    printf '%s\n' "$merged"
}

_arch_lock() {
    local uuid="$1" d="$AIB_ARCHIVE_DIR/.lock/$1" m owner pid token
    _arch_mkdir "$AIB_ARCHIVE_DIR/.lock" || return 1
    token="$$.$RANDOM$RANDOM"
    if mkdir "$d" 2>/dev/null; then printf '%s\n' "$token" > "$d/owner"; _ARCH_LOCK_TOKEN="$token"; return 0; fi
    owner="$(cat "$d/owner" 2>/dev/null || true)"; pid="${owner%%.*}"
    if [ -z "$owner" ]; then
        [ "$(_arch_age "$d")" -lt 5 ] && return 1      # holder is between mkdir and writing owner
    elif kill -0 "$pid" 2>/dev/null && [ "$(_arch_age "$d")" -lt 3600 ]; then
        return 1                                         # live (a worker never runs for an hour)
    fi
    # Reclaim a dead lock under a mutex, re-checking the owner so a fresh lock is never taken.
    m="$d.reclaim"
    if ! mkdir "$m" 2>/dev/null; then
        [ "$(_arch_age "$m")" -gt 30 ] && rmdir "$m" 2>/dev/null
        return 1
    fi
    if [ "$(cat "$d/owner" 2>/dev/null || true)" = "$owner" ]; then
        rm -rf "$d"; rm -f "$AIB_ARCHIVE_DIR/claude/.tmp.$uuid."* 2>/dev/null
        if mkdir "$d" 2>/dev/null; then
            printf '%s\n' "$token" > "$d/owner"; _ARCH_LOCK_TOKEN="$token"
            rmdir "$m" 2>/dev/null; return 0
        fi
    fi
    rmdir "$m" 2>/dev/null
    return 1
}
_arch_unlock() {
    local d="$AIB_ARCHIVE_DIR/.lock/$1"
    [ -n "$_ARCH_LOCK_TOKEN" ] && [ "$(cat "$d/owner" 2>/dev/null || true)" = "$_ARCH_LOCK_TOKEN" ] && rm -rf "$d"
    _ARCH_LOCK_TOKEN=""
    return 0
}

_arch_fail() {   # _arch_fail <uuid> <reason> [tmp...]
    local uuid="$1" reason="$2"; shift 2
    rm -f "$@" 2>/dev/null
    _arch_state_set "$uuid" "state=failed" "last_error=$reason" || true
    return 1
}

# _arch_write_gz <copy> <sha> <dest>: gzip, verify by gzip -t + decompressed sha, publish.
_arch_write_gz() {
    local copy="$1" sha="$2" dest="$3" gz="$1.gz"
    gzip -c "$copy" > "$gz" 2>/dev/null || { rm -f "$gz"; return 1; }
    [ "$(_arch_gz_sha "$gz" || true)" = "$sha" ] || { rm -f "$gz"; return 1; }
    chmod 600 "$gz" && mv -f "$gz" "$dest" || { rm -f "$gz"; return 1; }
}

# _arch_store <uuid> <copy> <sha> <size>: prints "<file name> <1 if written|0 if reused>".
_arch_store() {
    local uuid="$1" copy="$2" sha="$3" size="$4" dir="$AIB_ARCHIVE_DIR/claude" main old_sha old_size dest
    main="$dir/$uuid.jsonl.gz"; dest="$main"
    if [ -f "$main" ]; then
        old_sha="$(_arch_state_get "$uuid" main_sha)"; old_size="$(_arch_state_get "$uuid" main_size)"
        if [ -z "$old_sha" ] || [ -z "$old_size" ]; then
            old_sha="$(_arch_gz_sha "$main" || true)"
            old_size="$(gzip -dc "$main" 2>/dev/null | wc -c | tr -d ' ' || true)"
        fi
        if [ -z "$old_sha" ]; then
            dest="$main"                                    # unreadable main: rewrite it
        elif [ "$sha" = "$old_sha" ]; then
            printf '%s 0\n' "${main##*/}"; return 0
        elif [ "$size" -gt "$old_size" ] && [ "$(head -c "$old_size" "$copy" | shasum -a 256 | cut -d' ' -f1)" = "$old_sha" ]; then
            dest="$main"                                    # resume appended: extend in place
        else
            dest="$dir/$uuid.${sha:0:12}.jsonl.gz"          # rewritten: keep both
            if [ -f "$dest" ]; then
                if [ "$(_arch_gz_sha "$dest" || true)" = "$sha" ]; then printf '%s 0\n' "${dest##*/}"; return 0; fi
                dest="$dir/$uuid.$sha.jsonl.gz"             # short-hash clash or damage
            fi
        fi
    fi
    _arch_write_gz "$copy" "$sha" "$dest" || return 1
    if [ "$dest" = "$main" ]; then _arch_state_set "$uuid" "main_sha=$sha" "main_size=$size" || return 1; fi
    printf '%s 1\n' "${dest##*/}"
}

# Metadata-only digest. Tokens are deduplicated by message.id (Claude Code repeats usage on
# every record of a multi-block message); sidechains are only counted. Only well-formed
# values are copied: ISO timestamps, short model/tool identifiers (else "other"), MCP tools
# collapsed to "mcp" so server names do not leak.
_ARCH_DIGEST_JQ='
def ts: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?$") then . else null end;
def ident: if type == "string" and test("^[A-Za-z0-9._:-]{1,64}$") then . else "other" end;
def tool: if type == "string" and startswith("mcp__") then "mcp" else ident end;
def num: if type == "number" and . >= 0 then . else 0 end;
reduce (inputs | select(length > 0) | (fromjson? // {"__bad": true})) as $r (
  {bad: 0, first: null, last: null, models: {}, prompts: 0, turns: 0, seen: {}, tools: {},
   errors: 0, side: 0, tok: {input: 0, output: 0, cache_creation: 0, cache_read: 0}};
  if ($r | type) != "object" or $r.__bad then .bad += 1
  else
    ($r.timestamp | ts) as $t
    | (if $t != null and .first == null then .first = $t else . end)
    | (if $t != null then .last = $t else . end)
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
        ($r.message.id | if type == "string" then . else "" end) as $id
        | (if $r.message.model != null then .models[($r.message.model | ident)] = true else . end)
        | .tools = reduce ([$r.message.content[]? | select(.type? == "tool_use") | .name | tool][]) as $n
            (.tools; .[$n] += 1)
        | if $id == "" or (.seen[$id] | not) then
            (if $id != "" then .seen[$id] = true else . end)
            | .turns += 1
            | .tok.input += ($r.message.usage.input_tokens | num)
            | .tok.output += ($r.message.usage.output_tokens | num)
            | .tok.cache_creation += ($r.message.usage.cache_creation_input_tokens | num)
            | .tok.cache_read += ($r.message.usage.cache_read_input_tokens | num)
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

# _arch_process <uuid>: one archive pass (lock held).
_arch_process() {
    local uuid="$1" merged src canon vrc=0 state size mtime archive attempts dir copy sha csize stored name written digest_state=ok
    merged="$(_arch_merge_intents "$uuid")" || { _arch_fail "$uuid" state_unwritable; return 1; }
    state="$(_arch_state_get "$uuid" state)"
    [ "$state" = pruned ] && [ "$merged" != 1 ] && return 0     # pruned stays pruned until new activity
    src="$(_arch_state_get "$uuid" src)"
    canon="$(_arch_validate_transcript "$src" "$uuid")" || vrc=$?
    if [ "$vrc" -eq 3 ]; then
        case "$state" in succeeded) ;; *) _arch_state_set "$uuid" "state=source_missing" || true ;; esac
        return 0
    fi
    [ "$vrc" -eq 0 ] || { _arch_fail "$uuid" invalid_source; return 1; }
    size="$(wc -c < "$canon" | tr -d ' ')"; mtime="$(_arch_mtime "$canon")"; archive="$(_arch_state_get "$uuid" archive)"
    if [ "$state" = succeeded ] && [ "$(_arch_state_get "$uuid" src_size)" = "$size" ] \
        && [ "$(_arch_state_get "$uuid" src_mtime)" = "$mtime" ] \
        && [ -n "$archive" ] && [ -f "$AIB_ARCHIVE_DIR/claude/$archive" ] \
        && [ "$(_arch_state_get "$uuid" digest_state)" = ok ]; then
        return 0
    fi
    attempts=$(( $(_arch_state_get "$uuid" attempts) + 0 + 1 ))
    _arch_state_set "$uuid" "state=running" "attempts=$attempts" || return 1
    command -v gzip >/dev/null 2>&1 || { _arch_fail "$uuid" no_gzip; return 1; }
    dir="$AIB_ARCHIVE_DIR/claude"
    _arch_mkdir "$dir" || { _arch_fail "$uuid" archive_dir_unwritable; return 1; }
    copy="$(mktemp "$dir/.tmp.$uuid.XXXXXX" 2>/dev/null)" || { _arch_fail "$uuid" tmp_failed; return 1; }
    # -P: never follow a symlink swapped in after validation; the copy must stay a regular file.
    cp -P "$canon" "$copy" 2>/dev/null && [ -f "$copy" ] && [ ! -L "$copy" ] \
        || { _arch_fail "$uuid" copy_failed "$copy"; return 1; }
    sha="$(_arch_sha_file "$copy")"; csize="$(wc -c < "$copy" | tr -d ' ')"
    [ -n "$sha" ] || { _arch_fail "$uuid" hash_failed "$copy"; return 1; }
    stored="$(_arch_store "$uuid" "$copy" "$sha" "$csize")" || { _arch_fail "$uuid" store_or_verify_failed "$copy" "$copy.gz"; return 1; }
    name="${stored% *}"; written="${stored##* }"
    _arch_digest "$uuid" "$copy" "$sha" "$name" || digest_state=failed
    rm -f "$copy"
    if [ "$written" = 1 ]; then
        _arch_state_set "$uuid" "state=succeeded" "src_size=$size" "src_mtime=$mtime" "src_sha=$sha" \
            "archive=$name" "archived_at=$(date +%s)" "digest_state=$digest_state" "last_error=" "attempts=0"
    else
        _arch_state_set "$uuid" "state=succeeded" "src_size=$size" "src_mtime=$mtime" "src_sha=$sha" \
            "archive=$name" "digest_state=$digest_state" "last_error=" "attempts=0"
    fi
}

_arch_run_one() {
    local uuid="${1:-}" rc=0
    [[ "$uuid" =~ $_ARCH_UUID_RE ]] || { log_err "Usage: aib archive run <claude-session-uuid>|--pending"; return 1; }
    [ -f "$(_arch_state_file "$uuid")" ] || _arch_has_intent "$uuid" || { log_err "Unknown transcript: $uuid"; return 1; }
    _arch_lock "$uuid" || return 0          # another worker has it
    _arch_process "$uuid" || rc=$?
    _arch_unlock "$uuid"
    return "$rc"
}

# Retry everything not finished: new intents, changed sources, failures under the cap.
_arch_run_pending() {
    local f uuid seen=" "
    for f in "$AIB_ARCHIVE_DIR/.intent/"* "$AIB_ARCHIVE_DIR/.state/"*; do
        [ -e "$f" ] || continue
        uuid="${f##*/}"; uuid="${uuid%%.*}"
        [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        case "$seen" in *" $uuid "*) continue ;; esac
        seen="$seen$uuid "
        if ! _arch_has_intent "$uuid"; then
            case "$(_arch_state_get "$uuid" state)" in
                pruned) continue ;;
                failed) [ "$(_arch_state_get "$uuid" attempts)" -ge "$_ARCH_MAX_ATTEMPTS" ] 2>/dev/null && continue ;;
            esac
        fi
        _arch_run_one "$uuid" || true
    done
    return 0
}

# _arch_spawn <archive run args...>: detached worker (survives the CLI exiting).
_arch_spawn() {
    [ -n "${AIB_ARCHIVE_NO_WORKER:-}" ] && return 0
    if [ "${AIB_ARCHIVE_SYNC:-}" = 1 ]; then
        ( umask 077; if [ "${1:-}" = --pending ]; then _arch_run_pending; else _arch_run_one "$1"; fi ) >/dev/null 2>&1 || true
        return 0
    fi
    _arch_mkdir "$AIB_ARCHIVE_DIR" || return 0
    (cd / && umask 077 && nohup "$SCRIPT_DIR/aib" archive run "$@" </dev/null >>"$AIB_ARCHIVE_DIR/.log" 2>&1 &) 2>/dev/null || true
}

# _arch_hook <SessionStart|SessionEnd> <aib-session-id or "">: Claude hooks only. Never fails.
# SessionStart always retries pending work; SessionEnd archives even without a session row.
_arch_hook() {
    local event="$1" sid="${2:-}" uuid="" src="" canon vrc=0
    if [ "$event" = SessionEnd ]; then
        [ -n "$_ARCH_END_DONE" ] && return 0
        _ARCH_END_DONE=1
    fi
    if [ -n "$_ARCH_PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
        uuid="$(printf '%s' "$_ARCH_PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null || true)"
        src="$(printf '%s' "$_ARCH_PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
        canon="$(_arch_validate_transcript "$src" "$uuid")" || vrc=$?
        if [ "$vrc" -eq 0 ] || [ "$vrc" -eq 3 ]; then
            ( umask 077; _arch_intent "$uuid" "$canon" "$sid" "$(pwd -P)" ) || true
        else
            uuid=""
        fi
    fi
    if [ "$event" = SessionEnd ] && [ -n "$uuid" ]; then _arch_spawn "$uuid"; else _arch_spawn --pending; fi
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
            cwd="$(head -n 200 "$f" 2>/dev/null | jq -R -r 'fromjson? | select(type == "object" and (.cwd | type) == "string") | .cwd' 2>/dev/null | head -n 1 || true)"
            [ "$cwd" = "$barrack" ] || case "$cwd" in "$barrack"/*) ;; *) continue ;; esac
        fi
        _arch_intent "$uuid" "$f" "" "$cwd" || { failed=$((failed + 1)); continue; }
        _arch_run_one "$uuid" || failed=$((failed + 1))
        n=$((n + 1))
    done
    log_ok "Backfill: ${n} transcript(s) checked, ${failed} failed — see aib archive status"
    [ "$failed" -eq 0 ]
}

_arch_status() {
    local f uuid st ok=0 pend=0 fail=0 miss=0 pruned=0 run=0 size oldest="" at listed=0
    if [ ! -d "$AIB_ARCHIVE_DIR/.state" ] && ! ls "$AIB_ARCHIVE_DIR/.intent/"* >/dev/null 2>&1; then
        echo "archive: empty — ${AIB_ARCHIVE_DIR}"
        return 0
    fi
    for f in "$AIB_ARCHIVE_DIR/.state/"*; do
        [ -f "$f" ] || continue
        uuid="${f##*/}"; [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        st="$(_arch_state_get "$uuid" state)"
        case "$st" in
            succeeded) ok=$((ok + 1)) ;; pending) pend=$((pend + 1)) ;; running) run=$((run + 1)) ;;
            failed) fail=$((fail + 1)) ;; source_missing) miss=$((miss + 1)) ;; pruned) pruned=$((pruned + 1)) ;;
        esac
        at="$(_arch_state_get "$uuid" archived_at)"
        if [ "$st" = succeeded ] && [[ "$at" =~ ^[0-9]+$ ]]; then
            if [ -z "$oldest" ] || [ "$at" -lt "$oldest" ]; then oldest="$at"; fi
        fi
    done
    echo "archive: ${ok} succeeded, ${pend} pending, ${run} running, ${fail} failed, ${miss} source_missing, ${pruned} pruned — ${AIB_ARCHIVE_DIR}"
    size="$(du -sh "$AIB_ARCHIVE_DIR/claude" 2>/dev/null | cut -f1 || true)"
    echo "  size: ${size:-0}  oldest archive: $( [ -n "$oldest" ] && date -r "$oldest" '+%Y-%m-%d' 2>/dev/null || echo -)"
    echo "  Archives are plaintext transcripts (0600, outside git) and may contain secrets. Retention is unlimited until you run: aib archive prune --older-than <days>"
    if [ "$fail" -gt 0 ]; then
        for f in "$AIB_ARCHIVE_DIR/.state/"*; do
            [ "$listed" -ge 10 ] && break
            uuid="${f##*/}"
            if [ "$(_arch_state_get "$uuid" state)" = failed ]; then
                echo "  failed ${uuid}: $(_arch_state_get "$uuid" last_error) (attempts $(_arch_state_get "$uuid" attempts))"
                listed=$((listed + 1))
            fi
        done
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
            [ -f "$f" ] || continue
            sids="$(sed -n 's/^sids=//p' "$f" 2>/dev/null | tail -n 1)"
            case ",$sids," in *",$key,"*) uuid="${f##*/}"; break ;; esac
        done
    fi
    if [ -z "$uuid" ] || [ ! -f "$(_arch_state_file "$uuid")" ]; then
        log_err "No archived transcript for: $key"; return 1
    fi
    echo "claude_session_id: $uuid"
    grep -E '^(state|sids|cwd|archive|archived_at|src_sha|digest_state|attempts|last_error)=' "$(_arch_state_file "$uuid")" || true
    echo "file: $AIB_ARCHIVE_DIR/claude/$(_arch_state_get "$uuid" archive)"
    if [ -f "$AIB_ARCHIVE_DIR/.digest/$uuid.json" ]; then jq . "$AIB_ARCHIVE_DIR/.digest/$uuid.json" || true; fi
    return 0
}

_arch_prune() {
    local days="" f uuid at cutoff n=0 busy=0
    [ "${1:-}" = --older-than ] && days="${2:-}"
    [[ "$days" =~ ^[0-9]+$ ]] || { log_err "Usage: aib archive prune --older-than <days>"; return 1; }
    [ -d "$AIB_ARCHIVE_DIR/.state" ] || { log_info "Archive is empty"; return 0; }
    cutoff=$(( $(date +%s) - days * 86400 ))
    for f in "$AIB_ARCHIVE_DIR/.state/"*; do
        [ -f "$f" ] || continue
        uuid="${f##*/}"; [[ "$uuid" =~ $_ARCH_UUID_RE ]] || continue
        _arch_lock "$uuid" || { busy=$((busy + 1)); continue; }
        # Decide under the lock: a worker may have just refreshed this archive.
        at="$(_arch_state_get "$uuid" archived_at)"
        if [ "$(_arch_state_get "$uuid" state)" != pruned ] && [[ "$at" =~ ^[0-9]+$ ]] && [ "$at" -lt "$cutoff" ]; then
            rm -f "$AIB_ARCHIVE_DIR/claude/$uuid.jsonl.gz" "$AIB_ARCHIVE_DIR/claude/$uuid."*.jsonl.gz "$AIB_ARCHIVE_DIR/.digest/$uuid.json"
            _arch_state_set "$uuid" "state=pruned" "pruned_at=$(date +%s)" || true
            printf '%s %s archived_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$uuid" "$at" >> "$AIB_ARCHIVE_DIR/.pruned.log"
            n=$((n + 1))
        fi
        _arch_unlock "$uuid"
    done
    log_ok "Pruned ${n} archive(s) older than ${days} days (logged in ${AIB_ARCHIVE_DIR}/.pruned.log)"
    [ "$busy" -eq 0 ] || log_warn "${busy} archive(s) were busy and skipped; run prune again later"
    return 0
}

cmd_archive() {
    umask 077
    case "${1:-}" in
        run)      shift; if [ "${1:-}" = --pending ]; then _arch_run_pending; else _arch_run_one "${1:-}"; fi ;;
        backfill) shift; _arch_backfill "$@" ;;
        status)   _arch_status ;;
        show)     shift; _arch_show "${1:-}" ;;
        prune)    shift; _arch_prune "$@" ;;
        *) log_err "Usage: aib archive <run <uuid>|run --pending|backfill [--all]|status|show <uuid|sid>|prune --older-than <days>>"; return 1 ;;
    esac
}
