# aib update: is a newer aib out, and update it. Sourced by aib.
# aib had no way to tell (2026-11-25: a Mac stayed on Homebrew's 1.3.4 while
# 1.6.1 was out — its tap checkout had stopped at 1.4.0 without `brew update`).
# Homebrew only knows a release once its local copy of the tap is refreshed
# (`brew update`, by itself at most once a day before install/upgrade), so
# aib asks GitHub. `aib update` and `aib doctor` ask at once; in a terminal,
# a few commands ask at most once a day in the background and say so next
# time (`_aib_update_notice`). Nothing waits for it; hooks never ask.

AIB_LATEST_URL="${AIB_LATEST_URL:-https://api.github.com/repos/ai-barracks/ai-barracks/releases/latest}"
AIB_TAP="ai-barracks/ai-barracks"
AIB_TAP_FORMULA="$AIB_TAP/ai-barracks"
# Line 1: when GitHub was last asked (epoch seconds); line 2: the newest aib then.
AIB_UPDATE_CACHE="${AIB_UPDATE_CACHE:-$HOME/.aib/latest-release}"
AIB_UPDATE_CHECK_SECS="${AIB_UPDATE_CHECK_SECS:-86400}"

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
    _aib_update_verify "$latest"
}

# The aib Homebrew links (prefix/bin/aib), else the one on PATH.
_aib_updated_bin() {
    local self
    self="$(realpath "$SCRIPT_DIR/aib" 2>/dev/null || true)"
    case "$self" in */Cellar/ai-barracks/*) echo "${self%%/Cellar/ai-barracks/*}/bin/aib"; return 0 ;; esac
    command -v aib 2>/dev/null || true
}

# Homebrew answers "already installed" and exits 0 while its tap has not got
# the release yet (the tap follows a release): say so instead of "updated".
_aib_update_verify() {
    local latest="$1" bin now=""
    bin="$(_aib_updated_bin)"
    [ -z "$bin" ] || now="$("$bin" version 2>/dev/null | sed -n 's/^aib v//p' | head -1 || true)"
    if [ -z "$now" ] || _aib_version_lt "$now" "$latest"; then
        log_warn "Homebrew still has aib ${now:-?}, not $latest: its tap has not got $latest yet (it follows a release). Try again later: aib update"
        exit 1
    fi
    log_ok "aib $now installed. Then run aib sync in each barrack (CommandCenter: 모두 Sync)"
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
    _aib_doctor_brew_taps "$latest"
}

# Homebrew's side for aib doctor: its copy of the official tap may be behind
# GitHub, and an older tap with the same formula makes the plain name
# ambiguous ("Formulae found in multiple taps"). AIB_BREW_REPOSITORY replaces
# `brew --repository` (tests).
_aib_doctor_brew_taps() {
    local latest="$1" repo="${AIB_BREW_REPOSITORY:-}" f tap version
    if [ -z "$repo" ]; then
        command -v brew >/dev/null 2>&1 || return 0
        repo="$(brew --repository 2>/dev/null || true)"
    fi
    for f in "$repo"/Library/Taps/*/homebrew-*/Formula/ai-barracks.rb "$repo"/Library/Taps/*/homebrew-*/ai-barracks.rb; do
        [ -f "$f" ] || continue
        tap="$(echo "$f" | sed -E 's#.*/Library/Taps/([^/]+)/homebrew-([^/]+)/.*#\1/\2#')"
        if [ "$tap" != "$AIB_TAP" ]; then
            log_warn "Homebrew tap $tap also has ai-barracks (an older tap; plain \`brew upgrade ai-barracks\` cannot choose). After aib update: brew untap $tap"
            continue
        fi
        version="$(sed -nE 's#.*/v([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz.*#\1#p' "$f" | head -1)"
        if [ -n "$latest" ] && [ -n "$version" ] && _aib_version_lt "$version" "$latest"; then
            log_info "Homebrew's copy of $tap still has aib $version: Homebrew sees $latest after brew update (aib update runs it first)"
        fi
    done
    return 0
}

# --- the daily notice ---

_aib_cache_line() { sed -n "${1}p" "$AIB_UPDATE_CACHE" 2>/dev/null || true; }

# Now, and the given release, written whole (readers never see half a file).
_aib_write_latest_cache() {
    local tmp="$AIB_UPDATE_CACHE.$$"
    mkdir -p "$(dirname "$AIB_UPDATE_CACHE")" 2>/dev/null || return 0
    if printf '%s\n%s\n' "$(date +%s)" "$1" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$AIB_UPDATE_CACHE"; else rm -f "$tmp"; fi
}

# Ask GitHub and write the cache (an offline lookup keeps the known release).
_aib_refresh_latest_cache() {
    local latest
    latest="$(_aib_latest_version)"
    [ -n "$latest" ] || latest="$(_aib_cache_line 2)"
    _aib_write_latest_cache "$latest"
}

# In a terminal: one line when the last lookup found a newer aib, and a new
# lookup in the background once a day. Off with AIB_NO_UPDATE_CHECK=1.
_aib_update_notice() {
    [ -z "${AIB_NO_UPDATE_CHECK:-}" ] || return 0
    [ "${AIB_ASSUME_TTY:-}" = 1 ] || [ -t 2 ] || return 0
    local known checked
    known="$(_aib_cache_line 2)"
    if [ -n "$known" ] && _aib_version_lt "$AIB_VERSION" "$known"; then
        log_warn "aib $known is out (installed: $AIB_VERSION) — aib update"
    fi
    checked="$(_aib_cache_line 1)"
    case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
    if [ $(( $(date +%s) - checked )) -ge "$AIB_UPDATE_CHECK_SECS" ]; then
        # Stamp first: CommandCenter starts many panes at once, one lookup is enough.
        _aib_write_latest_cache "$known"
        ( _aib_refresh_latest_cache ) </dev/null >/dev/null 2>&1 &
    fi
    return 0
}
