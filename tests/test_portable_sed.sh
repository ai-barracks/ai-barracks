#!/usr/bin/env bash
# Portable in-place sed. BSD `-i ''` is a silent no-op on GNU/Linux (the form `sed`+`-i`+`''`
# leaves the file unchanged AND swallows the script as a filename). The codebase targets both
# macOS and Linux (cleanup_stale has a `date -d` GNU fallback), so all in-place edits must use
# the portable tmp+mv helper `_sed_inplace`. This is the only portability proof available
# without a Linux CI runner: (1) the mechanism is platform-identical, (2) no BSD-only form remains.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIB_BIN="${SCRIPT_DIR}/../bin/aib"
fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

AIB_SOURCE_ONLY=1 source "$AIB_BIN"
set +e

# ---------- regression guard: no BSD-only in-place sed remains ----------
# (Comments must not contain the literal command form, or this guard self-trips.)
if grep -n "sed -i ''" "$AIB_BIN" >/dev/null 2>&1; then
  echo "FAIL: bin/aib still contains BSD-only in-place sed (GNU no-op):"
  grep -n "sed -i ''" "$AIB_BIN"
  exit 1
fi
pass "no BSD-only in-place sed remains in bin/aib"

# ---------- _sed_inplace: single expression ----------
printf 'foo\nbar\n' > f.txt
_sed_inplace f.txt -e 's/foo/FOO/'
[ "$(sed -n 1p f.txt)" = "FOO" ] || fail "single expr must substitute"
[ "$(sed -n 2p f.txt)" = "bar" ] || fail "other lines must be preserved"
pass "_sed_inplace single expr"

# ---------- _sed_inplace: multiple expressions in one pass ----------
printf 'a\nb\n' > f.txt
_sed_inplace f.txt -e 's/^a$/A/' -e 's/^b$/B/'
[ "$(cat f.txt)" = "$(printf 'A\nB')" ] || fail "multi -e must apply all"
pass "_sed_inplace multi expr"

# ---------- no leftover temp files ----------
[ -z "$(ls f.txt.* 2>/dev/null)" ] || fail "must not leave a .tmp sibling"
pass "_sed_inplace leaves no temp file"

# ---------- alt delimiter / slashes in replacement (url-like) ----------
printf 'url v1.3.1\n' > f.txt
_sed_inplace f.txt -e 's#v1\.3\.1#v1.3.2#'
[ "$(cat f.txt)" = "url v1.3.2" ] || fail "alt delimiter substitution"
pass "_sed_inplace alt delimiter"

# ---------- missing file → safe no-op, returns 0 (even under set -e) ----------
( set -e; _sed_inplace nope.txt -e 's/x/y/' ) || fail "missing file must be a no-op, not a failure"
pass "_sed_inplace missing-file no-op"

# ---------- content is otherwise byte-stable (only the match changes) ----------
printf '# title\n- **Status**: active\n- **Task**: t\n' > s.md
_sed_inplace s.md -e 's/^- \*\*Status\*\*: active/- **Status**: completed/'
[ "$(grep -c '^- \*\*Status\*\*: completed' s.md)" = "1" ] || fail "status flip must apply"
[ "$(grep -c '^- \*\*Task\*\*: t' s.md)" = "1" ] || fail "unrelated lines preserved"
[ "$(grep -c '^# title' s.md)" = "1" ] || fail "header preserved"
pass "_sed_inplace preserves unrelated content"

# ---------- preserves file mode (faithful `sed -i` drop-in; mktemp would leave 0600) ----------
printf 'v: 1\n' > m.txt
chmod 644 m.txt
_sed_inplace m.txt -e 's/1/2/'
mode="$(stat -f '%Lp' m.txt 2>/dev/null || stat -c '%a' m.txt 2>/dev/null)"
[ "$mode" = "644" ] || fail "must preserve original mode (got $mode, expected 644)"
[ "$(cat m.txt)" = "v: 2" ] || fail "content still edited"
pass "_sed_inplace preserves file mode"

echo "ALL PASS (test_portable_sed.sh)"
