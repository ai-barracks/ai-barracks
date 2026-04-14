<!-- AIB:OWNERSHIP — [SYSTEM] aib sync가 관리하는 프로토콜 문서. 수동 수정 금지. -->
# Wiki Protocol — 상세 가이드

## Memory Layer (wiki/)

### 세션 시작
1. `wiki/Index.md` 읽기 — 토픽 카탈로그 파악
2. 현재 작업과 관련된 토픽 파일만 선택 로딩 (`wiki/topics/{topic}.md`)
3. 모든 토픽을 읽지 않는다 — 토큰 경제성 최우선

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

## Schema Rules

1. **토픽당 1파일**, 200줄 초과 시 분할
2. **형식**: H1 제목, H2 섹션, bullet facts. 각 사실에 `[YYYY-MM-DD]` 날짜 태그 필수
3. **출처**: 각 사실에 source 명시 (세션 ID, 사용자, 외부 URL)
4. **검증**: 6개월 경과 사실은 `[STALE?]` 표시 후 재검증
5. **비밀정보 금지**: API 키/비밀번호 저장 불가
6. **중복 금지**: 행동 규칙(do/don't)은 RULES.md에, 맥락 지식(facts, decisions)만 wiki에 저장
7. **Lint**: 신규 토픽 생성 시 기존 토픽과 범위 중복 여부 확인. 중복되면 기존 토픽에 병합

## Wiki 건강성 관리

`aib wiki lint` 명령어로 다음을 자동 검사:
- `[STALE]`: 6개월 경과 날짜 태그 감지
- `[OVERSIZED]`: 200줄 초과 토픽 감지
- `[MISSING]`: Index.md에 참조되나 실제 파일 없음
- `[UNINDEXED]`: 파일은 있으나 Index.md에 등록 안 됨
- `[DUPLICATE]`: RULES.md 중복 규칙 감지

`aib wiki lint --fix`로 STALE 마커 자동 삽입 가능.
