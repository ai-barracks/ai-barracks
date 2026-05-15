# Changelog

## [1.2.1] - 2026-05-15

### Fixed
- **SessionStart hook — false-positive "no Wiki Extractions" alerts (variant F)**: `cmd_hook_start` used `grep -A1 "## Wiki Extractions"` to decide whether the previous session had recorded any extraction. That window only saw the single line right after the header, so the four-line guidance comment block emitted by the session template hid any real `- ` bullet placed below it, and the recommended `(없음 — wiki: … / RULES: … / SOUL: …)` parenthetical "no extractions, with reason" form was never accepted either. The detector now scans the full Wiki Extractions section (header through the next `## `), strips HTML comments and blank lines, and fires only when the section is genuinely empty. Sessions whose authors followed the protocol — whether with bullets or parenthetical reasons — no longer surface the same alert every time a new session starts. See `wiki/topics/AIB-Hook-Stale-Cleanup-Bug.md` variant F for the full diagnosis.

### Tests
- `tests/test_hook_wiki_extractions.sh` — pins the new detector against four fixture cases (real bullet under template comments, parenthetical reason line, comments-only, truly empty).

## [1.2.0] - 2026-05-09

### Added
- **Skills loading (S6 — was drafted as S4)**: `aib sync` now materializes `.claude/skills/<n>` relative symlinks (W1 — Claude Code native discovery) and an auto-managed `Available Skills` block in CLAUDE.md/GEMINI.md/AGENTS.md (W2 — Gemini/Codex text catalog). Closes the catalog-vs-loading gap that shipped in v1.1.0.
- `aib skills check [path]` — read-only drift diagnostic.
- `aib skills doctor` extended to validate W1+W2 consistency.
- `aib start <client>` surfaces a non-blocking drift warning before launch.
- `templates/.gitignore` shipped; existing barracks have `.claude/skills/` appended on next sync.

### Changed
- `cmd_sync` step ordering: `inject_protocol` runs first (creates CLAUDE.md/GEMINI.md/AGENTS.md), then `sync_new_files` (auto-seeds `templates/skills/council/`), then the skills-derived wirings (`inject_skills_section` → `sync_claude_skills_symlinks` → `ensure_gitignore_skills_entry`) so they observe the post-seed state. Earlier ordering caused fresh `aib init` + `aib sync` to end in a drifted state.

### Compatibility
- v1.1 catalog SKILL.md files are loaded as-is. No migration command needed; first `aib sync` after upgrade materializes the new wirings.
- W2 marker block is harmless markdown to v1.1.x readers.

### Docs
- `docs/rfcs/v1.1-skills.md` — added Loading (S4 → renumbered S6) section.
- `templates/docs/skills-protocol.md` — rewrote 호출 규약 section.

## [1.1.0] - 2026-05-08

### Added — Skills as First-Class Capability
- **`templates/skills/council/SKILL.md`**: 첫 reference 스킬 시드. 새 배럭 init 또는 `aib sync` 시 자동 배포. Anthropic Agent Skills 표준 frontmatter(`name`/`description`) + Claude Code 호환(`argument-hint`/`allowed-tools`) + ai-barracks 확장(`aib_version`/`upstream`/`growth_origin`).
- **`templates/agent.yaml` skills 스키마 확장**: 기존 `skills: [council]` 리스트 → 객체 `skills: {discovery: auto|explicit, enabled: [...]}`. 1.0.x 리스트 형식은 backward compat 유지 (`discovery: explicit`로 해석).
- **`aib skills list [path]`**: 배럭의 `skills/` 스캔 후 슬러그 + description 표 출력.
- **`aib skills doctor [path]`**: SKILL.md frontmatter 유효성 검사 — name=슬러그 일치, description 존재, orphan 디렉터리 감지.
- **`templates/docs/skills-protocol.md`**: Skills 사용/생성 프로토콜 가이드. session/wiki/growth 프로토콜과 동일 위계.
- **`docs/rfcs/v1.1-skills.md`**: v1.1 도입 RFC (Anthropic Skills + GitAgent GAP 0.1.0 호환 근거, Open Questions Q1~Q8, aib-cc 영향 분석).

### Changed
- `AIB_VERSION` 1.0.1 → 1.1.0. `aib sync`의 `sync_version_stamp`가 모든 배럭의 agent.yaml을 자동 갱신.

