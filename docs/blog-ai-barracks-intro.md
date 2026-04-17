# AI Barracks — AI 에이전트의 단기 세션을 장기 프로젝트 맥락으로 연결하는 Git 기반 시스템

> Claude Code, Gemini CLI, Codex CLI가 하나의 배럭에서 세션을 공유하고, 프로젝트별 규칙과 지식이 자동으로 축적되는 시스템을 만들었습니다.

## 문제: 매번 초기화되는 AI 에이전트

AI 코딩 에이전트를 실무에서 쓰다 보면 한 가지 불만이 생깁니다.

**세션이 끝나면 모든 맥락이 사라진다.**

어제 Claude에게 "이 프로젝트에서 sed 대신 awk를 써야 한다"고 알려줬는데, 오늘 다시 같은 실수를 합니다. 지난주에 발견한 배포 순서(tag → tap → brew)를 또 물어봅니다. 아키텍처 결정의 이유를 매번 다시 설명해야 합니다.

CLAUDE.md에 모든 것을 적어두면 되지 않느냐고요? 파일이 수백 줄이 되면 토큰 낭비이고, 어떤 정보가 중요한지 판단하는 것도 결국 사람의 몫입니다.

이 문제를 다르게 접근했습니다. **매 세션의 결과가 다음 세션의 입력이 되게 만들고 싶었습니다.** 기억을 프롬프트가 아니라 저장소 구조로 옮기는 방식입니다.

## 왜 파일 기반인가

DB나 SaaS를 쓰지 않은 이유가 있습니다.

- **감사 가능**: Git history로 언제 무엇이 바뀌었는지 추적 가능
- **이식 가능**: 디렉토리를 통째로 옮기면 끝. 벤더 종속 없음
- **투명**: 마크다운 파일을 열면 에이전트가 뭘 알고 있는지 바로 보임
- **LLM 친화적**: 별도 API 없이 파일을 읽으면 되므로 어떤 LLM이든 바로 사용 가능

AI 에이전트의 기억이 블랙박스가 아니라 버전 관리되는 텍스트 파일이라는 점이 핵심입니다.

## AI Barracks: 배럭에서 임무를 수행하는 에이전트

AI Barracks(AIB)는 Git 저장소를 "배럭(barrack)"으로 초기화하여, 그 안에서 AI 에이전트가 세션을 공유하고 장기 지식을 축적하는 시스템입니다.

```bash
brew tap ai-barracks/ai-barracks
brew install ai-barracks

aib init ~/my-project                          # 배럭 초기화 + 훅 자동 설정
aib start claude "버그 수정" --skip-permissions  # 에이전트 배치
```

`aib init`을 실행하면 프로젝트 디렉토리에 다음 구조가 생깁니다:

```
your-project/
├── CLAUDE.md        # 세션 프로토콜 자동 주입 (Claude Code)
├── GEMINI.md        # 세션 프로토콜 자동 주입 (Gemini CLI)
├── AGENTS.md        # 세션 프로토콜 자동 주입 (Codex CLI)
├── agent.yaml       # 배럭 메타데이터 (GitAgent 호환)
├── SOUL.md          # 에이전트 정체성 (전문성, 성격, 가치관)
├── RULES.md         # 행동 규칙 — 에이전트가 자동으로 학습하여 추가
├── GROWTH.md        # 언제 뭘 기록할지 결정 테이블
├── SESSIONS.md      # 활성 세션 인덱스 (gitignored)
├── sessions/        # Veritable Records aka 'Silok'
│   ├── .active      # 현재 세션 ID 마커
│   └── claude-20260408-2202.md
└── wiki/            # 장기 지식 베이스 (LLM-Wiki)
    ├── Index.md     # 토픽 카탈로그 (~750 토큰)
    ├── Log.md       # 변경 기록
    └── topics/      # 개별 지식 페이지
```

## 3계층 아키텍처

```
┌─────────────────────────────────────────────────────────┐
│  Layer 1: Session Index (SESSIONS.md)                   │
│  "지금 누가 무엇을 하고 있나" — 실시간 에이전트 레지스트리     │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Session History (sessions/*.md)                │
│  "그때 무슨 일이 있었나" — Veritable Records aka 'Silok'    │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Memory / Wiki (wiki/)                         │
│  "우리가 알고 있는 것" — Karpathy LLM-Wiki 패턴의 장기 지식  │
└─────────────────────────────────────────────────────────┘
```

