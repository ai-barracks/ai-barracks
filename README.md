# AI Barracks (AIB)

Cross-client LLM session sharing and persistent memory system.

Any LLM (Claude, Gemini, Codex) across any interface shares sessions and knowledge through simple markdown files. A git repo initialized with `aib init` becomes a **barrack** — a base from which AI agents are deployed on missions.

## Quick Start

```bash
brew tap CYRok90/ai-barracks
brew install ai-barracks

aib init ~/my-project       # Initialize barrack + auto-configure hooks
aib start claude "my task"  # Or just run `claude` directly (hooks handle it)
aib status                  # Show active agents and wiki
```

## What it creates

```
your-barrack/
├── CLAUDE.md        # Protocol injected
├── GEMINI.md        # Protocol injected
├── AGENTS.md        # Protocol injected
├── SESSIONS.md      # Session index (gitignored)
├── sessions/        # Session history (영구 기록 — 조선실록)
│   ├── claude-20260405-2230.md
│   └── gemini-20260405-2245.md
└── wiki/            # Persistent knowledge base (장기 기억)
    ├── Index.md     # Topic catalog
    ├── Log.md       # Chronological change log
    └── topics/      # Individual knowledge pages
```

## 3-Layer Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Session Index (SESSIONS.md)                            │
│  "지금 누가 무엇을 하고 있나" — 실시간 활성 에이전트 레지스트리           │
├──────────────────────────────────────────────────────────────────┤
│  Layer 2: Session History (sessions/*.md)                        │
│  "그때 무슨 일이 있었나" — 조선실록처럼 영구 보존되는 임무 기록           │
├──────────────────────────────────────────────────────────────────┤
│  Layer 3: Memory / Wiki (wiki/)                                  │
│  "우리가 알고 있는 것" — Karpathy LLM-Wiki 패턴의 장기 지식            │
└──────────────────────────────────────────────────────────────────┘
```

### Layer 1: Session Index (SESSIONS.md)
- 활성 에이전트 목록 (누가, 언제, 무엇)
- Hook이 자동으로 등록/해제
- 2시간 이상 업데이트 없으면 stale로 자동 정리

### Layer 2: Session History (sessions/)
- 세션별 상세 기록: Log (임무 실록), Decisions, Blockers
- 세션 종료 시 auto-summary 생성
- **영구 보존** — 나중에 "그때 뭘 했지?" 찾아볼 수 있음
- Cross-CLI handoff: 다른 CLI가 이전 세션 파일을 읽고 이어받기

### Layer 3: Memory / Wiki (wiki/)
- [Karpathy LLM-Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) 패턴
- 세션 종료 시 wiki로 추출할 지식을 식별하여 topics/에 저장
- Index.md만 읽고 필요한 토픽만 선택 로딩 (토큰 효율)

## Session Lifecycle (Hook 기반 자동화)

```
SessionStart Hook                    임무 수행 중                     SessionEnd Hook
─────────────────                    ──────────────                   ─────────────────
┌─ 스크립트가 자동 처리 ─┐           ┌─ LLM이 직접 처리 ─┐           ┌─ 스크립트가 자동 처리 ─┐
│ 1. Stale 에이전트 정리  │           │ • Log에 작업 기록  │           │ 1. SESSIONS.md 항목 삭제│
│ 2. SESSIONS.md 등록    │           │ • Decisions 기록   │           │ 2. Status → completed  │
│ 3. sessions/{id}.md 생성│          │ • Blockers 기록    │           │ 3. Ended 타임스탬프     │
│ 4. 이전 세션 미추출 알림 │          │ • wiki 업데이트    │           │ 4. Auto-summary 생성   │
│ 5. 활성 세션 컨텍스트   │           └────────────────────┘           └─────────────────────────┘
│    stdout → LLM 주입   │
└─────────────────────────┘                                           다음 SessionStart에서:
                                                                      → Wiki Extractions 비어있으면
                                                                        LLM에게 추출 요청
```

**핵심 원칙**: hook end는 기계적 정리만, hook start는 LLM 컨텍스트 주입 담당.
세션 종료 시점에는 LLM이 이미 끝나므로 지적 작업(wiki 추출)은 다음 세션 시작 시 처리.

### Session Auto-Recording (v0.4.0)

세션 내용을 LLM의 instruction-following에 의존하지 않고 **자동으로 캡처 + 요약**한다.

| CLI | 캡처 방식 | 요약 시점 |
|-----|----------|----------|
| Claude Code | `$CLAUDE_TRANSCRIPT_PATH` (내장) | SessionEnd hook |
| Gemini CLI | `script -q` (raw 캡처) | `aib start` trap |
| Codex CLI | `script -q` (raw 캡처) | `aib start` trap |

세션 종료 시 자동으로:
1. Raw 캡처에서 ANSI 코드 제거
2. `claude -p`로 요약 (Log/Decisions/Wiki Extractions 추출)
3. `sessions/{id}.md`에 구조화된 기록 저장
4. Raw 파일 삭제

### Hook 설정

`aib init`이 CLI별 hook을 자동 감지 + 설정한다:

| CLI | SessionStart | SessionEnd | 비고 |
|-----|-------------|-----------|------|
| Claude Code | `aib hook start claude` | `aib hook end claude` | 자동 설정 |
| Gemini CLI | `aib hook start gemini` | `aib hook end gemini` | 자동 설정 |
| Codex CLI | — | — | `aib start codex` 래퍼 사용 |

### Cross-CLI Session Handoff

```bash
# Claude에서 작업 중 rate limit 발생
# → Gemini에서 이어받기:
aib hook continue claude-20260405-2230
# → 이전 세션의 Log, Decisions, Blockers가 컨텍스트로 주입됨
```

## Commands

| Command | Description |
|---------|-------------|
| `aib init [path]` | Initialize barrack + auto-configure hooks |
| `aib start <client> [task]` | Deploy agent for tracked session (wrapper) |
| `aib hook start <client>` | (Auto) Called by CLI SessionStart hooks |
| `aib hook end <client>` | (Auto) Called by CLI SessionEnd hooks |
| `aib hook continue <session_id>` | Continue another CLI's session |
| `aib status` | Show active agents and wiki stats |
| `aib sync` | Re-inject protocol into config files |
| `aib council [-r N] [-m MODE] "topic"` | Run multi-LLM debate council (Claude + Gemini + Codex) |

### Council Command

`aib council` wraps [council.sh](https://github.com/CYRok90/rakku-workspace/blob/main/scripts/council.sh) — a multi-round debate orchestrator that runs Claude, Gemini, and Codex in parallel and synthesizes a consensus answer.

```bash
aib council "REST vs gRPC"
aib council -m adversarial -r 3 "Kafka vs Pulsar"
aib council -m pipeline "Migration strategy"
```

**Script resolution order** (first found wins):
1. `$AIB_COUNCIL_SCRIPT` env var
2. `./scripts/council.sh` (barrack-local)
3. `~/Develop/rakku-workspace/scripts/council.sh` (fallback)

**Modes**: `debate` (default) | `adversarial` | `pipeline`

## Access Methods

```
┌─────────────────────────────────────────────────────────┐
│                     Your Barrack                         │
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
`claude` 실행 → SessionStart hook이 자동으로 에이전트 등록 + wiki 컨텍스트 주입.
세션 종료 → SessionEnd hook이 자동으로 정리 + auto-summary 생성.

### Mobile: Slack Bot 경유
[slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge)가 프로토콜을 대신 처리:

1. Slack 메시지 수신 → SESSIONS.md 등록 + wiki 컨텍스트 프롬프트 주입
2. CLI `-p` 실행 → 응답 반환
3. 스레드 만료 → SESSIONS.md 정리

```bash
# bridge .env 설정
AIB_BARRACK_DIR=/path/to/your/barrack
```

## GitAgent Compatibility

AIB는 [GitAgent](https://github.com/open-gitagent/gitagent) 표준과 호환된다.
`aib init`이 생성하는 `agent.yaml`, `SOUL.md`, `RULES.md`는 GitAgent spec을 따른다.

| 파일 | GitAgent 역할 | AIB 역할 |
|------|-------------|---------|
| `agent.yaml` | 에이전트 메타데이터 | 배럭 설정 (자동 관리) |
| `SOUL.md` | 에이전트 정체성 | 사용자/에이전트 커스터마이즈 |
| `RULES.md` | 행동 규칙 | 에이전트 자동 학습 (Must Always/Must Never/Learned) |

`gitagent validate`로 AIB 배럭의 GitAgent 규격 준수를 검증할 수 있다.

## Design Principles

- **File-based**: No database, no server, no infrastructure
- **Hook-enforced**: LLM이 프로토콜을 무시해도 hook이 강제 관리
- **Permanent history**: sessions/는 삭제하지 않는 영구 기록 (조선실록)
- **Knowledge extraction**: 세션 → wiki 추출로 지식이 누적
- **Cross-CLI**: 어떤 CLI에서든 이전 에이전트 세션을 이어받을 수 있음
- **Token-efficient**: Index.md (~750 tokens)만 필수, 나머지 선택 로딩

## License

MIT