### Compatibility
- 1.0.x 클라이언트는 새 `skills:` 객체 스키마 무시(YAML unknown key). 1.1 클라이언트는 리스트·객체 둘 다 파싱.
- 기존 배럭은 `aib sync` 시 `templates/skills/` 신규 파일만 추가됨. 사용자가 작성한 SKILL.md는 절대 덮어쓰지 않음.

## [1.0.1] - 2026-05-04

### Fixed
- **Codex `--skip-permissions` 회귀 대응**: Codex CLI 0.128에서 제거된 `--full-auto` 대신 `--dangerously-bypass-approvals-and-sandbox`를 매핑. 이전 aib는 `aib start codex --skip-permissions` 실행 시 즉시 종료됐음.

### Added
- **`validate_claude_settings()` 사전검사**: `aib start claude` launch 직전 `.claude/settings*.json`의 `permissions.allow[]` 중 `Bash(...)` 패턴 quote 균형을 검사해 깨진 항목을 경고. Claude 2.1.118이 CommandCenter PTY에서 invisible Settings 다이얼로그로 stdin을 가로채는 회귀 진단 시간 단축이 목적.
- **README 트러블슈팅 섹션** 추가 — Claude TUI 입력 차단 / Codex `--full-auto` 거부 두 케이스 명시.

## [1.0.0] - 2026-04-17

AI Barracks v1.0.0 공식 릴리즈.

v0.9.0~v0.9.1의 변경사항을 포함하며, 프로덕션 안정 버전으로 선언.

### Highlights (since v0.8.2)
- **Invariant Violation System**: Hook 기반 불변식 강제 (TASK_PENDING, GROWTH_MISSING, UNRESOLVED_BLOCKERS)
- **Wiki Lint**: `aib wiki lint [--fix]` — STALE, OVERSIZED, MISSING, UNINDEXED, DUPLICATE 감지
- **Progressive Disclosure**: AGENTS.md 목차화 + docs/ 분리 (session/growth/wiki protocol)
- **Self-Correction Protocol**: `## Retries` 섹션 + 동일 오류 2회 반복 시 RULES.md 패턴화
- **Atomic barracks.json write**: jq 실패 시 데이터 손실 방지

---

## [0.9.1] - 2026-04-16

### Fixed
- `register_barrack()`: jq 실패 시 barracks.json이 빈 파일로 덮어써지는 버그 수정 — tmp 파일에 쓰고 JSON 검증 후 atomic mv
- `unregister_barrack()`: 동일한 안전장치 적용

## [0.9.0] - 2026-04-14

### Motivation

4개의 에이전트 엔지니어링 글을 분석한 결과를 ai-barracks에 반영한 릴리즈.

