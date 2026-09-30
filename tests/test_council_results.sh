#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
parser="$ROOT/scripts/council-result.jq"
parse() { jq -es --arg provider "$1" -f "$parser"; }
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"hello","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":5}}' | parse claude | jq -e '.text=="hello" and .tokens.available and .tokens.total==35' >/dev/null
for record in '{"type":"result","result":"partial"}' '{"type":"result","subtype":"error","is_error":true,"result":"partial"}' '{}'; do
    if printf '%s' "$record" | parse claude 2>/dev/null; then exit 1; fi
done
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20,"cached_input_tokens":5}}' | parse codex | jq -e '.text=="hello" and .tokens.available and .tokens.total==30' >/dev/null
printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}' '{"type":"turn.completed"}' | parse codex | jq -e '.tokens.available == false' >/dev/null
for tail in '{"type":"turn.failed"}' '{"type":"error"}' '{"type":"item.completed","item":{"type":"command_execution"}}'; do
    if printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}' '{"type":"turn.completed"}' "$tail" | parse codex 2>/dev/null; then exit 1; fi
done
echo 'PASS: Council terminal success and per-call usage contracts'
