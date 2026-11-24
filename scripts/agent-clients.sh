# Finding and installing the agent CLIs aib starts (claude, codex). Sourced by aib.
#
# A GUI app (CommandCenter) runs aib through a login shell, which skips
# ~/.zshrc — where the official installers put their folder on PATH. So on a
# new Mac aib could not find claude, and on another the app ran a stale
# Homebrew Claude (2.1.118) while the terminal ran ~/.local/bin's (2.1.331)
# (2026-11-25). aib looks on PATH first, then in the folders installers use.

# Folders installers put claude/codex in, most specific first.
# AIB_CLIENT_DIRS (colon-separated) replaces the list (tests, unusual setups).
_aib_client_dirs() {
    if [ -n "${AIB_CLIENT_DIRS+x}" ]; then
        printf '%s\n' "$AIB_CLIENT_DIRS" | tr ':' '\n'
        return 0
    fi
    printf '%s\n' "$HOME/.local/bin" "$HOME/.claude/local" /opt/homebrew/bin /usr/local/bin \
        "$HOME/.npm-global/bin" "$HOME/.volta/bin" "$HOME/.bun/bin" \
        "$HOME/.local/share/mise/shims" "$HOME/.asdf/shims"
    # nvm keeps one folder per Node version: newest first.
    { ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null || true; } | sort -r -V
}

# Every install of <client>, one line each: PATH's first, then the folders
# above; two names for one file (a symlink) count once.
_aib_client_all() {
    local name="$1" dir
    {
        command -v "$name" 2>/dev/null || true
        _aib_client_dirs | while IFS= read -r dir; do
            if [ -n "$dir" ] && [ -x "$dir/$name" ] && [ ! -d "$dir/$name" ]; then echo "$dir/$name"; fi
        done
    } | while IFS= read -r path; do
        case "$path" in /*) ;; *) continue ;; esac   # an alias or function name
        printf '%s\t%s\n' "$path" "$(cd "$(dirname "$path")" && realpath "$(basename "$path")" 2>/dev/null || echo "$path")"
    done | awk -F '\t' '!seen[$2]++ { print $1 }'
}

# The install aib runs: PATH's, else the first one found. Fails when none.
_aib_find_client() {
    local first
    first="$(_aib_client_all "$1" | head -1)"
    [ -n "$first" ] || return 1
    echo "$first"
}

_aib_client_version() {
    "$1" --version 2>/dev/null | head -1
}

# The command that installs <client> the official way, or nothing.
# AIB_INSTALL_<CLIENT>_CMD replaces it (an organization's own installer; tests).
_aib_install_command() {
    case "$1" in
        claude)
            if [ -n "${AIB_INSTALL_CLAUDE_CMD:-}" ]; then echo "$AIB_INSTALL_CLAUDE_CMD"
            elif command -v curl >/dev/null 2>&1; then echo "curl -fsSL https://claude.ai/install.sh | bash"
            fi ;;
        codex)
            if [ -n "${AIB_INSTALL_CODEX_CMD:-}" ]; then echo "$AIB_INSTALL_CODEX_CMD"
            elif command -v brew >/dev/null 2>&1; then echo "brew install --cask codex"
            elif command -v npm >/dev/null 2>&1; then echo "npm install -g @openai/codex"
            fi ;;
    esac
}

# A person can answer: stdin and stderr are a terminal (AIB_ASSUME_TTY=1 in tests).
_aib_can_ask() {
    [ "${AIB_ASSUME_TTY:-}" = 1 ] || { [ -t 0 ] && [ -t 2 ]; }
}

# A missing client: in a terminal, ask and install; otherwise say how.
# Returns 0 only when the client is there afterwards.
_aib_offer_install() {
    local client="$1" name how answer
    name="$(client_name "$client")"
    how="$(_aib_install_command "$client")"
    log_warn "$name is not installed (not on PATH, nor in the usual install folders)"
    if [ -z "$how" ]; then
        log_err "No way to install $name here: install curl, Homebrew or npm first"
        return 1
    fi
    if ! _aib_can_ask; then
        log_info "Install it in a terminal with: $how   (or: aib install $client)"
        return 1
    fi
    printf 'Install %s now with `%s`? [y/N] ' "$name" "$how" >&2
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES|Yes) ;;
        *) log_info "Not installed. Later: aib install $client"; return 1 ;;
    esac
    bash -c "$how" || { log_err "Installing $name failed"; return 1; }
    local path
    path="$(_aib_find_client "$client")" || { log_err "$name installed, but aib cannot find it — open a new terminal and run: aib doctor"; return 1; }
    log_ok "$name installed: $path"
}

# aib install <claude|codex>
cmd_install() {
    local client="${1:-}" path
    case "$client" in claude|codex) ;; *) log_err "Usage: aib install <claude|codex>"; exit 1 ;; esac
    if path="$(_aib_find_client "$client")"; then
        log_ok "$(client_name "$client") is already installed: $path ($(_aib_client_version "$path"))"
        return 0
    fi
    _aib_offer_install "$client" || exit 1
}

# One client's report for aib doctor: each install, the one aib runs first.
_aib_doctor_client() {
    local client="$1" name all count versions path version
    name="$(client_name "$client")"
    all="$(_aib_client_all "$client")"
    if [ -z "$all" ]; then
        log_warn "$name: not installed — aib install $client"
        return 0
    fi
    count="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
    versions=""
    while IFS= read -r path; do
        version="$(_aib_client_version "$path")"
        versions="$versions$version"$'\n'
        if [ "$path" = "$(printf '%s\n' "$all" | head -1)" ]; then
            log_ok "$name: $path ($version) — aib runs this one"
        else
            log_info "  also: $path ($version)"
        fi
    done <<<"$all"
    if [ "$count" -gt 1 ] && [ "$(printf '%s' "$versions" | sort -u | grep -c .)" -gt 1 ]; then
        log_warn "$name: $count installs with different versions — a GUI app may run another one than your terminal. Remove the one you do not use."
    fi
}

# aib doctor: what aib and CommandCenter will run on this Mac.
cmd_doctor() {
    log_info "aib $AIB_VERSION ($SCRIPT_DIR/aib)"
    if command -v jq >/dev/null 2>&1; then log_ok "jq: $(command -v jq)"; else log_err "jq: not installed (brew install jq)"; fi
    _aib_doctor_client claude
    _aib_doctor_client codex
    _aib_doctor_hooks
}

# Hook wiring for aib doctor (Claude: user settings; Codex: user hooks.json).
_aib_doctor_hooks() {
    local claude_settings="${AIB_CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
    if jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(. == "aib hook start claude")' "$claude_settings" >/dev/null 2>&1; then
        log_ok "Claude hooks: $claude_settings"
    else
        log_warn "Claude hooks: not set — run aib init in a barrack"
    fi
    local codex_hooks
    codex_hooks="$(_aib_codex_user_hooks_file)"
    if _aib_codex_hooks_present "$codex_hooks"; then
        log_ok "Codex hooks: $codex_hooks — trust them once in Codex: /hooks"
    else
        log_warn "Codex hooks: not set — aib hooks codex install --user"
    fi
}
