# Native Codex hooks. Sourced by aib; never infer identity from a shared PID.
cmd_hooks_codex_install() (
    local root="${1:-.}"
    cd "$root"
    command -v jq >/dev/null || { log_err "jq is required"; exit 1; }
    [ ! -L .codex ] && [ ! -L .codex/hooks.json ] || { log_err "Refusing symlinked hook configuration"; exit 1; }
    mkdir -p .codex
    local file=.codex/hooks.json tmp
    [ -f "$file" ] || printf '{"hooks":{}}\n' > "$file"
    jq -e 'type == "object" and ((.hooks // {}) | type == "object")' "$file" >/dev/null || { log_err "Invalid hooks.json; preserved"; exit 1; }
    tmp=$(mktemp .codex/.hooks.XXXXXX)
    trap 'rm -f "$tmp"' EXIT
    jq 'def ensure(ev):
          .hooks[ev] = ((.hooks[ev] // []) | if any(.[]?; .hooks[]?.command == "aib hook native codex") then . else
            . + [{hooks:[{type:"command",command:"aib hook native codex",timeout:3}]}] end);
        .hooks = (.hooks // {})
        | ensure("SessionStart") | ensure("SessionEnd") | ensure("UserPromptSubmit")
        | ensure("PreToolUse") | ensure("PostToolUse") | ensure("PermissionRequest") | ensure("Stop") | ensure("Interrupt")' "$file" > "$tmp"
    mv "$tmp" "$file"
    log_ok "Project Codex hooks installed. Trust this project and approve the exact definitions in Codex /hooks. No trust settings were changed."
    log_info "Older/unsupported clients: continue using aib start codex. SessionEnd records only metadata (no LLM summary)."
)

cmd_hook_native_codex() (
    # All output except SessionStart context and Stop JSON is intentionally empty.
    local payload event native sid wrapped=false i tmp state
    payload=$(head -c 65536)
    event=$(printf '%s' "$payload" | jq -er '.hook_event_name | select(type=="string")' 2>/dev/null) || exit 0
    [ "$event" != Stop ] || printf '{}\n'
    native=$(printf '%s' "$payload" | jq -er '.session_id | select(type=="string" and length>0 and length<512)' 2>/dev/null) || exit 0
    # Project hooks run in the project cwd. Refuse writes through user-controlled symlinks.
    [ -f AGENTS.md ] || exit 0
    for i in sessions sessions/.live sessions/.live/native SESSIONS.md; do [ ! -L "$i" ] || exit 0; done
    mkdir -p sessions/.live/native
    # Bounded project-wide serialization; hooks in one event run concurrently.
    local lock=sessions/.live/native/index.lock acquired=false
    for i in {1..20}; do
        if mkdir "$lock" 2>/dev/null; then acquired=true; break; fi
        sleep 0.05
    done
    $acquired || exit 0
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT
    sid="codex-native-$(printf '%s' "$native" | shasum -a 256 | cut -d ' ' -f1)"
    if [ "${AIB_WRAPPER_ROOT:-}" = "$(pwd -P)" ] && [[ "${AIB_WRAPPER_SESSION_ID:-}" =~ ^codex-[a-zA-Z0-9-]+$ ]] && [ -f "sessions/${AIB_WRAPPER_SESSION_ID}.md" ]; then
        sid="$AIB_WRAPPER_SESSION_ID"; wrapped=true
    fi
    local ctx="sessions/${sid}.md"
    [ ! -L "$ctx" ] || exit 0
    case "$event" in
        SessionStart)
            ensure_sessions_md
            if [ ! -f "$ctx" ]; then
                # No substitution of arbitrary task text into sed expressions.
                sed -e "s/{{SESSION_ID}}/$sid/g" -e 's/{{CLIENT_NAME}}/Codex CLI/g' \
                    -e "s/{{STARTED}}/$(date '+%Y-%m-%d %H:%M')/g" -e 's/{{TASK}}/(pending)/g' \
                    "$TEMPLATE_DIR/session-context.md" > "$ctx"
            elif ! $wrapped; then
                _sed_inplace "$ctx" -e 's/^- \*\*Status\*\*: completed/- **Status**: active/' -e 's/^- \*\*Ended\*\*:.*/- **Ended**: (active)/'
            fi
            if ! grep -qF "| $sid |" SESSIONS.md; then
                printf '| %s | Codex CLI | %s | %s | (starting) |\n' "$sid" "$(date '+%m-%d %H:%M')" "$(date '+%m-%d %H:%M')" >> SESSIONS.md
            fi
            printf '[AIB SESSION] Your session file: %s/%s\nUpdate Task, Log, Decisions and Blockers during meaningful work. Do not use shared sessions/.active for identity.\n' "$(pwd -P)" "$ctx"
            state=working ;;
        SessionEnd)
            [ -f "$ctx" ] || exit 0
            if ! $wrapped; then
                tmp=$(mktemp sessions/.live/native/.index.XXXXXX)
                grep -vF "| $sid |" SESSIONS.md > "$tmp" || true
                mv "$tmp" SESSIONS.md
                _sed_inplace "$ctx" -e 's/^- \*\*Status\*\*: active/- **Status**: completed/' \
                    -e "s/^- \*\*Ended\*\*: (active)/- **Ended**: $(date '+%Y-%m-%d %H:%M')/"
            fi
            state=done ;;
        PermissionRequest) state=blocked ;;
        Stop) state=done ;;
        Interrupt) state=done ;;
        UserPromptSubmit|PreToolUse|PostToolUse) state=working ;;
        *) exit 0 ;;
    esac
    [ -f "$ctx" ] || exit 0
    AIB_LIVE_CLIENT=codex aib_live_write "$sid" "$state" "$event" native_hook || true
)
