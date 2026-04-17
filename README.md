# AI Barracks (AIB)

Git-native AI agent workspace — 하네스 엔지니어링, LLM-Wiki, GitAgent를 배럭 단위로 패키징.

## 왜 만들었나

AI 코딩 에이전트를 실무에서 쓰다 보면 세션이 끝날 때마다 맥락이 사라집니다.
어제 알려준 규칙을 오늘 또 설명하고, 아키텍처 결정의 이유를 매번 반복합니다.

한편, AI 에이전트를 잘 다루기 위한 좋은 아이디어들이 나오고 있습니다:

- **하네스 엔지니어링** (Anthropic, OpenAI) — 에이전트에게 규칙을 말하지 말고, Hook과 불변식으로 기계적으로 강제하라
- **LLM-Wiki** (Karpathy) — 세션에서 발견한 지식을 토픽별로 추출하여 장기 기억으로 축적
- **GitAgent** — 에이전트의 정체성(SOUL.md)과 행동 규칙(RULES.md)을 표준화된 파일로 관리

이 컨셉들은 강력하지만, 각각 직접 구현하고 조합해야 합니다.

**AI Barracks는 이 컨셉들을 하나의 "배럭"으로 패키징합니다.**
`aib init` 한 번이면 프로젝트 디렉토리가 AI 에이전트 워크스페이스로 변환되고,
세션 관리, 지식 축적, 규칙 학습, 불변식 강제가 자동으로 동작합니다.

- DB도, 서버도, SaaS도 없이 — Git repo 하나가 에이전트의 장기 기억
- Claude Code, Gemini CLI, Codex CLI가 같은 배럭을 공유하고 세션을 이어받을 수 있음
- 프로젝트별로 배럭을 만들어 각각의 에이전트를 독립적으로 관리

## 핵심 컨셉

| 컨셉 | 출처 | AI Barracks 구현 |
|------|------|-----------------|
| Hook 기반 자동화 | Harness Engineering | SessionStart/End Hook이 세션 등록, 정리, 요약을 자동 처리. LLM이 프로토콜을 잊어도 동작 |
| 불변식 강제 | OpenAI Harness Engineering | 세션 종료 시 위반 자동 감지 → 다음 세션에 remediation 주입 |
| LLM-Wiki | Karpathy | `wiki/Index.md`(~750토큰)만 로딩, 필요한 토픽만 선택적 로드. 세션마다 자동 추출 |
| 에이전트 정체성 | GitAgent | `SOUL.md`(정체성) + `RULES.md`(규칙) + `agent.yaml`(메타데이터) 표준 파일 |
| 자동 규칙 축적 | Growth Protocol | Decision Table로 "뭘 언제 어디에 기록할지" 명확화. 발견 즉시 기록 |
| 영구 기록 | Veritable Records | 세션 기록은 삭제하지 않는 실록(Silok) — 프로젝트 의사결정 이력의 영구 보존 |
| Cross-CLI | — | Claude/Gemini/Codex가 같은 배럭 공유. Rate limit 시 CLI 전환 + 세션 이어받기 |

## Quick Start

```bash
brew tap ai-barracks/ai-barracks
brew install ai-barracks

aib init ~/my-project       # Initialize barrack + auto-configure hooks
aib start claude "my task"  # Or just run `claude` directly (hooks handle it)
aib start claude "my task" --skip-permissions  # Skip permission prompts
aib status                  # Show active agents and wiki
```

## What it creates

```
your-barrack/
├── CLAUDE.md        # Protocol injected (Claude Code)
├── GEMINI.md        # Protocol injected (Gemini CLI)
├── AGENTS.md        # Protocol injected (Codex CLI)
├── agent.yaml       # GitAgent spec — barrack metadata
├── SOUL.md          # Agent identity / expertise
├── RULES.md         # Behavior rules (Must Always/Never/Learned)
├── GROWTH.md        # Growth triggers — decision table for wiki/RULES updates
├── SESSIONS.md      # Session index (gitignored)
├── sessions/        # Session history (Veritable Records aka 'Silok')
│   ├── .active      # Current session ID marker
│   ├── claude-20260405-2230.md
│   └── gemini-20260405-2245.md
├── docs/            # Protocol detail guides (system-managed)
│   ├── session-protocol.md
│   ├── growth-protocol.md
│   └── wiki-protocol.md
└── wiki/            # Persistent knowledge base (장기 기억)
    ├── Index.md     # Topic catalog
    ├── Log.md       # Chronological change log
    └── topics/      # Individual knowledge pages
```

