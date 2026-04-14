<!-- AIB:OWNERSHIP — [USER-OWNED] 사용자가 배럭에 맞게 커스터마이징하는 파일. 에이전트는 읽기만 합니다. -->
# Growth Protocol

> 에이전트가 세션 중 wiki/, RULES.md를 **자발적으로 성장시키기 위한 결정 규칙**.
> 이 파일은 배럭별로 자유롭게 커스터마이징 가능하다 (sync 시 덮어쓰지 않음).

## Decision Table — 발견 즉시 기록 (CRITICAL)

세션 **종료 시**가 아니라, **발견하는 즉시** 아래 표에 따라 기록한다.

| 세션 중 이벤트 | 기록 위치 | 예시 |
|---------------|-----------|------|
| 새 사실/아키텍처 결정 발견 | `wiki/topics/` | 배포 순서, API 동작, 디버깅 패턴 |
| 사용자가 행동 교정 ("그렇게 하지 마") | `RULES.md` Must Always/Never | "파일 수정 전 반드시 재읽기" |
| 실수/실패 패턴 발견 | `RULES.md` Learned | "sed 멱등성 문제 → awk 사용" |
| 같은 지시 2회 이상 반복 | `RULES.md` Learned | 반복되는 건 규칙으로 고착 |
| 정체성 관련 패턴 (3회+ 같은 영역 작업) | `sessions/{id}.md` § Identity Suggestions | "Expertise에 X 추가 제안" |
| 실패/오류 발생 | `sessions/{id}.md` § Retries | 실패 내용, 원인 분석, 수정 시도, 결과 |
| 같은 오류 2회 반복 | `RULES.md` Learned | "X 시 Y 확인 필수" 패턴화 |

**NOT growth-worthy** — 기록하지 않을 것:
- 단순 git commit, 오타 수정, 파일 이름 변경
- 일회성 사용자 선호 (session log에만)
- 이미 wiki에 있는 내용의 반복

## End-of-Session Audit

세션 종료 전, 위 Decision Table을 기준으로 누락을 점검한다.
종료 시점은 **저장 시점이 아니라 감사(audit) 시점**이다.

1. `## Decisions` 검토 → wiki/RULES에 반영할 것이 있는가?
2. `## Log` 검토 → 재사용 가능한 지식이 있는가?
3. 오류/수정 검토 → 학습한 규칙이 있는가?

### Wiki Extractions 작성 규칙

`sessions/{id}.md`의 `## Wiki Extractions`에 갱신 내역을 기록한다.
**wiki, RULES.md, Identity Suggestions 모두 포함.**

갱신이 없으면 **분류별 사유**를 적는다 (단순 "(없음)" 금지):
```
(없음 — wiki: 단순 오타 수정으로 새 지식 없음 / RULES: 교정·실패 없음 / SOUL: 해당 없음)
```

## RULES.md 관리

- **추가 기준**: 재발 방지 가치가 있는 것만. 일회성 선호는 session log에.
- **비대화 방지**: 사용자가 주기적으로 리뷰하여 중복 제거, 오래된 규칙 정리.
- **형식**: `- [YYYY-MM-DD] <규칙> — source: <세션 ID>`

## SOUL.md 제안 규칙

SOUL.md는 에이전트가 **직접 수정하지 않는다**.
대신 `sessions/{id}.md`의 `## Identity Suggestions`에 제안만 기록한다.

제안 조건:
- 동일 도메인 3회 이상 반복 작업
- 사용자 피드백 2회 이상 일관적
- 배럭 역할과 현재 Expertise 미스매치

최종 반영은 **사용자 승인 후**.
