# Multi-AI Platform (MAP)

Cross-client LLM session sharing and persistent memory system.

Any LLM (Claude, Gemini, Codex) across any interface shares sessions and knowledge through simple markdown files.

## Quick Start

```bash
# Install (coming soon)
brew tap CYRok90/multi-ai-platform
brew install multi-ai-platform

# Initialize a workspace
map init ~/my-project

# Start a tracked LLM session
map start claude "building feature X"

# Check active sessions and wiki
map status

# Re-sync protocol to config files
map sync
```

## What it creates

```
your-project/
├── CLAUDE.md        # Protocol injected
├── GEMINI.md        # Protocol injected
├── AGENTS.md        # Protocol injected
├── SESSIONS.md      # Active session registry (gitignored)
└── wiki/            # Persistent knowledge base
    ├── Index.md     # Topic catalog
    ├── Log.md       # Chronological change log
    └── topics/      # Individual knowledge pages
```

## How it works

### Session Layer (SESSIONS.md)
- Session start: register yourself, see what other sessions are doing
- Session end: unregister (or `map start` wrapper handles it via trap)
- Stale entries (>2h) are auto-cleaned by the next session

### Memory Layer (wiki/)
- Karpathy-style LLM-maintained wiki ([reference](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f))
- LLMs discover knowledge during work and write it to topic pages
- Index.md is the only mandatory read on session start (token-efficient)
- Topics are loaded selectively, not all at once

### Protocol
The same protocol is injected into CLAUDE.md, GEMINI.md, and AGENTS.md.
Every LLM follows identical rules regardless of which client is used.

## Commands

| Command | Description |
|---------|-------------|
| `map init [path]` | Initialize workspace with sessions + wiki |
| `map start <claude\|gemini\|codex> [task]` | Start tracked session |
| `map status` | Show active sessions and wiki stats |
| `map sync` | Re-inject protocol into config files |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Workspace                        │
│  SESSIONS.md + wiki/ + CLAUDE.md + GEMINI.md + AGENTS.md │
└────────┬──────────────┬──────────────┬──────────────────┘
         │              │              │
    ┌────▼────┐   ┌─────▼─────┐  ┌────▼────┐
    │ Claude  │   │  Gemini   │  │  Codex  │    ← Desktop (CLI)
    │  Code   │   │   CLI     │  │   CLI   │
    └─────────┘   └───────────┘  └─────────┘
                        │
              ┌─────────▼──────────┐
              │  slack-agent-bridge │              ← Mobile (Slack Bot)
              │  (Mac Mini daemon)  │
              └─────────┬──────────┘
                        │
              ┌─────────▼──────────┐
              │   Slack App        │
              │  (Phone/Tablet)    │
              └────────────────────┘
```

### Desktop: CLI 직접 사용
`map start claude` → CLI가 프로토콜에 따라 SESSIONS.md 등록, wiki 참조, 세션 종료 시 해제.
대화형 세션이므로 LLM이 직접 파일을 읽고 쓸 수 있다.

### Mobile: Slack Bot 경유
모바일 디바이스에서는 Slack을 통해 접근한다.
CLI는 `-p` 모드(원샷 실행)로 동작하므로 LLM이 직접 프로토콜을 따를 수 없다.
따라서 **bridge가 프로토콜을 대신 처리**한다:

1. Slack 스레드 생성 → bridge가 SESSIONS.md에 세션 등록
2. 메시지 수신 → bridge가 wiki/Index.md + 관련 토픽을 프롬프트에 주입 → CLI `-p` 실행
3. 응답에서 새 지식 발견 → bridge가 wiki/topics/ 업데이트
4. 스레드 만료(TTL) → bridge가 SESSIONS.md에서 세션 삭제

```
# bridge의 역할 (프로토콜 프록시)
Slack 메시지 → bridge가 wiki 컨텍스트 주입 → claude -p "{wiki context + user prompt}" → 응답
```

### Slack Bot 설정

[slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge)를 사용하여 Slack에서 LLM에 접근한다.

1. workspace를 `map init`으로 초기화
2. slack-agent-bridge의 `.env`에 워크스페이스 경로 설정:
   ```
   MAP_WORKSPACE_DIR=/path/to/your/workspace
   ```
3. bridge가 해당 경로의 SESSIONS.md와 wiki/를 관리

## Design Principles

- **File-based**: No database, no server, no infrastructure
- **Flat structure**: Everything at project root, no nested config paths
- **Optimistic concurrency**: Single user, low contention, append-preferred
- **Graceful degradation**: If an LLM ignores the protocol, nothing breaks
- **Token-efficient**: Read Index.md (~750 tokens), load only relevant topics

## License

MIT