## File Ownership

배럭 내 파일은 **누가 수정하는가**에 따라 5가지로 분류된다.
각 파일 상단의 `<!-- AIB:OWNERSHIP -->` 주석으로도 확인 가능.

| 표기 | 의미 | 사용자 행동 |
|------|------|------------|
| `USER-OWNED` | 사용자가 정의하고 관리 | **직접 수정** |
| `INJECTED` | `aib sync`가 마커 내부를 교체 | 마커 밖에만 내용 추가 |
| `AUTO-GROW` | 에이전트가 세션마다 자동 성장 | 수정 가능, 안 해도 됨 |
| `SYSTEM` | Hook/CLI가 관리 | **수정 금지** |
| `RECORD` | 세션 중 기록, 이후 영구 보존 | **수정 금지** |

### 사용자가 직접 수정해야 하는 파일

| 파일 | 용도 | 비고 |
|------|------|------|
| `SOUL.md` | 에이전트 정체성 (전문성, 성격, 가치관) | `aib init` 후 반드시 커스터마이징. 에이전트는 변경 제안만 세션 로그에 남김 |
| `agent.yaml` | 배럭 메타데이터 (이름, 설명, 모델) | description을 수정하면 Slack 라우팅 정확도 향상 |
| `GROWTH.md` | 지식 성장 기준 (wiki/RULES 갱신 트리거) | 기본값으로도 동작. 도메인 특화 시 wiki 토픽 예시 추가 권장 |
| `CLAUDE.md` | Claude Code 지시 (마커 밖 영역) | 배럭 전용 커스텀 지시 추가 가능 |

### 에이전트가 자동으로 성장시키는 파일

| 파일 | 동작 | 사용자 개입 |
|------|------|------------|
| `RULES.md` | 에이전트가 Learned 섹션에 규칙 자동 추가 | Must Always/Never에 직접 추가 가능 |
| `wiki/topics/*.md` | 세션 중 발견한 지식을 자동 추가 | 직접 추가/수정 가능 |
| `wiki/Index.md` | 새 토픽 생성 시 자동 등록 | 직접 추가 가능 |
| `wiki/Log.md` | wiki 변경 시 자동 기록 | 수정 불필요 |

### 건드리지 않아야 하는 파일

| 파일 | 이유 |
|------|------|
| `SESSIONS.md` | Hook이 실시간 관리 — 수동 수정 시 충돌 |
| `sessions/.active` | 현재 세션 ID 마커 — Hook 전용 |
| `sessions/{id}.md` | Veritable Records aka 'Silok' — 영구 보존 — 수정 시 이력 훼손 |