### Layer 1: 누가 지금 뭘 하고 있나

`SESSIONS.md`는 현재 활성 에이전트 목록입니다. 세션이 시작되면 Hook이 자동으로 등록하고, 끝나면 삭제합니다. 2시간 이상 업데이트 없으면 stale로 정리합니다. 사용자가 건드릴 필요가 없습니다.

### Layer 2: Veritable Records aka 'Silok'

세션 기록은 **절대 삭제하지 않습니다**.

```markdown
# Session: claude-20260408-2202

- **Task**: slack-agent-bridge 라우팅 버그 3건 수정 및 배포

## Log
- [23:15] Slack 봇 라우팅 이슈 분석 → 버그 3건 발견
- [23:15] 3건 수정 + 테스트 10개 추가 → commit, push, 재시작 완료

## Decisions
- non-rate-limited 실패는 cooldown cascade를 트리거하지 않도록 변경
- router 매칭 실패 시 None 반환하여 기본 workspace 사용
```

나중에 "그때 왜 그렇게 결정했지?"라고 찾아볼 수 있습니다. Veritable Records aka 'Silok'이 500년간 국가의 의사결정을 기록했듯이, 세션 기록은 프로젝트의 의사결정 이력을 영구 보존합니다.

### Layer 3: LLM-Wiki

[Karpathy의 LLM-Wiki 패턴](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)을 구현합니다. 세션에서 발견한 지식을 `wiki/topics/`에 추출하여 장기 기억으로 저장합니다.

에이전트는 세션 시작 시 `wiki/Index.md`(~750 토큰)만 읽고, 현재 작업과 관련된 토픽만 선택적으로 로딩합니다. 불필요한 컨텍스트 로딩을 줄이는 구조입니다.

## Cross-CLI: Claude, Gemini, Codex를 하나의 배럭에서

AI Barracks의 가장 큰 특징은 **CLI 종류에 상관없이 같은 배럭을 공유**한다는 점입니다.

```bash
# Claude에서 작업하다가 rate limit
# → Gemini로 이어받기:
aib hook continue claude-20260405-2230
# 이전 세션의 Log, Decisions, Blockers가 컨텍스트로 주입됨
```

Claude Code에서 시작한 작업을 Gemini CLI로 이어받고, 다시 Codex CLI로 넘기는 것이 가능합니다. 각 CLI의 프로토콜 파일(CLAUDE.md, GEMINI.md, AGENTS.md)에 동일한 세션 프로토콜이 주입되기 때문입니다.

실제로 Claude가 rate limit에 걸렸을 때 Gemini로 자연스럽게 전환하여 작업을 이어가는 것이 일상적인 워크플로우가 되었습니다.

## Growth Protocol: 반복 설명 비용을 줄이는 자동 규칙 축적

v0.8.2에서 도입하고 v1.0.0에서 크게 강화한 기능입니다.

처음에는 "지식 발견 시 wiki 업데이트"라는 모호한 지시만 있었고, 12개 세션 중 wiki 추출은 1건뿐이었습니다. 에이전트가 뭘 언제 어디에 기록해야 하는지 몰랐기 때문입니다.

이 문제를 **Decision Table**로 해결했습니다:

| 세션 중 이벤트 | 기록 위치 |
|---------------|-----------|
| 새 사실/아키텍처 결정 발견 | `wiki/topics/` |
| 사용자가 행동 교정 | `RULES.md` Must Always/Never |
| 실수/실패 패턴 발견 | `RULES.md` Learned |
| 같은 지시 2회 이상 반복 | `RULES.md` Learned |
| 실패/오류 발생 | `sessions/{id}.md` § Retries |
| 같은 오류 2회 반복 | `RULES.md` Learned |

핵심 원칙은 **"세션 종료 시가 아니라 발견 즉시 기록"**입니다. 세션이 갑자기 끝나도 지식이 보존됩니다.

세션 종료 시점은 저장보다 **점검에 가깝습니다**. 기록 누락이 있었는지만 확인합니다.

### 자기수정 프로토콜 (v0.9.0)

