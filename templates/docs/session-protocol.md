<!-- AIB:OWNERSHIP — [SYSTEM] aib sync가 관리하는 프로토콜 문서. 수동 수정 금지. -->
# Session Protocol — 상세 가이드

## Session Layer (SESSIONS.md + sessions/)

SESSIONS.md 등록/해제와 sessions/ 파일 생성은 hook이 자동 처리한다.
LLM의 핵심 의무는 **sessions/{AIB_SESSION_ID}.md 파일을 업데이트하는 것**이다.

### 세션 시작 — LLM이 반드시 수행할 것
Hook이 SESSIONS.md 등록과 세션 파일 생성을 자동 처리한다.
LLM은 세션 시작 시 반드시 다음을 수행한다:
1. `sessions/.active` 파일을 읽어 현재 세션 ID를 확인
2. `sessions/{세션ID}.md` 파일을 읽어 자신의 세션 파일을 인지
3. 첫 사용자 메시지 후 **Task** 필드를 실제 작업 내용으로 업데이트
4. `RULES.md` 읽기 — 이전 세션에서 학습한 규칙 확인
5. `GROWTH.md` 읽기 — 성장 트리거와 체크리스트 확인

### 세션 중 — LLM이 반드시 수행할 것
1. 첫 사용자 메시지 후 `sessions/{id}.md`의 **Task** 필드를 실제 작업 내용으로 업데이트
2. 의미있는 작업 단위 완료 시 `## Log`에 append: `- [HH:MM] <요청 요약> → <결과>`
3. 주요 결정 시 `## Decisions`에 기록
4. 블로커 발생 시 `## Blockers`에 기록
5. 매 턴마다 기록하지 않는다 — 의미있는 마일스톤에서만
6. **Growth: GROWTH.md의 Decision Table에 해당하는 이벤트 발생 시 즉시 wiki/RULES.md 갱신**

### 세션 종료
- SESSIONS.md에서 자기 항목 삭제
- 항목이 이미 없으면 (다른 세션이 stale로 정리) 무시

## Session History Layer (sessions/)

sessions/{id}.md는 조선실록처럼 세션의 모든 작업을 기록하는 영구 보존 로그다.
SESSIONS.md가 "지금 누가 무엇을 하고 있나"라면, sessions/*.md는 "그때 무슨 일이 있었나"다.

### 세션 시작
- `sessions/{id}.md`의 Task를 실제 작업 내용으로 업데이트

### 세션 중
- 의미있는 작업 단위 완료 시 `## Log`에 append:
  `- [HH:MM] <사용자 요청 요약> → <수행 결과/상태>`
- 매 턴마다 기록하지 않는다 (토큰 낭비 방지)
- 주요 결정은 `## Decisions`에, 블로커는 `## Blockers`에 기록

### 실패 시 자기수정 (Self-Correction Protocol)
1. 오류 발생 시 `## Retries`에 기록:
   `- [HH:MM] <실패 내용> → 원인: <분석> → 수정: <시도> → 결과: <성공/실패>`
2. 같은 오류 2회 반복 시 `RULES.md` Learned에 패턴 등록: "X 시 Y 확인 필수"
3. 해소되지 않은 블로커 → `## Blockers`에 기록 → 다음 세션에 자동 carry-over

### 세션 종료 — Growth Audit
→ [docs/growth-protocol.md](growth-protocol.md) 참조
