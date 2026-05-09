# 🏰 AI Barracks (AIB)

Git-native AI agent workspace — 하네스 엔지니어링, LLM-Wiki, GitAgent를 배럭 단위로 패키징.

## 🌱 Origin Story

### 네 가지 욕심에서 시작되었습니다

> 1. **LLM을 하나만 쓰고 싶지 않다.**
>    Claude가 주력이지만, rate limit에 걸리면 Gemini나 Codex로 자연스럽게 이어가고 싶었다.
>
> 2. **지나간 세션을 업무일지처럼 남기고 싶다.**
>    매일의 작업과 결정을 상세히 기록해서, 한참 뒤에도 *"그때 왜 이렇게 했지?"* 를 찾을 수 있기를.
>
> 3. **나만의 지식 저장소를 만들고 싶다.**
>    여러 AI 에이전트가 **같은 지식을 공유하며** 참조할 수 있기를.
>
> 4. **프로젝트별 하네스를 쉽게 관리하고 싶다.**
>    주제마다 다른 규칙과 컨텍스트를, 섞이지 않게 **독립된 단위로** 다루기를.

### 세 줄의 명제로 수렴했습니다

> 🔀 **쓰는 모델이 바뀌어도, 맥락은 이어져야 한다.**
>
> 📓 **지나간 세션은 흘려보내지 않고, 실록으로 남겨야 한다.**
>
> 📚 **지식은 에이전트를 넘나들되, 배럭 단위로 독립된다.**

### 세 가지 선행 아이디어 위에 세웠습니다

