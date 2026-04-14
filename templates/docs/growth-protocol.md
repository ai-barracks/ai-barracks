<!-- AIB:OWNERSHIP — [SYSTEM] aib sync가 관리하는 프로토콜 문서. 수동 수정 금지. -->
# Growth Protocol — 상세 가이드

> 배럭별 커스터마이징은 `GROWTH.md` (USER-OWNED)에서 한다.
> 이 문서는 Growth Audit 절차의 표준 가이드다.

## End-of-Session Growth Audit

종료 시점은 **저장 시점이 아니라 감사(audit) 시점**이다.

### 1단계: 누락 점검
GROWTH.md의 Decision Table 기준으로 점검:
- `## Decisions`에 기록된 결정 중 wiki/RULES에 반영 안 된 것이 있는가?
- `## Log`에 기록된 작업 중 재사용 가능한 지식이 있는가?
- 오류/수정에서 학습한 규칙이 있는가?
- `## Retries`에 반복 실패 패턴이 있는가? → RULES.md에 등록

### 2단계: Wiki Extractions 기록
`sessions/{id}.md`의 `## Wiki Extractions`에 갱신 내역을 기록한다.
**wiki, RULES.md, Identity Suggestions 모두 포함.**

### 3단계: 갱신 없을 때
갱신이 없으면 **분류별 사유**를 적는다 (단순 "(없음)" 금지):
```
(없음 — wiki: 단순 오타 수정으로 새 지식 없음 / RULES: 교정·실패 없음 / SOUL: 해당 없음)
```

### 4단계: 종료 마킹
- `**Ended**` 필드에 종료 시각 기록
- 파일은 삭제하지 않는다 — 실록은 영구 보존

## Invariant Violations

hook이 세션 종료 시 다음 위반을 자동 감지하여 `.violations` 파일로 기록한다:
- **TASK_PENDING**: Task 필드가 "(pending)"으로 남아있음
- **GROWTH_MISSING**: 의미있는 작업이 있으나 Wiki Extractions가 비어있음
- **UNRESOLVED_BLOCKERS**: 해소되지 않은 블로커 존재

다음 세션 시작 시 위반 사항이 LLM 컨텍스트에 주입된다 (remediation injection).

## SOUL.md 제안 규칙

SOUL.md는 에이전트가 **직접 수정하지 않는다**.
대신 `sessions/{id}.md`의 `## Identity Suggestions`에 제안만 기록한다.

제안 조건:
- 동일 도메인 3회 이상 반복 작업
- 사용자 피드백 2회 이상 일관적
- 배럭 역할과 현재 Expertise 미스매치

최종 반영은 **사용자 승인 후**.
