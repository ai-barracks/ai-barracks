<!-- AIB:OWNERSHIP — [SYSTEM] aib sync가 관리하는 프로토콜 문서. 수동 수정 금지. -->
# Skills Protocol — 상세 가이드

> v1.1.0+. Anthropic Agent Skills(2025-10) 호환. wiki(passive 지식)와 직교하는 *invocable capability* 레이어.

## 위계

| 레이어 | 위치 | 성격 | 갱신 |
|--------|------|------|------|
| 정체성 | SOUL.md | declared | USER-OWNED |
| 행동 규칙 | RULES.md | declarative do/don't | auto-grow |
| 맥락 지식 | wiki/topics/ | passive facts | auto-grow |
| **호출 능력** | **skills/<slug>/SKILL.md** | **invocable** | **manual + growth-suggest** |
| 세션 영속성 | sessions/ | append-only record | auto |

## Directory Layout

```
{barrack}/
└── skills/
    └── <slug>/
        ├── SKILL.md         # 필수
        ├── scripts/         # 선택 (실행 스크립트)
        └── references/      # 선택 (progressive disclosure 추가 파일)
```

- `<slug>` = kebab-case. `name:` frontmatter와 일치해야 함
- 한 배럭 내 슬러그 중복 금지 (파일시스템이 강제)
- 빈 `skills/`는 허용 — 카탈로그 0개로 처리

## SKILL.md Frontmatter

```yaml
---
# 필수 (Anthropic 표준)
name: <slug>                 # kebab-case, 디렉터리명과 일치
description: "<discovery trigger — when Claude should invoke this>"

# 선택 (Claude Code slash command 호환)
argument-hint: "[arg1] [arg2]"
allowed-tools: Bash(./scripts/foo *), Read, Write

# 선택 (ai-barracks 확장 — 무시되어도 동작)
aib_version: "1.1"
upstream: "<source path>"   # 외부 스크립트 참조 시 메타데이터
growth_origin: "manual"      # manual | growth-auto-generated
---

# 본문 — Claude가 invoke 시 읽는 instructions
```

## Discovery (agent.yaml)

```yaml
skills:
  discovery: auto       # 기본. skills/ 자동 스캔
  enabled:              # discovery=explicit일 때만 의미. auto일 땐 무시
    - council
```

backward compat: `skills: [council]` 리스트 형식도 그대로 유효(`discovery: explicit`로 해석).

## Skills vs MCP vs Wiki

- **wiki**: *읽는* 지식. 세션 시작 시 Index만 보고 필요한 토픽 선택 로딩
- **skills**: *호출하는* 능력. progressive disclosure로 metadata만 시스템 프롬프트에 노출, 본문은 invoke 시 로드
- **MCP**: *외부 도구 액세스*. skill 본문에서 MCP 도구 호출 가능 (직교 관계)

## Growth Trigger (제안 — GROWTH.md 사용자 적용)

| 세션 중 이벤트 | 기록 위치 | 예시 |
|---------------|-----------|------|
| 동일 워크플로 3회+ 반복 | `sessions/{id}.md` § Skill Suggestions | "PR 생성 5회 반복 → `/skill:open-pr` 후보" |

세션 종료 audit 시 누적된 후보를 사용자가 검토 후 `skills/<slug>/SKILL.md`로 승격. **에이전트가 skills/를 직접 자동 생성하지 않는다** — SOUL.md 자기수정 금지 원칙과 동일 보호.

## 호출 규약

- Claude Code: 네이티브 `Skill` 도구 (Anthropic 표준)
- 슬랙/외부 클라이언트: `/skill:<name> [args]` 슬래시 명령(클라이언트별 어댑터 책임)
- Gemini/Codex CLI: 네이티브 invoke 미지원 — SKILL.md를 *문서로* 참조, 본문 명시 명령을 직접 실행

## 관리 명령

- `aib skills list [path]` — 슬러그 + description 표 출력
- `aib skills doctor [path]` — frontmatter 유효성 검사 (name 일치, description 존재, orphan 디렉터리 등)

## 보호 원칙

- skills/ 자동 생성 금지 (사용자 승격만 허용)
- SKILL.md 직접 수정은 사용자 또는 명시적 사용자 지시 하에서만
- `allowed-tools` 명시 없는 스킬은 광범위 도구 호출 못함 (클라이언트 제약 의존)

## 참고

- Anthropic 발표: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills (2025-10-16)
- 공식 17개 reference: https://github.com/anthropics/skills
- ai-barracks v1.1 RFC: `docs/rfcs/v1.1-skills.md`
