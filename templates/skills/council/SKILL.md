---
name: council
description: "Use when an architectural decision, technology comparison, critical code review, or any high-stakes choice would benefit from cross-validation by 3 independent LLMs (Claude/Gemini/Codex). Triggers a multi-round debate via the upstream `ai-barracks/scripts/council.sh` and returns a synthesized consensus. Modes: debate (default 2 rounds), adversarial (devil's advocate rotation), pipeline (Gemini plans → Claude implements → Codex reviews)."
argument-hint: "<topic> [-m debate|adversarial|pipeline] [-r rounds] [--consensus N]"
allowed-tools: Bash(./scripts/council.sh *), Bash(council.sh *), Read, Write
aib_version: "1.1"
upstream: "ai-barracks/scripts/council.sh"
growth_origin: "manual"
---

# LLM Council — 멀티라운드 교차 리뷰

3개 AI(Claude Opus, Gemini 2.5 Pro, Codex GPT-5.3)가 같은 주제를 두고 멀티라운드 디베이트한 뒤 합의안을 도출한다. ai-barracks v1.1 표준 스킬의 reference 구현 — Anthropic Agent Skills 호환 frontmatter + ai-barracks 확장 필드 사용.

## When to Invoke

- 아키텍처/기술 비교 결정 (예: REST vs gRPC, Kafka vs Pulsar)
- 단일 LLM이 놓칠 수 있는 critical code review
- 사용자가 "council 돌려봐", "여러 LLM 의견 들어보자" 요청 시
- ai-barracks 프로토콜·스펙 변경처럼 영향 범위가 큰 결정

## How to Run

스크립트는 upstream `ai-barracks/scripts/council.sh`에 있다. 배럭 컨텍스트에서 호출:

```bash
# 기본 debate (2라운드)
council.sh "REST vs gRPC for internal service mesh"

# adversarial (반대론자 순환, 3라운드)
council.sh -m adversarial -r 3 "Kafka vs Pulsar for event streaming"

# pipeline (역할 분담)
council.sh -m pipeline "ClickHouse 마이그레이션 전략"

# 합의도 임계값 + JSON 출력
council.sh --consensus 90 --json "ai-barracks v1.1 skills 스펙 검토"
```

인자가 없으면 사용자에게 토론 주제를 먼저 묻는다.

## Modes

| Mode | 동작 | When |
|------|------|------|
| `debate` (default) | 3개 LLM 병렬 → 교차 리뷰 → 합의 | 일반 결정 |
| `adversarial` | 매 라운드 반대론자 1명 지정·순환 | 그룹 사고 회피 필요 |
| `pipeline` | Gemini(plan) → Claude(impl) → Codex(review) | 역할 분담 명확한 작업 |

## Outputs

- `stdout`: 라운드별 응답 + 최종 합의안
- `--output FILE`: 마크다운으로 저장 (세션 로그 첨부 권장)
- `--json`: manifest + synthesis 구조화 출력 (자동화 파이프라인용)

## Constraints

- Claude/Gemini/Codex CLI가 모두 설치·인증되어 있어야 함
- 기본 타임아웃 300초 (대형 토픽은 `--timeout` 상향 필요)
- 멀티라운드는 토큰 비용이 크다 — 사소한 결정에는 사용 자제

## Why This Skill Exists in ai-barracks

ai-barracks 철학상 "성장하는 배럭"은 단일 모델 의견에 갇히지 않아야 한다. council은 배럭이 자기 고집(model bias)을 외부 시각으로 검증하는 메타 도구. RFC 0.1.0에서 council을 첫 reference skill로 채택한 이유: 도메인 중립적이고, 모든 배럭에서 재사용 가능하며, ai-barracks의 "다중 시각" 가치관과 정렬된다.

## See Also

- RFC: [wiki/topics/aib-v1.1-skills-rfc.md](../../wiki/topics/aib-v1.1-skills-rfc.md)
- Upstream: `ai-barracks/scripts/council.sh`
- 표준: [Anthropic Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills)
