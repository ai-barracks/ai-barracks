#!/usr/bin/env bash
# aib update (2026-11-25: aib had no way to tell a newer release was out; a
# Mac stayed on 1.3.4 from Homebrew, whose tap checkout had stopped at 1.4.0).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AIB="$ROOT/bin/aib"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
export HOME="$TMP/home"; mkdir -p "$HOME"
# Doctor reads Homebrew's taps from here (not this Mac's Homebrew).
export AIB_BREW_REPOSITORY="$TMP/no-brew"
current="$("$AIB" version | sed 's/^aib v//')"
newer="99.0.0"

# The version order is numeric (1.10.0 is newer than 1.9.9).
AIB_SOURCE_ONLY=1 bash -c "source '$AIB'; _aib_version_lt 1.9.9 1.10.0 && ! _aib_version_lt 1.10.0 1.9.9 && ! _aib_version_lt 1.6.1 1.6.1" \
    || fail "version order"

# 1. Up to date: says so, succeeds, runs nothing.
out="$(AIB_LATEST_VERSION="$current" AIB_UPDATE_CMD="touch '$TMP/ran'" "$AIB" update 2>&1)" || fail "up to date failed: $out"
echo "$out" | grep -q "latest" || fail "up to date not reported: $out"
[ ! -e "$TMP/ran" ] || fail "updated while up to date"

# 2. GitHub unreachable: says so, fails.
if AIB_LATEST_VERSION="" AIB_LATEST_URL="http://127.0.0.1:9/none" "$AIB" update >/dev/null 2>&1; then fail "unreachable GitHub reported as success"; fi

# 3. Newer, Homebrew install, no terminal: shows the command, does not run it.
export AIB_LATEST_VERSION="$newer" AIB_INSTALL_KIND=brew AIB_UPDATE_CMD="touch '$TMP/ran'"
if out="$("$AIB" update 2>&1 </dev/null)"; then fail "update without a terminal reported success"; fi
echo "$out" | grep -q "$newer" || fail "newer version not named: $out"
echo "$out" | grep -q "touch" || fail "update command not shown: $out"
[ ! -e "$TMP/ran" ] || fail "updated without asking"

# 4. Newer, in a terminal: n does nothing, y runs the update. The aib on PATH
#    afterwards (a stand-in for Homebrew's) says which version got installed.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nif [ -e "%s" ]; then echo "aib v%s"; else echo "aib v%s"; fi\n' "$TMP/ran" "$newer" "$current" > "$TMP/bin/aib"
chmod +x "$TMP/bin/aib"; export PATH="$TMP/bin:$PATH"
printf 'n\n' | AIB_ASSUME_TTY=1 "$AIB" update >/dev/null 2>&1 || true
[ ! -e "$TMP/ran" ] || fail "updated after n"
printf 'y\n' | AIB_ASSUME_TTY=1 "$AIB" update > "$TMP/y.log" 2>&1 || fail "update (y) failed: $(cat "$TMP/y.log")"
[ -e "$TMP/ran" ] || fail "update command did not run after y"
grep -q "aib sync" "$TMP/y.log" || fail "no hint to sync barracks after the update: $(cat "$TMP/y.log")"

# 4b. The release is out but Homebrew's tap has not got it yet: brew says
#     "already installed" and exits 0 — not reported as updated.
rm -f "$TMP/ran"
export AIB_UPDATE_CMD="true"
if printf 'y\n' | AIB_ASSUME_TTY=1 "$AIB" update > "$TMP/lag.log" 2>&1; then fail "an update that installed nothing reported success: $(cat "$TMP/lag.log")"; fi
grep -q "aib updated\|installed. Then" "$TMP/lag.log" && fail "said updated while still on $current: $(cat "$TMP/lag.log")"
grep -q "$current" "$TMP/lag.log" && grep -q "later" "$TMP/lag.log" || fail "lag not explained: $(cat "$TMP/lag.log")"
export AIB_UPDATE_CMD="touch '$TMP/ran'"

# 5. Not a Homebrew install: explains instead of guessing.
rm -f "$TMP/ran"
if out="$(printf 'y\n' | AIB_ASSUME_TTY=1 AIB_INSTALL_KIND=other "$AIB" update 2>&1)"; then fail "non-Homebrew update reported success"; fi
[ ! -e "$TMP/ran" ] || fail "ran the Homebrew update on a non-Homebrew install"
echo "$out" | grep -q "brew install ai-barracks/ai-barracks/ai-barracks" || fail "no way forward shown: $out"

# 6. The Homebrew command names the official tap (an older tap may hold the same name).
AIB_SOURCE_ONLY=1 bash -c "unset AIB_UPDATE_CMD; source '$AIB'; _aib_update_command" | grep -q "brew upgrade ai-barracks/ai-barracks/ai-barracks" \
    || fail "update command does not name the official tap"

# 7. aib doctor names a newer release.
out="$("$AIB" doctor 2>&1 || true)"
echo "$out" | grep -q "$newer" || fail "doctor did not name the newer aib: $out"

# 8. aib doctor explains Homebrew's side: its copy of the tap is behind
#    (seen 2026-11-25: stuck at 1.4.0 since October), and an older tap with
#    the same formula makes `brew upgrade ai-barracks` ambiguous.
BREW="$TMP/brew"
mkdir -p "$BREW/Library/Taps/ai-barracks/homebrew-ai-barracks/Formula" "$BREW/Library/Taps/olduser/homebrew-ai-barracks/Formula"
echo '  url "https://github.com/ai-barracks/ai-barracks/archive/refs/tags/v1.4.0.tar.gz"' > "$BREW/Library/Taps/ai-barracks/homebrew-ai-barracks/Formula/ai-barracks.rb"
cp "$BREW/Library/Taps/ai-barracks/homebrew-ai-barracks/Formula/ai-barracks.rb" "$BREW/Library/Taps/olduser/homebrew-ai-barracks/Formula/"
out="$(AIB_BREW_REPOSITORY="$BREW" "$AIB" doctor 2>&1 || true)"
echo "$out" | grep -q "1.4.0" && echo "$out" | grep -q "brew update" || fail "doctor did not say Homebrew's tap copy is behind: $out"
echo "$out" | grep -q "brew untap olduser/ai-barracks" || fail "doctor did not name the older tap: $out"
echo "$out" | grep -q "untap ai-barracks/ai-barracks" && fail "doctor told to untap the official tap: $out"

echo "PASS: aib update (latest check, asks first, Homebrew only, official tap, verified, sync hint, doctor, taps)"
