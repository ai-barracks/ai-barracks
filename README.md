# Multi-AI Platform (MAP)

Cross-client LLM session sharing and persistent memory system.

Any LLM (Claude, Gemini, Codex) across any interface shares sessions and knowledge through simple markdown files.

## Quick Start

```bash
brew tap CYRok90/multi-ai-platform
brew install multi-ai-platform

map init ~/my-project       # Initialize workspace + auto-configure hooks
map start claude "my task"  # Or just run `claude` directly (hooks handle it)
map status                  # Show active sessions and wiki
```

## What it creates

```
your-project/
├── CLAUDE.md        # Protocol injected
├── GEMINI.md        # Protocol injected
├── AGENTS.md        # Protocol injected
├── SESSIONS.md      # Session index (gitignored)
├── sessions/        # Session history (permanent record)
│   ├── claude-20260405-2230.md
│   └── gemini-20260405-2245.md
└── wiki/            # Persistent knowledge base
    ├── Index.md     # Topic catalog
    ├── Log.md       # Chronological change log
    └── topics/      # Individual knowledge pages
```

## 3-Layer Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Session Index (SESSIONS.md)                            │
│  "지금 누가 무엇을 하고 있나" — 실시간 활성 세션 레지스트리           │
├──────────────────────────────────────────────────────────────────┤
│  Layer 2: Session History (sessions/*.md)                        │
│  "그때 무슨 일이 있었나" — 조선실록처럼 영구 보존되는 세션 기록        │
├──────────────────────────────────────────────────────────────────┤
│  Layer 3: Memory / Wiki (wiki/)                                  │
│  "우리가 알고 있는 것" — Karpathy LLM-Wiki 패턴의 장기 지식          │
└──────────────────────────────────────────────────────────────────┘
```

### Layer 1: Session Index (SESSIONS.md)
- 활성 세션 목록 (누가, 언제, 무엇)
- Hook이 자동으로 등록/해제
- 2시간 이상 업데이트 없으면 stale로 자동 정리

### Layer 2: Session History (sessions/)
- 세션별 상세 기록: Log (작업 실록), Decisions, Blockers
- 세션 종료 시 auto-summary 생성
- **영구 보존** — 나중에 "그때 뭘 했지?" 찾아볼 수 있음
- Cross-CLI handoff: 다른 CLI가 이전 세션 파일을 읽고 이어받기

### Layer 3: Memory / Wiki (wiki/)
- [Karpathy LLM-Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) 패턴
- 세션 종료 시 wiki로 추출할 지식을 식별하여 topics/에 저장
- Index.md만 읽고 필요한 토픽만 선택 로딩 (토큰 효율)

## Session Lifecycle (Hook 기반 자동화)

```
SessionStart Hook                    세션 진행 중                    SessionEnd Hook
─────────────────                    ──────────────                  ─────────────────
┌─ 스크립트가 자동 처리 ─┐           ┌─ LLM이 직접 처리 ─┐          ┌─ 스크립트가 자동 처리 ─┐
│ 1. Stale 세션 정리     │           │ • Log에 작업 기록  │          │ 1. SESSIONS.md 항목 삭제│
│ 2. SESSIONS.md 등록    │           │ • Decisions 기록   │          │ 2. Status → completed  │
│ 3. sessions/{id}.md 생성│          │ • Blockers 기록    │          │ 3. Ended 타임스탬프     │
│ 4. 이전 세션 미추출 알림 │          │ • wiki 업데이트    │          │ 4. Auto-summary 생성   │
│ 5. 활성 세션 컨텍스트   │           └────────────────────┘          └─────────────────────────┘
│    stdout → LLM 주입   │
└─────────────────────────┘                                          다음 SessionStart에서:
                                                                     → Wiki Extractions 비어있으면
                                                                       LLM에게 추출 요청
```

**핵심 원칙**: hook end는 기계적 정리만, hook start는 LLM 컨텍스트 주입 담당.
세션 종료 시점에는 LLM이 이미 끝나므로 지적 작업(wiki 추출)은 다음 세션 시작 시 처리.

### Hook 설정

`map init`이 CLI별 hook을 자동 감지 + 설정한다:

| CLI | SessionStart | SessionEnd | 비고 |
|-----|-------------|-----------|------|
| Claude Code | `map hook start claude` | `map hook end claude` | 자동 설정 |
| Gemini CLI | `map hook start gemini` | `map hook end gemini` | 자동 설정 |
| Codex CLI | — | — | `map start codex` 래퍼 사용 |

### Cross-CLI Session Handoff

```bash
# Claude에서 작업 중 rate limit 발생
# → Gemini에서 이어받기:
map hook continue claude-20260405-2230
# → 이전 세션의 Log, Decisions, Blockers가 컨텍스트로 주입됨
```

## Commands

| Command | Description |
|---------|-------------|
| `map init [path]` | Initialize workspace + auto-configure hooks |
| `map start <client> [task]` | Start tracked session (wrapper) |
| `map hook start <client>` | (Auto) Called by CLI SessionStart hooks |
| `map hook end <client>` | (Auto) Called by CLI SessionEnd hooks |
| `map hook continue <session_id>` | Continue another CLI's session |
| `map status` | Show active sessions and wiki stats |
| `map sync` | Re-inject protocol into config files |

## Access Methods

```
┌─────────────────────────────────────────────────────────┐
│                    Your Workspace                        │
│  SESSIONS.md + sessions/ + wiki/ + CLAUDE/GEMINI/AGENTS  │
└────────┬──────────────┬──────────────┬──────────────────┘
         │              │              │
    ┌────▼────┐   ┌─────▼─────┐  ┌────▼────┐
    │ Claude  │   │  Gemini   │  │  Codex  │    ← Desktop (CLI)
    │  Code   │   │   CLI     │  │   CLI   │      Hook이 자동 처리
    └─────────┘   └───────────┘  └─────────┘
                        │
              ┌─────────▼──────────┐
              │  slack-agent-bridge │              ← Mobile (Slack Bot)
              │  (Mac Mini daemon)  │                bridge가 프록시 처리
              └─────────┬──────────┘
                        │
              ┌─────────▼──────────┐
              │   Slack App        │
              │  (Phone/Tablet)    │
              └────────────────────┘
```

### Desktop: CLI 직접 사용
`claude` 실행 → SessionStart hook이 자동으로 세션 등록 + wiki 컨텍스트 주입.
세션 종료 → SessionEnd hook이 자동으로 정리 + auto-summary 생성.

### Mobile: Slack Bot 경유
[slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge)가 프로토콜을 대신 처리:

1. Slack 메시지 수신 → SESSIONS.md 등록 + wiki 컨텍스트 프롬프트 주입
2. CLI `-p` 실행 → 응답 반환
3. 스레드 만료 → SESSIONS.md 정리

```bash
# bridge .env 설정
MAP_WORKSPACE_DIR=/path/to/your/workspace
```

## Design Principles

- **File-based**: No database, no server, no infrastructure
- **Hook-enforced**: LLM이 프로토콜을 무시해도 hook이 강제 관리
- **Permanent history**: sessions/는 삭제하지 않는 영구 기록 (조선실록)
- **Knowledge extraction**: 세션 → wiki 추출로 지식이 누적
- **Cross-CLI**: 어떤 CLI에서든 이전 세션을 이어받을 수 있음
- **Token-efficient**: Index.md (~750 tokens)만 필수, 나머지 선택 로딩

## License

MIT
