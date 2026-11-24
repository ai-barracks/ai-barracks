# aib update: is a newer aib out, and update it. Sourced by aib.
# aib had no way to tell (2026-11-25: a Mac stayed on Homebrew's 1.3.4 while
# 1.6.1 was out — its tap checkout had stopped at 1.4.0 without `brew update`).
# Only `aib update` and `aib doctor` reach the network; start/hooks never do.

AIB_LATEST_URL="${AIB_LATEST_URL:-https://api.github.com/repos/ai-barracks/ai-barracks/releases/latest}"
AIB_TAP_FORMULA="ai-barracks/ai-barracks/ai-barracks"

# The newest published aib ("1.6.2"), or nothing when GitHub is unreachable.
# AIB_LATEST_VERSION replaces the lookup (tests).
_aib_latest_version() {
    if [ -n "${AIB_LATEST_VERSION+x}" ] && [ -n "$AIB_LATEST_VERSION" ]; then echo "$AIB_LATEST_VERSION"; return 0; fi
    curl -fsSL --max-time 5 -H 'Accept: application/vnd.github+json' "$AIB_LATEST_URL" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//' || true
}

# a < b, numerically per part (1.9.9 < 1.10.0).
_aib_version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# brew: this aib is Homebrew's (its file is in a Cellar); other: anything else.
# AIB_INSTALL_KIND replaces the check (tests).
_aib_install_kind() {
    if [ -n "${AIB_INSTALL_KIND:-}" ]; then echo "$AIB_INSTALL_KIND"; return 0; fi
    case "$(realpath "$SCRIPT_DIR/aib" 2>/dev/null)" in
        */Cellar/ai-barracks/*) echo brew ;;
        *) echo other ;;
    esac
}

# The official tap by full name: an older tap may hold a formula of the same name.
_aib_update_command() {
    echo "${AIB_UPDATE_CMD:-brew update && brew upgrade $AIB_TAP_FORMULA}"
}

cmd_update() {
    local latest how answer
    latest="$(_aib_latest_version)"
    if [ -z "$latest" ]; then log_err "Could not reach GitHub to check the latest aib"; exit 1; fi
    if ! _aib_version_lt "$AIB_VERSION" "$latest"; then
        log_ok "aib $AIB_VERSION is the latest"
        return 0
    fi
    log_info "aib $latest is out (installed: $AIB_VERSION)"
    if [ "$(_aib_install_kind)" != brew ]; then
        log_warn "This aib was not installed with Homebrew: $(realpath "$SCRIPT_DIR/aib" 2>/dev/null || echo "$SCRIPT_DIR/aib")"
        log_info "To update with Homebrew from now on, remove that file, then: brew install $AIB_TAP_FORMULA"
        exit 1
    fi
    how="$(_aib_update_command)"
    if ! _aib_can_ask; then
        log_info "Update in a terminal with: $how   (or: aib update)"
        exit 1
    fi
    printf 'Update aib to %s with `%s`? [y/N] ' "$latest" "$how" >&2
    read -r answer || answer=""
    case "$answer" in y|Y|yes|YES|Yes) ;; *) log_info "Not updated. Later: aib update"; exit 1 ;; esac
    bash -c "$how" || { log_err "Update failed"; exit 1; }
    log_ok "aib updated. Then run aib sync in each barrack (CommandCenter: 모두 Sync)"
}

# aib doctor's line about the installed aib and the newest one.
_aib_doctor_self() {
    local latest
    log_info "aib $AIB_VERSION ($(realpath "$SCRIPT_DIR/aib" 2>/dev/null || echo "$SCRIPT_DIR/aib"), $(_aib_install_kind))"
    latest="$(_aib_latest_version)"
    if [ -z "$latest" ]; then
        log_warn "aib: could not check the latest release (offline?)"
    elif _aib_version_lt "$AIB_VERSION" "$latest"; then
        log_warn "aib $latest is out — aib update"
    else
        log_ok "aib is the latest"
    fi
}
