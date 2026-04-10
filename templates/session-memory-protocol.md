# Session & Memory Protocol

모든 LLM 세션(Claude, Gemini, Codex)이 동일하게 따르는 프로토콜.
이를 통해 서로 다른 인터페이스/모델 간 세션 인지와 지식 공유를 달성한다.

## Session Layer (SESSIONS.md + sessions/)

SESSIONS.md 등록/해제와 sessions/ 파일 생성은 hook이 자동 처리한다.
LLM의 핵심 의무는 **sessions/{AIB_SESSION_ID}.md 파일을 업데이트하는 것**이다.

### 세션 시작 — LLM이 반드시 수행할 것 (CRITICAL)
Hook이 SESSIONS.md 등록과 세션 파일 생성을 자동 처리한다.
LLM은 세션 시작 시 반드시 다음을 수행한다:
1. `sessions/.active` 파일을 읽어 현재 세션 ID를 확인
2. `sessions/{세션ID}.md` 파일을 읽어 자신의 세션 파일을 인지
3. 첫 사용자 메시지 후 **Task** 필드를 실제 작업 내용으로 업데이트
4. `RULES.md` 읽기 — 이전 세션에서 학습한 규칙 확인
5. `GROWTH.md` 읽기 — 성장 트리거와 체크리스트 확인

### 세션 중 — LLM이 반드시 수행할 것 (CRITICAL)
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

sessions/{id}.md는 Veritable Records aka 'Silok'처럼 세션의 모든 작업을 기록하는 영구 보존 로그다.
SESSIONS.md가 "지금 누가 무엇을 하고 있나"라면, sessions/*.md는 "그때 무슨 일이 있었나"다.

### 세션 시작
- `sessions/{id}.md`의 Task를 실제 작업 내용으로 업데이트

### 세션 중
- 의미있는 작업 단위 완료 시 `## Log`에 append:
  `- [HH:MM] <사용자 요청 요약> → <수행 결과/상태>`
- 매 턴마다 기록하지 않는다 (토큰 낭비 방지)
- 주요 결정은 `## Decisions`에, 블로커는 `## Blockers`에 기록

### 세션 종료 — Growth Audit (CRITICAL)
종료 시점은 **저장 시점이 아니라 감사(audit) 시점**이다.
1. GROWTH.md의 Decision Table 기준으로 누락을 점검:
   - `## Decisions`에 기록된 결정 중 wiki/RULES에 반영 안 된 것이 있는가?
   - `## Log`에 기록된 작업 중 재사용 가능한 지식이 있는가?
   - 오류/수정에서 학습한 규칙이 있는가?
2. 갱신 내역을 `## Wiki Extractions`에 기록 (wiki, RULES.md, Identity Suggestions 모두 포함)
3. 갱신 없으면 **분류별 사유** 기술 (단순 "(없음)" 금지)
4. `**Ended**` 필드에 종료 시각 기록
5. 파일은 삭제하지 않는다 — Veritable Records aka 'Silok'은 영구 보존

## Memory Layer (wiki/)

### 세션 시작
1. `wiki/Index.md` 읽기 -- 토픽 카탈로그 파악
2. 현재 작업과 관련된 토픽 파일만 선택 로딩 (`wiki/topics/{topic}.md`)
3. 모든 토픽을 읽지 않는다 -- 토큰 경제성 최우선

### 세션 중 (지식 발견 시)
새로운 맥락 지식(프로젝트 결정, 아키텍처 패턴, 데이터 발견, 외부 API 동작 등)을 발견하면:
1. Index.md에서 관련 토픽 존재 여부 확인
2. 존재하면: 해당 `wiki/topics/{topic}.md` 파일에 append
3. 없으면: 새 토픽 파일 생성 + Index.md에 행 추가
4. `wiki/Log.md` 상단에 변경 기록 append

### Conflict Avoidance
- 파일 쓰기 직전에 반드시 해당 파일을 재읽기하여 최신 상태 확인
- Append를 선호하고, 기존 내용을 덮어쓰지 않는다
- SESSIONS.md에서는 자기 행만 추가/수정/삭제한다