**참고 자료:**
- [Anthropic — Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps): GAN 영감 Generator/Evaluator 멀티 에이전트 패턴. 핵심 인사이트 — "모델에게 자기비판보다 독립적 외부 평가자를 회의적으로 tuning하는 것이 효과적"
- [Anthropic — Managed Agents](https://www.anthropic.com/engineering/managed-agents): 뇌(Claude+하네스)/손(샌드박스)/세션(이벤트 로그) 3-레이어 분리 아키텍처. "모델 개선에 따라 낡아지는 가정을 인코딩하지 말 것"
- [Meta — HyperAgents](https://cobusgreyling.medium.com/hyperagents-by-meta-892580e14f5b): 자기 참조적 에이전트가 독립 진화시킨 6개 구성요소(persistent memory, 성능 추적, 다단계 평가, 의사결정 프로토콜, 도메인 지식 DB, 재시도/자기수정). ai-barracks에 없는 것: **재시도/자기수정 로직**
- [OpenAI — Harness Engineering](https://openai.com/index/harness-engineering/): 3기둥 — Context Engineering(AGENTS.md는 목차, docs/가 깊은 지식), Architectural Constraint Enforcement(불변식을 기계적으로 강제), Entropy Management(doc-gardening 에이전트). "에이전트에게 규칙을 말하지 말고, 린터로 강제하라"

**핵심 원칙:**
> "에이전트에게 규칙을 말하지 말고, 기계적으로 강제하라" (OpenAI)
> "모델이 개선되어도 하네스의 필요성은 사라지지 않고, 필요한 종류가 이동할 뿐" (Anthropic)
> "에이전트가 인프라의 소비자에서 생산자로 전환된다" (Meta)

### Added

#### Hook 기반 불변식 강제 (Invariant Violation System)
- `cmd_hook_end`: 세션 종료 시 3가지 위반 사항을 `sessions/{id}.violations` 파일로 기록
  - `TASK_PENDING`: Task 필드가 "(pending)"으로 남아있음
  - `GROWTH_MISSING`: 의미있는 작업(log>=2 또는 decisions>=1)이 있으나 Wiki Extractions 비어있음
  - `UNRESOLVED_BLOCKERS`: 해소되지 않은 블로커 존재
- `cmd_hook_start`: 이전 세션의 `.violations` 파일을 읽어 `[AIB VIOLATION]` + `[AIB REMEDIATION]` 메시지를 LLM 컨텍스트에 주입 (OpenAI remediation injection 패턴)
- Blocker carry-over: 이전 세션의 미해결 블로커를 `[AIB BLOCKER]`로 다음 세션에 자동 주입
- 기존 empty Wiki Extractions 체크를 violations fallback으로 유지

#### `aib wiki lint` 명령어 (Doc-Gardening)
- `[STALE]`: `[YYYY-MM-DD]` 날짜 태그가 6개월 경과한 fact 감지
- `[OVERSIZED]`: 200줄 초과 토픽 파일 감지
- `[MISSING]`: Index.md에 참조되나 실제 파일이 없는 토픽
- `[UNINDEXED]`: 파일은 존재하나 Index.md에 등록되지 않은 토픽
- `[DUPLICATE]`: RULES.md 중복 규칙 감지
- `--fix` 옵션: STALE 마커 `[STALE?]` 자동 삽입

#### AGENTS.md 목차화 + docs/ 분리 (Progressive Disclosure)
- `session-memory-protocol.md` 축소: 75줄 → ~40줄 목차형 (File Map 포함)
- 새 `docs/` 디렉토리 (3개 상세 프로토콜 문서):
  - `docs/session-protocol.md`: 세션 시작/중/종료 상세 + 자기수정 프로토콜
  - `docs/growth-protocol.md`: Growth Audit 절차 + Invariant Violations 설명 + SOUL.md 제안 규칙
  - `docs/wiki-protocol.md`: Wiki 갱신 규칙 + Schema Rules + wiki lint 사용법
- `.sync-manifest`에 `system` 전략 추가 (매 sync 시 항상 템플릿에서 덮어쓰기)
- `sync_new_files()`에 `system` 전략 처리 로직 추가

#### 자기수정 프로토콜 (Self-Correction Protocol)
- `session-context.md` 템플릿에 `## Retries` 섹션 추가
  - Format: `- [HH:MM] <실패> → 원인: <분석> → 수정: <시도> → 결과: <성공/실패>`
- `GROWTH.md` Decision Table에 2행 추가:
  - 실패/오류 발생 → `sessions/{id}.md` § Retries
  - 같은 오류 2회 반복 → `RULES.md` Learned
- Blocker carry-over와 결합하여 세션 간 자기수정 루프 구성

### Changed
- `AIB_VERSION`: 0.8.2 → 0.9.0
- Help 텍스트에 `wiki lint [--fix]` 명령어 추가

### Migration Guide
- `aib sync`를 실행하면 기존 배럭에 자동 적용:
  - CLAUDE.md/GEMINI.md/AGENTS.md의 마커 블록이 새 목차형으로 교체 (사용자 커스텀 보존)
  - `docs/` 디렉토리에 3개 파일 자동 생성
- **수동 필요**: 기존 배럭의 `GROWTH.md`는 `scaffold` 전략이므로 자동 업데이트 안 됨
  - Decision Table에 다음 2행을 수동 추가:
    ```
    | 실패/오류 발생 | `sessions/{id}.md` § Retries | 실패 내용, 원인 분석, 수정 시도, 결과 |
    | 같은 오류 2회 반복 | `RULES.md` Learned | "X 시 Y 확인 필수" 패턴화 |
    ```
- `.gitignore`에 추가 권장: `sessions/*.violations`, `sessions/*.violations.delivered`

---

## [0.8.2] - 2026-04-07
- Bug fixes and documentation updates
- Growth Protocol + File Ownership system

## [0.8.0] - 2026-04-05
- Growth Protocol 도입
- File Ownership 마커 시스템 (SYSTEM, RECORD, USER-OWNED, AUTO-GROW, INJECTED)

## [0.7.0]
- Enhanced `aib sync` (idempotent upgrade)

## [0.6.0]
- Barracks registry (다중 배럭 관리)

## [0.5.0]
- GitAgent 호환성 (agent.yaml + SOUL.md + RULES.md)

## [0.4.0]
- Session auto-recording (script capture + LLM summarization)