v0.9.0에서 추가한 기능입니다. Meta의 HyperAgents 논문에서 "자기 개선 에이전트가 독립적으로 진화시킨 구성요소" 중 ai-barracks에 없던 것이 **재시도/자기수정 로직**이었습니다.

세션 파일에 `## Retries` 섹션을 추가하여 에이전트가 실패 시 원인을 분석하고 수정 시도를 기록하도록 했습니다. 같은 오류가 2회 반복되면 `RULES.md`에 패턴으로 등록하여 재발을 방지합니다.

### 에이전트의 정체성은 사용자가 관리한다

SOUL.md는 에이전트의 전문성, 성격, 가치관을 정의합니다. [GitAgent](https://github.com/open-gitagent/gitagent) 표준을 따릅니다.

중요한 설계 결정: **에이전트는 SOUL.md를 직접 수정하지 않습니다.** 에이전트가 자기 정체성을 임의로 바꾸지 못하게 했습니다. 대신 세션 로그에 "Expertise에 X 추가 제안"처럼 제안만 기록하고, 최종 반영은 사용자가 승인합니다.

> **"wiki는 기억하고, RULES는 교정하고, SOUL은 승인받아 진화한다."**

## Hook 기반 자동화: LLM이 잊어도 시스템이 놓치지 않게

AI Barracks의 설계 원칙 중 하나는 **"LLM의 instruction-following에 의존하지 않는다"**입니다.

세션 등록, stale 정리, 상태 기록, 자동 요약 — 이런 기계적 작업은 모두 CLI Hook이 처리합니다. LLM이 프로토콜을 무시하거나 잊어버려도 시스템은 정상 동작합니다.

```
SessionStart Hook          임무 수행 중            SessionEnd Hook
─────────────────          ──────────────          ─────────────────
 Stale 정리                 Log 기록 (LLM)         SESSIONS.md 정리
 SESSIONS.md 등록           Decisions 기록          Status → completed
 세션 파일 생성              Retries 기록            Auto-summary 생성
 Violation 주입 ★          wiki 업데이트            Violation 기록 ★
 Blocker carry-over ★      RULES 갱신
 컨텍스트 주입
```

### 불변식 강제 (v0.9.0)

v0.9.0에서는 OpenAI의 Harness Engineering에서 배운 핵심 원칙을 적용했습니다: **"에이전트에게 규칙을 말하지 말고, 기계적으로 강제하라."**

SessionEnd hook이 세션 종료 시 3가지 불변식 위반을 자동 감지하여 `.violations` 파일로 기록합니다:
- `TASK_PENDING`: Task 필드가 업데이트되지 않음
- `GROWTH_MISSING`: 의미있는 작업이 있으나 Wiki Extractions가 비어있음
- `UNRESOLVED_BLOCKERS`: 해소되지 않은 블로커 존재

다음 세션의 SessionStart hook에서 이 위반 사항을 LLM 컨텍스트에 remediation instruction으로 주입합니다. "규칙을 알려주는 것"이 아니라 "위반을 감지하고 수정을 요구하는 것"으로 전환한 것입니다.

SessionEnd Hook은 세션 원본 기록을 자동 요약하여 구조화된 기록(Log, Decisions, Wiki Extractions)으로 변환합니다. LLM이 세션 중 기록을 빼먹어도 사후 복구가 가능합니다.

## 그 외 기능들

### Council: 다중 AI 토론

```bash
aib council "REST vs gRPC for internal services"
aib council -m adversarial -r 3 "Kafka vs Pulsar"
```

Claude, Gemini, Codex를 병렬 실행하여 멀티라운드 교차 리뷰 후 합의안을 도출합니다. 실제로 이 시스템의 설계 결정들을 Council을 통해 토론하고 합의했습니다.

### Slack 연동

[slack-agent-bridge](https://github.com/CYRok90/slack-agent-bridge)와 연동하면 Slack 메시지가 `~/.aib/barracks.json` 기반으로 적절한 배럭에 자동 라우팅됩니다. 데스크톱에서는 CLI, 모바일에서는 Slack으로 같은 배럭에 접근합니다.

### Wiki 건강성 자동 관리

wiki가 쌓이면서 오래된 정보, 200줄을 넘는 토픽, Index와 실제 파일의 불일치 같은 문제가 생깁니다. `aib wiki lint`는 이런 문제를 자동으로 감지합니다:

```bash
aib wiki lint           # 문제 감지
aib wiki lint --fix     # 자동 수정 가능한 항목 처리
```

OpenAI가 Codex 프로젝트에서 "doc-gardening 에이전트"로 기술 부채를 지속적으로 상환한 것과 같은 접근입니다. "기술 부채는 고금리 대출이다 — 연속 소액 상환이 일괄 청산보다 낫다."

## 실제 운용 현황

현재 3개 배럭을 운용 중입니다:

| 배럭 | 용도 | 세션 수 | wiki 토픽 |
|------|------|---------|----------|
| ai_barracks_management | 시스템 개발/관리 | 40+ | CLI 아키텍처, 에이전트 엔지니어링 리서치 |
| career_management | 면접 준비 | 30+ | 8개 (팀 구조, 기술 아티클, 예상 질문 70+) |
| data_engineering | 데이터 엔지니어링 | 10+ | ClickHouse, S3 Lakehouse |

career_management 배럭에서는 PDF 이력서 분석, 채용공고 분석, YouTube 발표 분석을 모두 wiki로 지식화하여 면접 준비에 활용했습니다.

## 시작하기

```bash
# 설치
brew tap ai-barracks/ai-barracks
brew install ai-barracks

# 배럭 초기화
aib init ~/my-project

# SOUL.md를 열어 에이전트 정체성 커스터마이징
# (전문성, 성격, 가치관을 프로젝트에 맞게 수정)

# 에이전트 배치
aib start claude "리팩토링" --skip-permissions
aib start gemini "로그 분석"
aib start codex "테스트 작성" --skip-permissions
```

세션이 쌓일수록 RULES.md에는 학습한 규칙이, wiki/에는 프로젝트 지식이 축적됩니다. 사람이 다시 설명하는 대신, 프로젝트가 맥락을 보존하게 됩니다.

## CommandCenter: 배럭 관제 데스크톱 앱

CLI만으로 배럭을 관리하면서 느낀 불편함이 하나 있었습니다. **파일을 직접 찾아다녀야 한다는 것.** SOUL.md를 편집하려면 파일 탐색기에서 찾아야 하고, 세션 히스토리를 보려면 sessions/ 디렉토리를 열어야 합니다. 강력한 컨셉(Growth Protocol, File Ownership, Wiki)을 갖추고 있지만, 눈에 보이지 않으면 까먹기 쉽습니다.

이 문제를 해결하기 위해 **AI Barracks CommandCenter**를 만들었습니다. Tauri v2(Rust + React) 기반의 macOS 데스크톱 앱입니다.

- **Overview**: 배럭 상태, Expertise 태그, 통계를 한눈에
- **Config**: SOUL.md/GROWTH.md는 마크다운 에디터, RULES.md는 구조화된 관리 UI, agent.yaml은 폼 에디터
- **Agents**: 세션 히스토리 타임라인, 필터링, 완료된 작업 Continue
- **Wiki**: 토픽 브라우저 + Wiki Lint 실행
- **Git**: Branch/changes 상태, commit/push, 커밋 히스토리 상세 보기, mono-repo 지원
- **System**: 전체 배럭 버전 대시보드, 선택적/일괄 Sync
- **내장 터미널**: xterm.js + portable-pty 기반 완전한 터미널, 모든 UI 액션 터미널 연동
- **커맨드 팔레트** (`Cmd+K`): 배럭 컨텍스트 기반 명령어 추천 + Quick Commands
- **검색**: 세션, 위키, 규칙, 설정 통합 검색
- **Light/Dark 테마**: Apple HIG 기반

스타크래프트의 Command Center처럼 — Barracks에서 유닛(에이전트)을 생산하고, Command Center에서 모든 것을 관제합니다.

```bash
# CommandCenter 빌드 & 실행
cd ai-barracks-cc
npm install && npm run tauri build
open src-tauri/target/release/bundle/macos/AI\ Barracks\ CommandCenter.app
```

---

**GitHub**: [ai-barracks/ai-barracks](https://github.com/ai-barracks/ai-barracks) (CLI)
**GitHub**: [ai-barracks/ai-barracks-cc](https://github.com/ai-barracks/ai-barracks-cc) (CommandCenter)
**License**: MIT
**현재 버전**: CLI v1.0.0 / CommandCenter v1.0.0