| 아이디어 | 출처 | AI Barracks에 녹인 방식 |
|---------|------|------------------------|
| **🔨 Harness Engineering** | Anthropic, OpenAI | 규칙을 말하지 말고, Hook과 불변식으로 기계적으로 강제하라 |
| **📖 LLM-Wiki** | [Karpathy](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) | 세션에서 발견한 지식을 토픽별로 추출하여 장기 기억으로 축적 |
| **🧬 GitAgent** | [open-gitagent](https://github.com/open-gitagent/gitagent) | 에이전트의 정체성(`SOUL.md`)과 행동 규칙(`RULES.md`)을 표준화된 파일로 관리 |

이 모든 것을 하나의 **"배럭(Barrack)"** 단위로 패키징한 것이 **AI Barracks**이며,
여러 배럭을 데스크톱에서 GUI로 관제하기 위한 동반 프로젝트가 **[AI Barracks CommandCenter (CC)](https://github.com/ai-barracks/ai-barracks-cc)** 입니다.

---

## 💡 핵심 아이디어

> **에이전트의 기억을 프롬프트가 아니라 Git 저장소에 남기자.**

프로젝트 디렉토리 안에 마크다운 파일로 모든 것을 기록하고, Git으로 버전 관리합니다:

| | |
|---|---|
| 📝 **세션 기록** | `sessions/` — 영구 보존되는 실록 |
| 📚 **장기 지식** | `wiki/` — 토픽별 선택 로딩 |
| ⚖️ **학습된 규칙** | `RULES.md` — 실수에서 자동 축적 |
| 🧬 **에이전트 정체성** | `SOUL.md` — 사용자가 정의 |

DB도 서버도 SaaS도 필요 없습니다. **Git repo 하나가 에이전트의 장기 기억**입니다.

---

## ✨ 한눈에 보는 특징

| 기능 | 설명 |
|------|------|
| 🔄 **Cross-CLI Handoff** | Claude/Gemini/Codex가 같은 배럭을 공유. Rate limit 걸리면 다른 CLI로 세션 이어받기 |
| 🎣 **Hook 기반 자동화** | LLM이 프로토콜을 잊어도 시스템은 정상 동작. 세션 등록/정리/요약 전부 자동 |
| 🧪 **불변식 강제** | 세션 종료 시 위반 자동 감지 → 다음 세션에 remediation 주입 |
| 📖 **Karpathy LLM-Wiki** | Index만 로딩, 필요한 토픽만 선택 로드 — 토큰 경제성 |
| 🗳️ **Multi-LLM Council** | Claude + Gemini + Codex 병렬 실행으로 합의 도출 |
| 🌐 **Barrack Registry** | 프로젝트별 배럭 관리 + 키워드 기반 라우팅 (Slack bot 연동) |
| 🧾 **Veritable Records** | 세션 기록은 절대 지우지 않는 실록(Silok) — 의사결정 이력의 영구 보존 |
| 🧪 **Skills** | `skills/<slug>/SKILL.md`를 first-class 자원으로 다룹니다 — Anthropic Agent Skills 표준 + ai-barracks 확장(`aib_version`, `upstream`). v1.2부터 `aib sync`가 Claude Code용 `.claude/skills/<slug>` 심볼릭 링크(W1)와 Gemini/Codex용 `Available Skills` 카탈로그 블록(W2)을 자동 wiring. |

---

## 🚀 Quick Start

```bash
# 1. 설치
brew tap ai-barracks/ai-barracks
brew install ai-barracks

# 2. 배럭 초기화 (CLI hook 자동 설정)
cd ~/my-project
aib init

# 3. 평소처럼 CLI 실행 — hook이 알아서 처리
claude
# 또는 명시적 세션 시작
aib start claude "리팩토링 작업"

# 4. 상태 확인
aib status
```

`aib init` 한 번 실행으로:

- ✅ 프로젝트 디렉토리가 AI 에이전트 워크스페이스로 변환
- ✅ Claude Code / Gemini CLI의 `SessionStart`/`SessionEnd` hook 자동 주입 (`~/.claude/settings.json`, `~/.gemini/settings.json`)
- ✅ 글로벌 배럭 레지스트리(`~/.aib/barracks.json`) 등록
- ✅ `CLAUDE.md`, `GEMINI.md`, `AGENTS.md`에 Session-Memory Protocol 주입

---

## 🏗️ 아키텍처

### 3-Layer Memory Model

```
┌──────────────────────────────────────────────────────────┐
│ Layer 1: Active Sessions  (SESSIONS.md)                  │
│ "지금 누가 뭘 하고 있나" — 실시간 활성 에이전트 레지스트리 │
├──────────────────────────────────────────────────────────┤
│ Layer 2: Session History  (sessions/*.md)                │
│ "그때 무슨 일이 있었나" — 영구 보존되는 실록(Silok)        │
├──────────────────────────────────────────────────────────┤
│ Layer 3: Knowledge Wiki   (wiki/)                        │
│ "우리가 알고 있는 것" — Karpathy LLM-Wiki 패턴            │
└──────────────────────────────────────────────────────────┘
```

### 디렉토리 구조

```
your-barrack/
├── CLAUDE.md        ← Claude Code용 프로토콜 주입 (마커 안쪽만 관리)
├── GEMINI.md        ← Gemini CLI용
├── AGENTS.md        ← Codex CLI용
├── SOUL.md          ← 에이전트 정체성             [USER-OWNED]
├── RULES.md         ← 행동 규칙                   [AUTO-GROW]
├── GROWTH.md        ← 성장 트리거                 [USER-OWNED]
├── agent.yaml       ← 배럭 메타데이터 (GitAgent 호환)
├── SESSIONS.md      ← 활성 세션 인덱스            [SYSTEM, gitignored]
├── sessions/
│   ├── .active
│   └── claude-20260418-1430.md                   [RECORD, 영구 보존]
├── wiki/
│   ├── Index.md     ← 토픽 카탈로그 (~750 토큰)
│   ├── Log.md       ← 시간순 변경 로그
│   └── topics/      ← 토픽별 상세 지식
├── skills/
│   └── council/
│       └── SKILL.md ← frontmatter + 본문 — Agent Skills 표준  [AUTO-GROW]
├── .claude/skills/  ← W1 심볼릭 링크 (aib sync가 생성)        [SYSTEM, gitignored]
└── docs/            ← 프로토콜 상세 가이드        [SYSTEM, on-demand 로딩]
```

---

## ⚙️ 어떻게 동작하나?

### Session Lifecycle

```
      CLI 시작                    작업 중                      CLI 종료
   ┌────────────┐              ┌──────────┐                ┌────────────┐
   │SessionStart│────────▶    │   LLM    │      ────▶     │ SessionEnd │
   │   Hook     │              │  작업    │                │   Hook     │
   └─────┬──────┘              └──────────┘                └──────┬─────┘
         │                                                        │
         ▼ 스크립트 자동 처리                                       ▼ 스크립트 자동 처리
  ├─ Stale 세션 정리 (>2h)                            ├─ SESSIONS.md 항목 삭제
  ├─ 새 세션 등록                                     ├─ Status → completed
  ├─ sessions/{id}.md 생성                            ├─ Ended 타임스탬프
  ├─ 배럭 메타데이터 갱신                             ├─ Raw 캡처 → LLM 자동 요약
  ├─ 이전 blocker carry-over                         ├─ 불변식 검증
  ├─ .violations 주입 (remediation) ★                 │   • TASK_PENDING?
  └─ stdout → LLM 컨텍스트 주입                       │   • GROWTH_MISSING?
                                                     │   • UNRESOLVED_BLOCKERS?
                                                     └─ 위반 → .violations 파일 ★

                                     ★ 다음 SessionStart에서 LLM에 자동 주입
```

**핵심 원칙**:
> Hook End는 기계적 정리만, Hook Start는 LLM 컨텍스트 주입 담당.
> 세션 종료 시점에는 LLM이 이미 끝났으므로, 지적 작업(wiki 추출, remediation 설계)은 다음 세션 시작 시 처리.

### 불변식 → Remediation 루프

이 툴의 핵심 차별점입니다. LLM에게 *"세션 끝날 때 꼭 이거 해라"* 라고 말하는 대신:

1. **세션 종료 시 위반을 스크립트로 자동 감지**
   - `TASK_PENDING` — Task 필드가 업데이트 안 됨
   - `GROWTH_MISSING` — 의미있는 작업이 있으나 지식 추출이 비어있음
   - `UNRESOLVED_BLOCKERS` — 해소 안 된 블로커
2. **위반을 `.violations` 파일로 영구 기록**
3. **다음 세션 시작 시 LLM 컨텍스트에 자동 주입** (remediation injection)
4. LLM이 이전 실수를 알고 작업 시작 → 재발 방지

OpenAI/Anthropic의 Harness Engineering 패턴 — *"LLM에게 규칙을 말하지 말고, 기계적으로 강제하라"* — 를 그대로 구현했습니다.

### Session Auto-Recording

세션 내용을 LLM의 instruction-following에 의존하지 않고 **자동으로 캡처 + 요약**합니다:

| CLI | 캡처 방식 | 요약 시점 |
|-----|---------|---------|
| Claude Code | `$CLAUDE_TRANSCRIPT_PATH` (내장) | SessionEnd hook |
| Gemini CLI | `script -q` (raw 캡처) | `aib start` trap |
| Codex CLI | `script -q` (raw 캡처) | `aib start` trap |

세션 종료 시 `claude -p`로 raw 로그를 자동 요약하여 `sessions/{id}.md`에 구조화된 Log/Decisions/Wiki Extractions로 저장합니다.

---

## 🎭 Multi-LLM Council

`aib council`은 **Claude + Gemini + Codex를 병렬 실행해 합의를 도출**하는 토론 오케스트레이터입니다.

```bash
aib council "REST vs gRPC"
aib council -m adversarial -r 3 "Kafka vs Pulsar 비교"
aib council -m pipeline "ClickHouse 마이그레이션 전략"
aib council --json -o result.json -r 2 "마이크로서비스 vs 모놀리스"
```

### 3가지 토론 모드

| Mode | 설명 |
|------|------|
| `debate` *(기본)* | 자유 분석 → 교차 리뷰 |
| `adversarial` | 매 라운드 1명이 반대론자(Devil's Advocate) 역할 |
| `pipeline` | 역할 고정: Gemini 계획 → Claude 구현 → Codex 리뷰 |

### 영리한 최적화

- **First-done + Grace Period** — 첫 에이전트 완료 후 N초만 대기 후 컷. LLM tail latency 문제 해결.
- **Consensus-based Early Termination** — LLM-as-judge가 합의도 85+ 점수 산출 시 남은 라운드 skip. 토큰 절약.
- **Session-based Resume** — 중단된 토론을 `--resume <session_id>`로 이어받기.
- **Recursive Guard** — Claude Code 내부 실행 시 `CLAUDECODE=1` 감지하여 Claude 참여자에서 자동 제외.
- **Token Accounting** — Gemini는 JSON 응답, Codex는 `~/.codex/sessions/`의 rollout JSONL 파일을 세션 전후 비교로 파싱. 라운드별 토큰 사용량 자동 추적.
- **Claude OAuth Quota** — macOS Keychain에서 토큰 추출 → `/api/oauth/usage` 엔드포인트 호출로 5h/7d 사용률 실시간 체크.

### Manifest 기반 기록

모든 토론은 `/tmp/council/<session_id>/manifest.json`으로 구조화되어 저장됩니다:

```json
{
  "version": "2.0",
  "session_id": "20260418_143022_12345",
  "mode": "debate",
  "config": { "rounds": 2, "consensus_threshold": 85, "agents": {...} },
  "rounds_data": [{"round": 1, "agents": {"claude": {"duration_s": 28, "tokens": {...}}}}],
  "consensus_history": [{"round": 1, "score": 72, "reason": "..."}],
  "final_synthesis": "..."
}
```

구조화된 Markdown 리포트(`report.md`)도 함께 생성됩니다.

---

## 🔄 Cross-CLI Session Handoff

Claude에서 rate limit 걸리면?

```bash
# Claude 세션 중단
# Gemini로 이어받기:
gemini
> 명령: aib hook continue claude-20260418-1430
# 이전 세션의 Log/Decisions/Blockers가 Gemini 컨텍스트에 주입됨
```

**같은 배럭을 공유하므로 프로젝트 지식(wiki/, RULES.md, SOUL.md)은 그대로 유지**되고, 세션 컨텍스트만 새 CLI로 이동합니다.
이것이 Origin Story 첫 번째 욕심 — *"하나의 LLM에 묶이지 않기"* — 의 구현체입니다.

---

## 🌐 Barrack Registry

여러 프로젝트를 각각의 배럭으로 독립 관리할 수 있습니다. `~/.aib/barracks.json`에 글로벌 등록됩니다:

```json
[
  {
    "path": "/home/user/etf-platform",
    "name": "etf-platform",
    "description": "ETF 투자 추적 시스템",
    "expertise": "Python, ClickHouse, FastAPI",
    "topics": "ETFPlatform,ClickHouseOperations"
  },
  {
    "path": "/home/user/o11y-cli",
    "name": "o11y-cli",
    "description": "내부 observability CLI",
    "expertise": "Go, Kubernetes, eBPF",
    "topics": "CLIDesign,MetricsQuery"
  }
]
```

```bash
aib barracks list                    # 등록된 배럭 목록
aib barracks route "ETF 데이터"       # 메시지와 가장 관련 높은 배럭 경로 반환
aib barracks refresh                 # 모든 배럭 메타데이터 재수집
aib barracks remove /path/to/old     # 등록 해제
```

### Slack Bot 연동

[**slack-agent-bridge**](https://github.com/CYRok90/slack-agent-bridge)가 `barracks.json`을 읽어 자동 라우팅합니다:

```
Slack 메시지 → barracks.json에서 키워드 매칭
            → 최적 배럭 선택
            → 해당 배럭의 wiki 컨텍스트 주입
            → CLI -p 실행 (cwd = 배럭 경로)
            → 응답 반환
```

**모바일에서도 같은 프로젝트 컨텍스트로 에이전트에 지시**할 수 있습니다.

---

## 📂 File Ownership Model

배럭 내 파일은 **누가 수정하는가**에 따라 5가지로 분류됩니다. 각 파일 상단 `<!-- AIB:OWNERSHIP -->` 주석에 명시되어 있습니다.

| 표기 | 의미 | 사용자 행동 |
|------|------|------------|
| `USER-OWNED` | 사용자가 정의하고 관리 | **직접 수정** |
| `INJECTED` | `aib sync`가 마커 내부만 교체 | 마커 밖에만 내용 추가 |
| `AUTO-GROW` | 에이전트가 세션마다 성장시킴 | 수정 가능 (안 해도 됨) |
| `SYSTEM` | Hook/CLI가 관리 | **수정 금지** |
| `RECORD` | 세션 중 기록, 이후 영구 보존 | **수정 금지** |

### 사용자가 커스터마이징하는 파일

| 파일 | 용도 | 비고 |
|------|------|------|
| `SOUL.md` | 에이전트 정체성 (전문성, 성격, 가치관) | `aib init` 후 반드시 커스터마이징 |
| `agent.yaml` | 배럭 메타데이터 (이름, 설명, 모델) | description이 Slack 라우팅 정확도 결정 |
| `GROWTH.md` | 지식 성장 기준 | 기본값 동작, 도메인 특화 시 토픽 예시 추가 |
| `skills/<slug>/SKILL.md` | 스킬 정의 (frontmatter: name/description/aib_version/upstream) | council seed는 `aib sync`로 자동 배포 (`AUTO-GROW`) |

---

## 🛠️ Commands Reference

| Command | Description |
|---------|-------------|
| `aib init [path]` | 배럭 초기화 + hook 자동 설정 |
| `aib start <client> [task] [--skip-permissions]` | 세션 래퍼로 CLI 시작 |
| `aib status` | 활성 세션 + wiki 통계 |
| `aib wiki lint [--fix]` | wiki 건전성 검사 (`STALE`, `OVERSIZED`, `MISSING`, `DUPLICATE`) |
| `aib sessions clean [--dry-run]` | 빈 세션 파일 정리 |
| `aib barracks [list\|remove\|route\|refresh]` | 글로벌 배럭 관리 |
| `aib sync [--dry-run] [path]` | 템플릿 업그레이드 (파일별 안전 전략) |
| `aib council [-r N] [-m MODE] "topic"` | 멀티 LLM 합의 도출 |
| `aib skills [list\|doctor\|check]` | 스킬 목록 조회 / 무결성 점검 / 드리프트 진단 (v1.1+, `check`는 v1.2+) |
| `aib hook {start,end,continue}` | (내부) CLI hook에서 자동 호출 |
| `aib version` | 버전 확인 |

### Skills (v1.2.0+)

각 배럭은 `skills/<slug>/SKILL.md` 형태로 호출 가능한 스킬을 등록합니다 (Anthropic Agent Skills 호환). v1.2부터는 등록만 하면 활성 세션에 **자동 노출**됩니다:

- **Claude Code** — `aib sync`가 `.claude/skills/<slug>` 상대 심볼릭 링크를 생성. Claude의 native skill discovery가 이를 로드해 system reminder의 skill 목록에 노출하고, 네이티브 `Skill` 도구로 호출 가능합니다.
- **Gemini / Codex** — `aib sync`가 `Available Skills` 카탈로그 블록을 CLAUDE.md/GEMINI.md/AGENTS.md (이 셋은 byte-identical) 안에 자동 주입. 에이전트는 SKILL.md를 텍스트로 읽고 문서화된 명령을 실행합니다.

**Lifecycle:**

```bash
aib skills list                # 등록된 스킬 + frontmatter 메타데이터 출력 (v1.1+)
aib skills doctor              # frontmatter 유효성 + W1/W2 동기 검증 (v1.1+, v1.2 확장)
aib skills check               # 드리프트 빠른 진단 — aib start에서 사용 (v1.2+)
aib sync                       # W1+W2 wiring 재생성 (Step 1.5)
```

`.claude/skills/`는 런타임 산출물이며 기본적으로 gitignore 됩니다 (`templates/.gitignore`).

```bash
$ aib skills list
council    aib 1.1   ai-barracks/scripts/council.sh

$ aib skills doctor
✓ All healthy (1 skill, W1+W2 in sync)
```

### `--skip-permissions`

`aib start`에 이 플래그를 추가하면 각 CLI의 permission prompt를 자동 스킵합니다:

| Client | Mapped Flag | Effect |
|--------|-------------|--------|
| Claude | `--dangerously-skip-permissions` | 모든 tool call 자동 승인 |
| Gemini | `--yolo` | Sandbox 비활성화 + 자동 승인 |
| Codex | `--dangerously-bypass-approvals-and-sandbox` | 자동 실행 모드 (Codex CLI ≥ 0.128: 구 `--full-auto`는 거부됨) |

> ⚠️ **주의**: 신뢰할 수 없는 환경이나 프로덕션에서는 사용하지 마세요. 모든 tool call이 확인 없이 실행됩니다.

---

## 🔧 Advanced: `aib sync`

`brew upgrade ai-barracks` 후 기존 배럭에 변경사항을 반영할 때 사용합니다.

```bash
aib sync --dry-run /path/to/barrack  # 변경 예정 미리보기
aib sync /path/to/barrack            # 실제 적용
```

**파일 유형별 안전 전략**:

| 전략 | 대상 파일 | 동작 |
|------|---------|------|
| **Protocol injection** | `CLAUDE.md`, `GEMINI.md`, `AGENTS.md` | 마커 안쪽만 교체, 사용자 내용 보존 |
| **Section guard** | `SOUL.md`, `RULES.md` | 누락된 H2 섹션만 빈 스텁 추가. 기존 내용 불변 |
| **YAML field merge** | `agent.yaml` | 누락 필드만 기본값으로 추가 |
| **Scaffold** | `wiki/Index.md`, `GROWTH.md` | 파일 없으면 생성, 있으면 skip |
| **System** | `docs/*.md` | 매 sync 시 템플릿에서 덮어쓰기 |

`aib_version` 필드가 `agent.yaml`에 자동 스탬프되어 각 배럭의 마지막 sync 버전을 추적합니다.

---

## 🩹 Troubleshooting

### Claude TUI가 CommandCenter 내장 터미널에서 입력을 안 받을 때

증상: `aib start claude` 후 TUI는 보이는데 키 입력(Ctrl+C 포함)이 전부 무시되고, 외부 macOS Terminal.app에서는 같은 명령이 정상.

원인: `.claude/settings.local.json`의 `permissions.allow[]` 항목 중 `Bash(...)` 패턴에 unmatched `'` 또는 `"`가 있으면, Claude Code(특정 버전 — 2.1.118 검증) 가 PTY 환경에서 Settings Error 다이얼로그를 invisible 상태로 띄우면서 stdin을 가로챕니다.

진단/수정:
1. `aib start claude`는 v1.0.1부터 launch 직전 settings JSON을 검사해 `[WARN] N broken Bash() permission pattern(s) detected ...`을 출력합니다.
2. 경고가 뜨면 `.claude/settings.local.json`을 열어 해당 라인의 `'`/`"` 균형을 맞추거나 항목을 삭제하세요.
3. `claude install latest --force`로 Claude Code를 최신 버전으로 갱신.

### `aib start codex --skip-permissions`가 즉시 실패할 때

증상: `error: unexpected argument '--full-auto' found` 후 종료.

원인: Codex CLI 0.128 이상에서 `--full-auto` 플래그가 제거되고 `--dangerously-bypass-approvals-and-sandbox`로 대체되었습니다. v1.0.1부터 aib가 새 플래그를 사용합니다 — `brew upgrade ai-barracks`로 업데이트하세요.

---

## 🎯 Design Philosophy

### 1. LLM의 지시 수행을 믿지 않는다

세션 기록·정리·요약을 LLM instruction-following에 맡기지 않습니다. 중요한 작업은 전부 shell hook으로 기계적으로 강제합니다. **LLM이 프로토콜을 잊어도, 세션이 중간에 끊겨도 시스템은 정상 동작합니다.**

### 2. Progressive Disclosure로 토큰 절약

프로토콜 자체도 요약/상세 2단으로 분리했습니다:

- `CLAUDE.md`에 주입되는 프로토콜은 **~40줄 요약만**
- 상세 절차는 `docs/session-protocol.md` 등 별도 파일에 두고, **LLM이 필요할 때만 읽음**

Wiki도 마찬가지. Index만 항상 로드하고 토픽은 on-demand. **세션 시작 토큰 풋프린트를 최소화하는 것**이 설계 원칙입니다.

### 3. 특정 CLI에 묶이지 않는다

Claude/Gemini/Codex가 **동일한 파일 포맷**(`sessions/{id}.md`, `wiki/`, `RULES.md`)을 공유합니다. 한 CLI가 죽어도 다른 CLI가 파일을 읽고 이어받기가 됩니다. 벤더 종속성 없는 구조입니다.

### 4. 실록(Veritable Records)은 지우지 않는다

세션 기록은 모두 영구 보존됩니다. "그때 왜 이 결정을 했었지?"를 몇 달 뒤에도 확인할 수 있어야 합니다. `agent.yaml`에 `session_retention: permanent`로 명시되어 있으며, 에이전트는 세션 파일 수정이 금지됩니다.

### 5. 발견 즉시 기록, 종료 시 감사

`GROWTH.md`의 Decision Table에 따라 에이전트는 **종료 시가 아니라 발견 즉시** wiki/RULES를 갱신합니다. 세션 종료는 **저장 시점이 아니라 감사(audit) 시점**입니다.

---

## 🖥️ AI Barracks CommandCenter (CC)

CLI 외에 데스크톱 앱으로도 배럭을 관제할 수 있습니다.

[**AI Barracks CommandCenter**](https://github.com/ai-barracks/ai-barracks-cc) — Tauri v2 (Rust + React) 기반 macOS 앱.

- 🏠 배럭 목록 + 상태 한눈에 보기
- ✏️ `SOUL.md`/`RULES.md`/`agent.yaml` 구조화된 편집 UI
- ⏱️ 에이전트 히스토리 타임라인 + Continue (완료 작업 이어받기)
- 🔍 위키 탐색 + 전체 검색 (세션/위키/규칙 통합)
- 🔄 버전 대시보드 + 선택적/일괄 Sync
- 🌗 Light/Dark 테마 + 파일 실시간 감시

> CC는 ai-barracks CLI의 GUI 확장입니다. CLI(`aib`) 없이는 동작하지 않습니다.
> **CLI = 엔진, CC = 조종석. 두 프로젝트는 한 쌍입니다.**

---

## 🤝 GitAgent Compatibility

[GitAgent](https://github.com/open-gitagent/gitagent) 표준과 호환됩니다. `aib init`이 생성하는 `agent.yaml`, `SOUL.md`, `RULES.md`는 GitAgent spec을 따르므로 `gitagent validate`로 검증 가능합니다.

| 파일 | GitAgent 역할 | AIB 역할 |
|------|-------------|---------|
| `agent.yaml` | 에이전트 메타데이터 | 배럭 설정 (자동 관리) |
| `SOUL.md` | 에이전트 정체성 | 사용자 커스터마이즈 |
| `RULES.md` | 행동 규칙 | 에이전트 자동 학습 (Must Always/Never/Learned) |

---

## 📋 Requirements

- **macOS** *(현재 macOS 전용)*
- **Homebrew**
- **jq** *(자동 설치됨)*
- Claude Code, Gemini CLI, Codex CLI 중 **하나 이상**

---

## 🔗 관련 프로젝트

| 프로젝트 | 역할 |
|---------|------|
| [**ai-barracks-cc**](https://github.com/ai-barracks/ai-barracks-cc) | CommandCenter 데스크톱 GUI — 배럭 관제 조종석 |
| [**slack-agent-bridge**](https://github.com/CYRok90/slack-agent-bridge) | Slack → 배럭 자동 라우팅 브릿지 |
| [**open-gitagent**](https://github.com/open-gitagent/gitagent) | 호환되는 에이전트 정체성 표준 |

---

## 📜 License

[MIT](LICENSE)

---

<div align="center">

**Build your AI agent's long-term memory, one barrack at a time.**

*모델이 바뀌어도, 세션이 끝나도, 배럭은 남습니다.*

[⭐ Star on GitHub](https://github.com/ai-barracks/ai-barracks)&nbsp;·&nbsp;[🐛 Report a bug](https://github.com/ai-barracks/ai-barracks/issues)&nbsp;·&nbsp;[💬 Discuss](https://github.com/ai-barracks/ai-barracks/discussions)