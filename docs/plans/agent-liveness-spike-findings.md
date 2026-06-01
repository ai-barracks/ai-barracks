# Agent Liveness — Task 1 Spike Findings

> 세션 claude-20260531-2320, 통합 구현(플랜 `docs/superpowers/plans/2026-06-01-agent-liveness-aib.md` + council FINAL `sessions/claude-20260531-2320.council-web-terminal.FINAL.md`). 2026-06-01.
> 방법: 실행 중 Claude Code 세션의 프로세스 트리 관찰. (정식 probe hook 등록은 생략 — 아래 한계 참조.)

## 관찰된 프로세스 트리

```
AI Barracks CommandCenter.app (ai-barracks-cc, pid 38857)
  └─ /bin/zsh (3969)
       └─ claude (pid 4334, comm=claude)        ← 이 세션의 agent 프로세스
            └─ /bin/zsh (24929, Bash 도구 셸)
                 └─ <명령>
```

## 해결된 결정 (이후 태스크가 전제하는 값)

1. **PID 소스 = `$PPID`에서 ancestor chain walk → comm이 client명 매칭하는 첫 프로세스 PID.**
   - hook은 claude의 자손으로 실행되며 `$PPID`가 임시 셸일 수 있으므로, 단순 `$PPID`가 아니라 **위로 walk하여 `claude` 프로세스를 찾는다.**
   - 못 찾으면 `$PPID`를 `confidence=low`로 기록 → low-confidence는 **보존 우선, 적극 dead 판단 제한**(council 결정 매트릭스).
   - 테스트 결정성: helper는 `AIB_LIVE_PID`/`AIB_LIVE_LSTART` 오버라이드를 우선 적용, 없을 때만 walk/`ps` 실측.

2. **claude CLI의 `comm` = `claude`** (node 아님). → walk 매칭 키 = client명(`claude`; codex/gemini는 각 comm). `node` 단독 매칭은 `confidence=low` 강등. (council 참고사항 #1 해소.)

3. **lstart (PID reuse 방어 — council 통합 추가, 플랜엔 없던 필드)**: `ps -o lstart= -p <pid>`로 프로세스 시작시각을 캡처해 sidecar `.status`에 저장. `cleanup_stale`/fold 판정 시 **저장값 vs 현재값 문자열 동일성** 비교(OS 포맷차 무관). 불일치 = PID 재사용 = `dead` 취급.

4. **Notification → blocked**: 채택. over-fire 가능성(council 우려)은 정식 실측을 Task 7 E2E로 이연. `cmd_hook_event`는 stdin payload를 받아두되 v1은 무조건 blocked 매핑, payload guard는 hook 포인트만 주석으로 남긴다.

## 한계 (정식 probe 미실행)

- 플랜 Task 1의 정식 probe hook(`~/.claude/settings.json` 등록 + 실제 세션 구동으로 각 이벤트의 `$PPID` 캡처)은 생략하고, 실행 중 세션의 `ps` 트리로 대체했다. `$PPID`의 정확한 hook 실행 컨텍스트(claude 직속 vs 셸 경유)는 **ancestor walk가 흡수**하므로 de-risk된다.
- 남은 미확인: `Notification`이 승인대기에만 발화하는지(over-fire). → Task 7 E2E에서 `aib sessions state` watch로 실측 확정.