## 3-Layer Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Layer 1: Session Index (SESSIONS.md)                            │
│  "지금 누가 무엇을 하고 있나" — 실시간 활성 에이전트 레지스트리           │
├──────────────────────────────────────────────────────────────────┤
│  Layer 2: Session History (sessions/*.md)                        │
│  "그때 무슨 일이 있었나" — Veritable Records aka 'Silok' — 영구 보존되는 임무 기록           │
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
- 세션별 상세 기록: Log (Veritable Records aka 'Silok'), Decisions, Blockers
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
│ 4. 배럭 메타데이터 갱신  │          │ • Retries 기록     │           │ 4. Auto-summary 생성   │
│ 5. Violation 주입 ★    │          │ • wiki 업데이트    │           │ 5. Violation 기록 ★    │
│ 6. Blocker carry-over ★│          └────────────────────┘           └─────────────────────────┘
│ 7. 활성 세션 컨텍스트   │
│    stdout → LLM 주입   │
└─────────────────────────┘                                           ★ v0.9.0: 불변식 위반을
                                                                        .violations 파일로 기록 →
                                                                        다음 Start에서 LLM에 주입
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
| `aib start <client> [task] [--skip-permissions]` | Deploy agent for tracked session (wrapper) |
| `aib hook start <client>` | (Auto) Called by CLI SessionStart hooks |
| `aib hook end <client>` | (Auto) Called by CLI SessionEnd hooks |
| `aib hook continue <session_id>` | Continue another CLI's session |
| `aib barracks [list\|remove\|route\|refresh]` | Manage registered barracks globally |
| `aib status` | Show active agents and wiki stats |
| `aib wiki lint [--fix]` | Check wiki health and freshness (STALE, OVERSIZED, MISSING, DUPLICATE) |
| `aib sync [--dry-run] [path]` | Sync templates + protocol to barrack (idempotent upgrade) |
| `aib council [-r N] [-m MODE] "topic"` | Run multi-LLM debate council (Claude + Gemini + Codex) |
| `aib version` | Show version |

### `--skip-permissions`

`aib start`에 `--skip-permissions` 플래그를 추가하면 각 CLI의 permission prompt를 자동으로 스킵한다.

```bash
aib start claude "refactor auth" --skip-permissions
aib start gemini "analyze logs" --skip-permissions
aib start codex "fix tests" --skip-permissions
```

| Client | Mapped Flag | Effect |
|--------|------------|--------|
| Claude | `--dangerously-skip-permissions` | 모든 tool call 자동 승인 |
| Gemini | `--yolo` | Sandbox 비활성화 + 자동 승인 |
| Codex  | `--full-auto` | 자동 실행 모드 |

> **주의**: 신뢰할 수 없는 환경이나 프로덕션에서는 사용하지 마세요. 모든 tool call이 확인 없이 실행됩니다.

### Council Command

`aib council` wraps a bundled `council.sh` — a multi-round debate orchestrator that runs Claude, Gemini, and Codex in parallel and synthesizes a consensus answer.

```bash
aib council "REST vs gRPC"
aib council -m adversarial -r 3 "Kafka vs Pulsar"
aib council -m pipeline "Migration strategy"
```

**Script resolution order** (first found wins):
1. `$AIB_COUNCIL_SCRIPT` env var
2. `./scripts/council.sh` (barrack-local)
3. Brew-installed path (`$(brew --prefix)/share/ai-barracks/scripts/council.sh`)

**Modes**: `debate` (default) | `adversarial` | `pipeline`

## Barrack Registry (`~/.aib/barracks.json`)

`aib init`은 배럭을 글로벌 레지스트리(`~/.aib/barracks.json`)에 자동 등록한다.
여러 프로젝트를 각각의 배럭으로 관리하고, 외부 시스템(Slack Bot 등)이 메시지 내용에 따라 적절한 배럭을 자동 선택할 수 있다.

```json
[
  {
    "path": "/home/user/project-alpha",
    "name": "project-alpha",
    "description": "AI workspace powered by AI Barracks",
    "expertise": "Python, backend, data pipeline",
    "topics": "ETFPlatform,ClickHouseOperations"
  }
]
```

메타데이터는 배럭 내 `agent.yaml` (description), `SOUL.md` (expertise), `wiki/Index.md` (topics)에서 자동 추출된다.
세션 시작 시(`aib hook start`) 현재 배럭의 메타데이터가 자동으로 갱신되므로, SOUL.md나 wiki를 편집하면 다음 세션부터 라우팅에 반영된다.

```bash
aib barracks list                  # 등록된 배럭 목록
aib barracks route "ETF 데이터"     # 메시지와 가장 관련 높은 배럭 경로 반환
aib barracks refresh               # 모든 배럭 메타데이터 재수집
aib barracks remove /path/to/old   # 등록 해제
```

### Slack Bot 연동

[slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge)는 `barracks.json`을 읽어 메시지 키워드 기반으로 최적의 배럭을 자동 라우팅한다:

```
Slack 메시지 → barracks.json에서 키워드 매칭 → 최적 배럭 선택
→ 해당 배럭의 wiki 컨텍스트 주입 + CLI 실행 (cwd = 배럭 경로)
```

## Access Methods

```
              ~/.aib/barracks.json (글로벌 레지스트리)
                        │
          ┌─────────────┼──────────────┐
          ▼             ▼              ▼
   ┌──────────┐  ┌──────────┐  ┌──────────┐
   │ Barrack A│  │ Barrack B│  │ Barrack C│     ← 프로젝트별 배럭
   └────┬─────┘  └────┬─────┘  └────┬─────┘
        │              │             │
        └──────┬───────┘─────────────┘
               │
    ┌──────────┼──────────────────────────────┐
    │          │                    │          │
┌───▼───┐ ┌───▼────┐ ┌───▼────┐   │    ┌─────▼──────────┐
│Claude │ │Gemini  │ │ Codex  │   │    │ CommandCenter  │ ← Desktop (GUI)
│ Code  │ │  CLI   │ │  CLI   │   │    │ (Tauri App)    │   배럭 관제 + 편집
└───────┘ └────────┘ └────────┘   │    └────────────────┘
     ↑ Desktop (CLI)               │
       Hook이 자동 처리             │
                          ┌────────▼─────────────┐
                          │  slack-agent-bridge   │ ← Mobile (Slack Bot)
                          │  (Mac Mini daemon)    │   barracks.json 라우팅
                          └──────────┬────────────┘
                                     │
                          ┌──────────▼──────────┐
                          │   Slack App          │
                          │  (Phone/Tablet)      │
                          └──────────────────────┘
```

### Desktop: CLI 직접 사용
`claude` 실행 → SessionStart hook이 자동으로 에이전트 등록 + wiki 컨텍스트 주입.
세션 종료 → SessionEnd hook이 자동으로 정리 + auto-summary 생성.

### Mobile: Slack Bot 경유
[slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge)가 프로토콜을 대신 처리:

1. Slack 메시지 수신 → `barracks.json`에서 키워드 매칭으로 배럭 라우팅
2. 해당 배럭의 wiki 컨텍스트 주입 + SESSIONS.md 등록
3. CLI `-p` 실행 (cwd = 라우팅된 배럭) → 응답 반환
4. 스레드 만료 → SESSIONS.md 정리

```bash
# bridge .env 설정
AIB_WORKSPACE_DIR=/path/to/default/barrack  # 기본 배럭 (라우팅 실패 시 fallback)
```

## Upgrading Barracks (`aib sync`)

`brew upgrade ai-barracks` 후 기존 배럭에 변경사항을 반영하려면:

```bash
aib sync                    # 현재 디렉토리의 배럭 업그레이드
aib sync /path/to/barrack   # 특정 배럭 업그레이드
aib sync --dry-run           # 변경 예정 사항만 미리 확인
```

`aib sync`는 파일 유형별로 안전한 업데이트 전략을 적용한다:

| 전략 | 대상 파일 | 동작 |
|------|---------|------|
| **Protocol injection** | CLAUDE.md, GEMINI.md, AGENTS.md | 마커(`<!-- AIB:... -->`) 안쪽만 교체, 사용자 내용 보존 |
| **Section guard** | SOUL.md, RULES.md | 템플릿의 H2 섹션이 누락되면 빈 스텁으로 추가. 기존 내용 불변 |
| **YAML field merge** | agent.yaml | 누락된 top-level 키만 기본값으로 추가. 기존 키 불변 |
| **Scaffold** | wiki/Index.md, wiki/Log.md, GROWTH.md | 파일 없으면 생성, 있으면 skip |
| **System** | docs/*.md | 매 sync 시 항상 템플릿에서 덮어쓰기 (시스템 문서) |

`aib_version` 필드가 `agent.yaml`에 자동 스탬프되어 각 배럭의 마지막 sync 버전을 추적한다.

### 전체 업그레이드 워크플로우

```bash
brew upgrade ai-barracks            # CLI 업그레이드
aib barracks list                   # 등록된 배럭 확인
aib sync --dry-run /path/to/barrack # 변경사항 미리 확인
aib sync /path/to/barrack           # 적용
# 메타데이터는 다음 세션 시작 시 자동 갱신됨 (수동: aib barracks refresh)
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

## CommandCenter (Desktop GUI)

CLI 외에 데스크톱 앱으로도 배럭을 관제할 수 있다.

[**AI Barracks CommandCenter**](https://github.com/ai-barracks/ai-barracks-cc) — Tauri v2 (Rust + React) 기반 macOS 앱.

- 배럭 목록 + 상태 한눈에 보기
- 설정 파일 편집: SOUL.md/GROWTH.md 에디터, RULES.md 구조화 UI, agent.yaml 폼 에디터
- 에이전트 히스토리 타임라인 + Continue (완료된 작업 이어받기)
- 위키 탐색, 전체 검색 (세션/위키/규칙 통합)
- 버전 대시보드 + 선택적/일괄 Sync
- 새 배럭 생성
- Light/Dark 테마, 파일 실시간 감시

> CommandCenter는 ai-barracks CLI의 GUI 확장이다. CLI(`aib`) 없이는 동작하지 않는다.

```
              ~/.aib/barracks.json
                      │
          ┌───────────┼──────────────┐
          ▼           ▼              ▼
    ┌──────────┐ ┌──────────┐ ┌──────────┐
    │ Barrack A│ │ Barrack B│ │ Barrack C│
    └──────────┘ └──────────┘ └──────────┘
          ▲                         ▲
    ┌─────┴──────┐            ┌─────┴──────┐
    │ CLI (aib)  │            │CommandCenter│
    │ Terminal   │            │ Desktop App │
    └────────────┘            └─────────────┘
```

## License

MIT
