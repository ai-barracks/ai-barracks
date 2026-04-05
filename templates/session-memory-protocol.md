# Session & Memory Protocol

모든 LLM 세션(Claude, Gemini, Codex)이 동일하게 따르는 프로토콜.
이를 통해 서로 다른 인터페이스/모델 간 세션 인지와 지식 공유를 달성한다.

## Session Layer (SESSIONS.md)

### 세션 시작
1. `SESSIONS.md` 읽기 -- 다른 활성 세션이 무엇을 하고 있는지 파악
2. 자기 항목 추가: `| {client}-{YYYYMMDD}-{HHMM} | {Client Name} | {MM-DD HH:MM} | {MM-DD HH:MM} | {작업 요약} |`
3. 2시간 이상 업데이트 없는 항목이 있으면 stale로 판단하여 삭제하고 wiki/Log.md에 기록

### 세션 중
- 작업 전환 또는 유의미한 마일스톤 달성 시에만 "Working On"과 "Last Update" 갱신
- 매 턴마다 갱신하지 않는다 (토큰/레이턴시 낭비 방지)

### 세션 종료
- SESSIONS.md에서 자기 항목 삭제
- 항목이 이미 없으면 (다른 세션이 stale로 정리) 무시

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
