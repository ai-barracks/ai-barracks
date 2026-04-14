# Session & Memory Protocol

모든 LLM 세션(Claude, Gemini, Codex)이 동일하게 따르는 프로토콜.
이를 통해 서로 다른 인터페이스/모델 간 세션 인지와 지식 공유를 달성한다.
상세 가이드는 docs/ 참조.

## 세션 시작 (CRITICAL)
1. `sessions/.active` → 세션 ID 확인
2. `sessions/{세션ID}.md` → 자신의 세션 파일 인지
3. 첫 사용자 메시지 후 **Task** 필드를 실제 작업 내용으로 업데이트
4. `RULES.md` 읽기 — 이전 세션에서 학습한 규칙 확인
5. `GROWTH.md` 읽기 — 성장 트리거와 체크리스트 확인
→ 상세: [docs/session-protocol.md](docs/session-protocol.md)

## 세션 중 (CRITICAL)
1. `## Log` append: `- [HH:MM] <요청 요약> → <결과>` (의미있는 마일스톤만)
2. 주요 결정 → `## Decisions`, 블로커 → `## Blockers`
3. 실패/오류 → `## Retries`에 원인 분석과 수정 시도 기록
4. **Growth: 발견 즉시 wiki/RULES.md 갱신** (종료 시가 아님)
→ 상세: [docs/session-protocol.md](docs/session-protocol.md)

## 세션 종료 — Growth Audit (CRITICAL)
1. GROWTH.md Decision Table 기준으로 누락 점검
2. `## Wiki Extractions` 기록 (분류별 사유 필수, 단순 "(없음)" 금지)
3. `**Ended**` 필드에 종료 시각 기록
→ 상세: [docs/growth-protocol.md](docs/growth-protocol.md)

## Wiki 갱신
1. `wiki/Index.md`만 읽기 (전체 토픽 로딩 금지 — 토큰 경제성)
2. 새 지식 → 기존 토픽에 append 또는 새 파일 생성 + Index 업데이트
→ 상세: [docs/wiki-protocol.md](docs/wiki-protocol.md)

## File Map
| File | Owner | Purpose |
|------|-------|---------|
| SESSIONS.md | SYSTEM | 활성 세션 인덱스 (hook이 자동 관리) |
| sessions/{id}.md | RECORD | 세션 로그 (영구 보존) |
| wiki/ | AUTO-GROW | 지식 베이스 (Index + topics/) |
| RULES.md | AUTO-GROW | 행동 규칙 (학습 자동 추가) |
| GROWTH.md | USER-OWNED | 성장 트리거 (배럭별 커스터마이징) |
| SOUL.md | USER-OWNED | 에이전트 정체성 |
| docs/ | SYSTEM | 프로토콜 상세 가이드 |
