#!/usr/bin/env bash
#
# council.sh v2 - LLM Council: 멀티라운드 디베이트 시스템
#
# 3개 AI CLI(Claude Code, Gemini CLI, Codex CLI)를 병렬 실행하여
# 멀티라운드 교차 리뷰 후 최종 합의안을 도출합니다.
#
# 사용법:
#   council.sh [옵션] "토론 주제"
#   echo "토론 주제" | council.sh [옵션]
#
# 옵션:
#   -r, --rounds N          토론 라운드 수 (기본: 2)
#   -m, --mode MODE         토론 모드: debate|adversarial|pipeline (기본: debate)
#   -o, --output FILE       결과 저장 파일
#   -v, --verbose           각 라운드 상세 출력
#   --json                  JSON 형식 출력 (manifest + synthesis)
#   --consensus N           합의도 임계값 0-100, 0=비활성 (기본: 85)
#   --resume SESSION_ID     중단된 세션 재개
#   --no-claude             Claude 제외
#   --no-gemini             Gemini 제외
#   --no-codex              Codex 제외
#   --timeout SECONDS       전체 CLI 타임아웃 (기본: 300)
#   --timeout-claude N      Claude 전용 타임아웃
#   --timeout-gemini N      Gemini 전용 타임아웃
#   --timeout-codex N       Codex 전용 타임아웃
#   --grace SECONDS         선착 에이전트 이후 유예 시간 (기본: 90, 0=비활성)
#   --clean                 세션 디렉토리 전체 삭제
#   --clean-older-than N    N일 이상 세션 삭제
#   -h, --help              도움말

set -euo pipefail

# ── 기본값 ──────────────────────────────────────────────
ROUNDS=2
MODE="debate"
OUTPUT_FILE=""
VERBOSE=false
JSON_OUTPUT=false
CONSENSUS_THRESHOLD=85
RESUME_SESSION=""
USE_CLAUDE=true
USE_GEMINI=true
USE_CODEX=true
TIMEOUT=300
TIMEOUT_CLAUDE=""
TIMEOUT_GEMINI=""
TIMEOUT_CODEX=""
GRACE_PERIOD=0
DISABLED_AGENTS=()

# Claude Code 내부 실행 감지: claude -p 중첩 호출 불가
if [[ "${CLAUDECODE:-0}" == "1" ]]; then
    USE_CLAUDE=false
    INSIDE_CLAUDE_CODE=true
else
    INSIDE_CLAUDE_CODE=false
fi

# 모델 설정
CLAUDE_MODEL="claude-opus-4-6"
GEMINI_MODEL="gemini-3.1-pro-preview"
CODEX_PROFILE="council"

# 색상 — stdout이 TTY가 아니면 비활성화 (Slack 등 파이프 환경)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── 유틸리티 함수 ──────────────────────────────────────
log_info()  { echo -e "${BLUE}[Council]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[Council]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[Council]${NC} $*" >&2; }
log_error() { echo -e "${RED}[Council]${NC} $*" >&2; }

label_claude() { echo -e "${PURPLE}[Claude/Opus-4.6]${NC}"; }
label_gemini() { echo -e "${CYAN}[Gemini/3.1-Pro-Preview]${NC}"; }
label_codex()  { echo -e "${GREEN}[Codex/GPT-5.4]${NC}"; }

agent_label() {
    case "$1" in
        claude) echo "Claude/Opus-4.6" ;;
        gemini) echo "Gemini/3.1-Pro-Preview" ;;
        codex)  echo "Codex/GPT-5.4" ;;
    esac
}

agent_timeout() {
    case "$1" in
        claude) echo "${TIMEOUT_CLAUDE:-$TIMEOUT}" ;;
        gemini) echo "${TIMEOUT_GEMINI:-$TIMEOUT}" ;;
        codex)  echo "${TIMEOUT_CODEX:-$TIMEOUT}" ;;
    esac
}

# ── 토큰 & 한도 모니터링 ─────────────────────────────

get_claude_quota() {
    # statusline.sh와 동일한 방식: macOS keychain에서 OAuth 토큰 추출
    local token
    token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null) || true
    [[ -z "$token" ]] && return 1

    local resp
    resp=$(curl -s --max-time 5 "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null) || true
    [[ -z "$resp" ]] && return 1

    local h5 d7
    h5=$(echo "$resp" | jq -r '.five_hour.utilization // empty' 2>/dev/null)
    d7=$(echo "$resp" | jq -r '.seven_day.utilization // empty' 2>/dev/null)

    if [[ -n "$h5" ]]; then
        echo "5h: ${h5%.*}%, 7d: ${d7%.*}%"
        # JSON으로도 저장 (리포트용)
        echo "$resp" | jq '{
            five_hour_pct: (.five_hour.utilization | floor),
            seven_day_pct: (.seven_day.utilization | floor)
        }' > "${SESSION_DIR}/claude_quota.json" 2>/dev/null || true
    else
        return 1
    fi
}

extract_gemini_tokens() {
    local raw_json="$1"
    local token_file="$2"
    [[ ! -s "$raw_json" ]] && { echo '{}' > "$token_file"; return; }

    jq '{
        input: (.stats.models | to_entries[0].value.tokens.input // 0),
        output: (.stats.models | to_entries[0].value.tokens.candidates // 0),
        cached: (.stats.models | to_entries[0].value.tokens.cached // 0),
        thoughts: (.stats.models | to_entries[0].value.tokens.thoughts // 0),
        total: (.stats.models | to_entries[0].value.tokens.total // 0)
    }' "$raw_json" > "$token_file" 2>/dev/null || echo '{}' > "$token_file"
}

extract_codex_tokens() {
    local session_before="$1"
    local token_file="$2"

    local session_after
    session_after=$(ls -t ~/.codex/sessions/2026/*/*/rollout-*.jsonl 2>/dev/null | head -1) || true

    if [[ -n "$session_after" && "$session_before" != "$session_after" && -f "$session_after" ]]; then
        grep '"token_count"' "$session_after" 2>/dev/null | tail -1 | \
            jq '.payload.info.total_token_usage // {}' > "$token_file" 2>/dev/null || echo '{}' > "$token_file"
    fi
    [[ ! -s "$token_file" ]] && echo '{}' > "$token_file"
}

print_token_summary() {
    local round=$1
    local has_tokens=false

    # Gemini / Codex: 라운드 사용량
    for agent in gemini codex; do
        local token_file="${SESSION_DIR}/r${round}_${agent}.md.tokens.json"
        [[ ! -s "$token_file" ]] && continue
        local total
        total=$(jq -r '.total // .total_tokens // 0' "$token_file" 2>/dev/null) || true
        [[ "$total" == "0" || "$total" == "null" || -z "$total" ]] && continue

        has_tokens=true
        local input output cached
        input=$(jq -r '.input // .input_tokens // 0' "$token_file" 2>/dev/null)
        output=$(jq -r '.output // .output_tokens // 0' "$token_file" 2>/dev/null)
        cached=$(jq -r '.cached // .cached_input_tokens // 0' "$token_file" 2>/dev/null)

        log_info "  ${DIM}[Token]${NC} $(agent_label "$agent"): 입력 ${input} / 출력 ${output} / 캐시 ${cached} / 합계 ${total}"
    done

    # Claude: 남은 한도 (5h/7d 사용률)
    if $USE_CLAUDE || $INSIDE_CLAUDE_CODE; then
        local quota
        quota=$(get_claude_quota 2>/dev/null) || true
        if [[ -n "$quota" ]]; then
            has_tokens=true
            log_info "  ${DIM}[Quota]${NC} Claude: ${quota}"
        fi
    fi

    $has_tokens || return 0
}

usage() {
    cat <<'USAGE'
LLM Council v2 - 멀티라운드 디베이트 시스템

사용법:
  council.sh [옵션] "토론 주제"
  echo "토론 주제" | council.sh [옵션]

모드:
  debate (기본)    자유 토론 + 교차 리뷰 (창의적 발상 + 체계적 검토)
  adversarial      매 라운드 1명이 반대론자(Devil's Advocate) 역할
  pipeline         역할 고정 순차 실행 (Gemini 계획 → Claude 구현 → Codex 리뷰)

옵션:
  -r, --rounds N          토론 라운드 수 (기본: 2)
  -m, --mode MODE         토론 모드 (기본: debate)
  -o, --output FILE       결과 저장 파일
  -v, --verbose           각 라운드 상세 출력
  --json                  JSON 형식 출력
  --consensus N           합의도 임계값 (기본: 85, 0=비활성)
  --resume SESSION_ID     중단된 세션 재개
  --no-claude             Claude 제외
  --no-gemini             Gemini 제외
  --no-codex              Codex 제외
  --timeout SECONDS       전체 CLI 타임아웃 (기본: 300)
  --timeout-claude N      Claude 전용 타임아웃
  --timeout-gemini N      Gemini 전용 타임아웃
  --timeout-codex N       Codex 전용 타임아웃
  --grace SECONDS         선착 에이전트 이후 유예 시간 (기본: 90, 0=비활성)
  --clean                 세션 디렉토리 전체 삭제
  --clean-older-than N    N일 이상 세션 삭제
  -h, --help              도움말

예시:
  council.sh "ClickHouse 콜드 데이터: Parquet vs S3 티어링 비교"
  council.sh -r 3 -v "마이크로서비스 vs 모놀리스 아키텍처"
  council.sh -m adversarial -r 3 "Kafka vs Pulsar 비교"
  council.sh -m pipeline "ClickHouse 마이그레이션 전략"
  council.sh --json -r 2 -o result.json "REST vs gRPC"
  council.sh --resume 20260210_143022_12345
  council.sh --clean
USAGE
}

# ── 인자 파싱 ──────────────────────────────────────────
PROMPT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--rounds)         ROUNDS="$2"; shift 2 ;;
        -m|--mode)           MODE="$2"; shift 2 ;;
        -o|--output)         OUTPUT_FILE="$2"; shift 2 ;;
        -v|--verbose)        VERBOSE=true; shift ;;
        --json)              JSON_OUTPUT=true; shift ;;
        --consensus)         CONSENSUS_THRESHOLD="$2"; shift 2 ;;
        --resume)            RESUME_SESSION="$2"; shift 2 ;;
        --no-claude)         USE_CLAUDE=false; shift ;;
        --no-gemini)         USE_GEMINI=false; shift ;;
        --no-codex)          USE_CODEX=false; shift ;;
        --timeout)           TIMEOUT="$2"; shift 2 ;;
        --timeout-claude)    TIMEOUT_CLAUDE="$2"; shift 2 ;;
        --timeout-gemini)    TIMEOUT_GEMINI="$2"; shift 2 ;;
        --timeout-codex)     TIMEOUT_CODEX="$2"; shift 2 ;;
        --grace)             GRACE_PERIOD="$2"; shift 2 ;;
        --clean)
            log_info "세션 디렉토리 정리 중..."
            if [[ -d /tmp/council ]]; then
                count=$(find /tmp/council -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
                rm -rf /tmp/council/*
                log_ok "${count}개 세션 삭제 완료"
            else
                log_info "정리할 세션이 없습니다"
            fi
            exit 0
            ;;
        --clean-older-than)
            days="$2"; shift 2
            find /tmp/council -maxdepth 1 -mindepth 1 -type d -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
            log_ok "${days}일 이상 된 세션 정리 완료"
            exit 0
            ;;
        -h|--help)           usage; exit 0 ;;
        -*)                  log_error "알 수 없는 옵션: $1"; usage; exit 1 ;;
        *)                   PROMPT="$*"; break ;;
    esac
done

# 모드 검증
case "$MODE" in
    debate|adversarial|pipeline) ;;
    *) log_error "알 수 없는 모드: $MODE (사용 가능: debate, adversarial, pipeline)"; exit 1 ;;
esac

# jq 의존성 확인
if ! command -v jq &>/dev/null; then
    log_error "jq가 필요합니다. 설치: brew install jq"
    exit 1
fi

# ── 세션 재개 ──────────────────────────────────────────

resume_session() {
    local sid="$1"
    SESSION_DIR="/tmp/council/${sid}"
    SESSION_ID="$sid"

    if [[ ! -f "${SESSION_DIR}/manifest.json" ]]; then
        log_error "세션 매니페스트를 찾을 수 없습니다: ${SESSION_DIR}/manifest.json"
        exit 4
    fi

    PROMPT=$(jq -r '.prompt' "${SESSION_DIR}/manifest.json")
    ROUNDS=$(jq -r '.config.rounds' "${SESSION_DIR}/manifest.json")
    MODE=$(jq -r '.mode' "${SESSION_DIR}/manifest.json")
    TIMEOUT=$(jq -r '.config.timeout' "${SESSION_DIR}/manifest.json")
    USE_CLAUDE=$(jq -r '.config.agents.claude.enabled' "${SESSION_DIR}/manifest.json")
    USE_GEMINI=$(jq -r '.config.agents.gemini.enabled' "${SESSION_DIR}/manifest.json")
    USE_CODEX=$(jq -r '.config.agents.codex.enabled' "${SESSION_DIR}/manifest.json")

    local completed_round
    completed_round=$(jq -r '.current_round' "${SESSION_DIR}/manifest.json")
    RESUME_FROM_ROUND=$((completed_round + 1))

    log_info "세션 복원: ${SESSION_ID}"
    log_info "완료된 라운드: ${completed_round}/${ROUNDS}, 라운드 ${RESUME_FROM_ROUND}부터 재개"
}

if [[ -n "$RESUME_SESSION" ]]; then
    resume_session "$RESUME_SESSION"
else
    # stdin에서 프롬프트 읽기 (인자가 없을 때)
    if [[ -z "$PROMPT" ]]; then
        if [[ ! -t 0 ]]; then
            PROMPT=$(cat)
        else
            log_error "토론 주제를 입력하세요."
            usage
            exit 1
        fi
    fi
fi

# 활성 에이전트 수 확인
ACTIVE_COUNT=0
$USE_CLAUDE && ((ACTIVE_COUNT++)) || true
$USE_GEMINI && ((ACTIVE_COUNT++)) || true
$USE_CODEX  && ((ACTIVE_COUNT++)) || true

if [[ "$MODE" == "pipeline" ]]; then
    # pipeline 모드는 최소 2개 필요
    if [[ $ACTIVE_COUNT -lt 2 ]]; then
        log_error "pipeline 모드는 최소 2개 이상의 에이전트가 필요합니다."
        exit 1
    fi
elif [[ $ACTIVE_COUNT -lt 2 ]]; then
    log_error "최소 2개 이상의 에이전트가 필요합니다."
    exit 1
fi

# ── 세션 디렉토리 ──────────────────────────────────────
if [[ -z "$RESUME_SESSION" ]]; then
    SESSION_ID=$(date +%Y%m%d_%H%M%S)_$$
    SESSION_DIR="/tmp/council/${SESSION_ID}"
    mkdir -p "$SESSION_DIR"
fi
log_info "세션: ${SESSION_DIR}"

# ── JSON 매니페스트 ────────────────────────────────────

init_manifest() {
    local manifest="${SESSION_DIR}/manifest.json"
    jq -n \
        --arg sid "$SESSION_ID" \
        --arg prompt "$PROMPT" \
        --arg mode "$MODE" \
        --argjson rounds "$ROUNDS" \
        --argjson timeout "$TIMEOUT" \
        --argjson consensus "$CONSENSUS_THRESHOLD" \
        --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson use_claude "$( $USE_CLAUDE && echo true || echo false )" \
        --argjson use_gemini "$( $USE_GEMINI && echo true || echo false )" \
        --argjson use_codex "$( $USE_CODEX && echo true || echo false )" \
        '{
            version: "2.0",
            session_id: $sid,
            prompt: $prompt,
            mode: $mode,
            config: {
                rounds: $rounds,
                timeout: $timeout,
                consensus_threshold: $consensus,
                agents: {
                    claude: { enabled: $use_claude, model: "opus" },
                    gemini: { enabled: $use_gemini, model: "gemini-3.1-pro-preview" },
                    codex:  { enabled: $use_codex, model: "gpt-5.4" }
                }
            },
            started_at: $started,
            completed_at: null,
            status: "running",
            current_round: 0,
            rounds_data: [],
            consensus_history: [],
            final_synthesis: null
        }' > "$manifest"
}

update_manifest_round() {
    local round=$1
    local agent=$2
    local status=$3
    local duration=$4
    local word_count=$5
    local manifest="${SESSION_DIR}/manifest.json"
    [[ ! -f "$manifest" ]] && return

    # 토큰 데이터 로드 (있으면)
    local token_json='{}'
    local token_file="${SESSION_DIR}/r${round}_${agent}.md.tokens.json"
    if [[ -s "$token_file" ]]; then
        local check
        check=$(jq -r '.total // .total_tokens // 0' "$token_file" 2>/dev/null) || true
        if [[ -n "$check" && "$check" != "0" && "$check" != "null" ]]; then
            token_json=$(cat "$token_file")
        fi
    fi

    local tmp="${manifest}.tmp"
    jq --argjson r "$round" \
       --arg agent "$agent" \
       --arg status "$status" \
       --argjson dur "$duration" \
       --argjson wc "$word_count" \
       --argjson tokens "$token_json" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '
       .rounds_data |= (
           if length < $r then
               . + [range(length; $r) | { round: (. + 1), agents: {} }]
           else . end
       ) |
       .rounds_data[$r - 1].agents[$agent] = {
           status: $status,
           duration_s: $dur,
           word_count: $wc,
           tokens: $tokens,
           timestamp: $ts
       } |
       .current_round = $r
       ' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

update_manifest_consensus() {
    local round=$1
    local score=$2
    local reason="$3"
    local manifest="${SESSION_DIR}/manifest.json"
    [[ ! -f "$manifest" ]] && return

    local tmp="${manifest}.tmp"
    jq --argjson r "$round" \
       --argjson s "$score" \
       --arg reason "$reason" \
       '.consensus_history += [{ round: $r, score: $s, reason: $reason }]' \
       "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

finalize_manifest() {
    local status="${1:-completed}"
    local manifest="${SESSION_DIR}/manifest.json"
    [[ ! -f "$manifest" ]] && return

    local tmp="${manifest}.tmp"
    jq --arg s "$status" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.status = $s | .completed_at = $ts' \
       "$manifest" > "$tmp" && mv "$tmp" "$manifest"
}

# ── CLI 호출 함수 ──────────────────────────────────────

call_claude() {
    local prompt="$1"
    local outfile="$2"
    local tout
    tout=$(agent_timeout claude)
    local start_time=$SECONDS
    local stderr_file="${outfile}.stderr"
    local killed_marker="${outfile}.killed"
    rm -f "$killed_marker"

    claude -p "$prompt" --model "$CLAUDE_MODEL" --output-format text --no-session-persistence --permission-mode bypassPermissions > "$outfile" 2>"$stderr_file" &
    local cmd_pid=$!
    ( sleep "$tout" && touch "$killed_marker" && kill "$cmd_pid" 2>/dev/null ) &
    local watchdog_pid=$!

    local exit_code=0
    wait "$cmd_pid" 2>/dev/null || exit_code=$?
    kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null || true

    local duration=$(( SECONDS - start_time ))
    echo "$duration" > "${outfile}.meta"

    if [[ -s "$outfile" ]]; then
        rm -f "$stderr_file" "$killed_marker"
        return 0
    else
        local error_detail
        if [[ -f "$killed_marker" ]]; then
            error_detail="timeout=${tout}s"
        elif [[ -s "$stderr_file" ]]; then
            error_detail=$(head -1 "$stderr_file")
        else
            error_detail="exit=${exit_code}, ${duration}s"
        fi
        echo "[오류: Claude 호출 실패 (${error_detail})]" > "$outfile"
        rm -f "$killed_marker"
        return 1
    fi
}

call_gemini() {
    local prompt="$1"
    local outfile="$2"
    local tout
    tout=$(agent_timeout gemini)
    local start_time=$SECONDS
    local stderr_file="${outfile}.stderr"
    local killed_marker="${outfile}.killed"
    rm -f "$killed_marker"

    # JSON 출력으로 받아서 본문/토큰 분리
    local raw_json="${outfile}.raw.json"
    gemini -p "$prompt" -m "$GEMINI_MODEL" -o json --yolo > "$raw_json" 2>"$stderr_file" &
    local cmd_pid=$!
    ( sleep "$tout" && touch "$killed_marker" && kill "$cmd_pid" 2>/dev/null ) &
    local watchdog_pid=$!

    local exit_code=0
    wait "$cmd_pid" 2>/dev/null || exit_code=$?
    kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null || true

    local duration=$(( SECONDS - start_time ))
    echo "$duration" > "${outfile}.meta"

    if [[ -s "$raw_json" ]]; then
        # 본문 추출 (JSON → 텍스트)
        jq -r '.response // .candidates[0].content // .' "$raw_json" > "$outfile" 2>/dev/null \
            || cp "$raw_json" "$outfile"
        # 토큰 추출
        extract_gemini_tokens "$raw_json" "${outfile}.tokens.json"
        rm -f "$stderr_file" "$killed_marker"
        return 0
    else
        local error_detail
        if [[ -f "$killed_marker" ]]; then
            error_detail="timeout=${tout}s"
        elif [[ -s "$stderr_file" ]]; then
            error_detail=$(head -1 "$stderr_file")
        else
            error_detail="exit=${exit_code}, ${duration}s"
        fi
        echo "[오류: Gemini 호출 실패 (${error_detail})]" > "$outfile"
        echo '{}' > "${outfile}.tokens.json"
        rm -f "$killed_marker"
        return 1
    fi
}

call_codex() {
    local prompt="$1"
    local outfile="$2"
    local tout
    tout=$(agent_timeout codex)
    local start_time=$SECONDS
    local stderr_file="${outfile}.stderr"
    local killed_marker="${outfile}.killed"
    rm -f "$killed_marker"

    # 실행 전 최신 세션 파일 기록 (토큰 추출용)
    local session_before
    session_before=$(ls -t ~/.codex/sessions/2026/*/*/rollout-*.jsonl 2>/dev/null | head -1) || true

    codex exec --profile "$CODEX_PROFILE" --dangerously-bypass-approvals-and-sandbox -C /tmp --skip-git-repo-check --ephemeral "$prompt" > "$outfile" 2>"$stderr_file" &
    local cmd_pid=$!
    ( sleep "$tout" && touch "$killed_marker" && kill "$cmd_pid" 2>/dev/null ) &
    local watchdog_pid=$!

    local exit_code=0
    wait "$cmd_pid" 2>/dev/null || exit_code=$?
    kill "$watchdog_pid" 2>/dev/null; wait "$watchdog_pid" 2>/dev/null || true

    local duration=$(( SECONDS - start_time ))
    echo "$duration" > "${outfile}.meta"

    if [[ -s "$outfile" ]]; then
        # 세션 파일에서 토큰 추출
        extract_codex_tokens "$session_before" "${outfile}.tokens.json"
        rm -f "$stderr_file" "$killed_marker"
        return 0
    else
        local error_detail
        if [[ -f "$killed_marker" ]]; then
            error_detail="timeout=${tout}s"
        elif [[ -s "$stderr_file" ]]; then
            error_detail=$(head -1 "$stderr_file")
        else
            error_detail="exit=${exit_code}, ${duration}s"
        fi
        echo "[오류: Codex 호출 실패 (${error_detail})]" > "$outfile"
        echo '{}' > "${outfile}.tokens.json"
        rm -f "$killed_marker"
        return 1
    fi
}

# ── 품질 검증 & 재시도 ────────────────────────────────

validate_response() {
    local outfile="$1"
    local min_words=20

    [[ ! -s "$outfile" ]] && return 1
    grep -q "^\[오류:" "$outfile" && return 1

    local wc
    wc=$(wc -w < "$outfile" | tr -d ' ')
    [[ $wc -lt $min_words ]] && return 1

    return 0
}

call_agent_with_retry() {
    local agent="$1"
    local prompt="$2"
    local outfile="$3"
    local max_retries=4
    local attempt=0
    local call_fn="call_${agent}"
    local base_delay=30  # 30초 기본 대기

    while [[ $attempt -le $max_retries ]]; do
        if [[ $attempt -gt 0 ]]; then
            local wait_time=$(( base_delay * attempt ))
            # 최대 300초(5분) 캡
            [[ $wait_time -gt 300 ]] && wait_time=300
            log_warn "  ${agent} 재시도 (${attempt}/${max_retries}) - ${wait_time}초 대기..."
            sleep $wait_time
        fi

        if $call_fn "$prompt" "$outfile" && validate_response "$outfile"; then
            return 0
        fi
        ((attempt++))
    done

    log_error "  ${agent} 최종 실패 (재시도 ${max_retries}회 소진)"
    return 1
}

# ── 프롬프트 생성 함수 ────────────────────────────────

build_round1_prompt() {
    local agent_name="$1"
    cat <<EOF
당신은 ${agent_name} 전문가입니다. 다음 주제에 대해 자유롭게 깊이 있는 분석을 제공하세요.

형식에 구애받지 말고, 핵심 결론과 그 근거, 리스크, 대안이나 새로운 관점을 자연스럽게 포함하세요.
창의적이고 예상치 못한 관점도 환영합니다.

## 주제
${PROMPT}
EOF
}

build_review_prompt() {
    local agent_name="$1"
    local round_num="$2"
    local all_history="$3"

    cat <<EOF
당신은 ${agent_name} 전문가입니다. 라운드 ${round_num} 교차 리뷰입니다.

지금까지의 전체 토론 히스토리를 검토하고, 당신의 입장을 수정하거나 보강하세요.

## 가이드 (참고, 강제 아님)
- 동의하면 추가 근거로 보강
- 반박하면 구체적 반증 제시
- 이전 입장을 수정할 경우, 어떤 라운드의 어떤 의견에 영향 받았는지 명시
- 새로운 관점이 있으면 자유롭게 추가
- 각 전문가 의견의 약점이나 보완점도 지적

## 전체 토론 히스토리
${all_history}

## 원래 주제
${PROMPT}
EOF
}

build_adversarial_prompt() {
    local agent_name="$1"
    local round_num="$2"
    local all_history="$3"

    cat <<EOF
당신은 ${agent_name}이며, 이 라운드에서 **반대론자(Devil's Advocate)** 역할입니다.

다른 전문가들의 의견에서 약점, 논리적 결함, 숨겨진 가정, 간과된 리스크를 찾아내세요.
긍정적인 면을 인정하되, 주된 임무는 비판적 검토입니다.

## 전체 토론 히스토리
${all_history}

## 원래 주제
${PROMPT}

## 응답 가이드
1. **가장 큰 약점** — 논리적 결함 또는 간과된 리스크
2. **숨겨진 가정** — 검증되지 않은 전제
3. **반론** — 대안적 관점에서의 구체적 반증
4. **그럼에도 동의하는 부분** (있다면)
EOF
}

build_pipeline_prompt() {
    local stage="$1"
    local context="$2"

    case "$stage" in
        plan)
            cat <<EOF
다음 주제에 대한 실행 계획을 수립하세요. 단계별로 상세히 작성하세요.
목표, 접근 방법, 예상 리스크, 성공 기준을 포함하세요.

## 주제
${PROMPT}
EOF
            ;;
        implement)
            cat <<EOF
다음 계획을 기반으로 구체적인 구현안/상세 내용을 작성하세요.
계획의 각 단계를 실행 가능한 수준으로 구체화하세요.

## 계획
${context}

## 원래 주제
${PROMPT}
EOF
            ;;
        review)
            cat <<EOF
다음 계획과 구현안을 비판적으로 리뷰하세요.
빠진 부분, 리스크, 개선점, 실현 가능성을 평가하세요.

## 이전 단계 결과
${context}

## 원래 주제
${PROMPT}
EOF
            ;;
    esac
}

build_synthesis_prompt() {
    local all_rounds="$1"
    local agent_count=$ACTIVE_COUNT
    local agent_names=""
    $USE_CLAUDE && agent_names+="Claude/Opus-4.6, "
    $USE_GEMINI && agent_names+="Gemini/3.1-Pro-Preview, "
    $USE_CODEX && agent_names+="Codex/GPT-5.4, "
    agent_names="${agent_names%, }"

    cat <<EOF
${agent_count}명의 전문가(${agent_names})가 ${ROUNDS} 라운드에 걸쳐 토론했습니다.
모든 라운드의 논의를 종합하여 최종 합의안을 작성하세요.

## 응답 형식
1. **합의된 사항** — 모두 (또는 다수가) 동의한 결론
2. **미합의 쟁점** — 의견이 갈린 부분과 각 입장 요약
3. **최종 권고안** — 종합적 판단과 구체적 실행 방안
4. **참고사항** — 추가 조사가 필요한 영역

## 전체 토론 내역
${all_rounds}

## 원래 주제
${PROMPT}
EOF
}

# ── 라운드별 의견 수집 ────────────────────────────────

collect_previous_opinions() {
    local round=$1
    local opinions=""

    if $USE_CLAUDE && [[ -f "${SESSION_DIR}/r${round}_claude.md" ]] && validate_response "${SESSION_DIR}/r${round}_claude.md"; then
        opinions+="
### 전문가 A — Claude/Opus-4.6
$(cat "${SESSION_DIR}/r${round}_claude.md")
"
    fi
    if $USE_GEMINI && [[ -f "${SESSION_DIR}/r${round}_gemini.md" ]] && validate_response "${SESSION_DIR}/r${round}_gemini.md"; then
        opinions+="
### 전문가 B — Gemini/3.1-Pro-Preview
$(cat "${SESSION_DIR}/r${round}_gemini.md")
"
    fi
    if $USE_CODEX && [[ -f "${SESSION_DIR}/r${round}_codex.md" ]] && validate_response "${SESSION_DIR}/r${round}_codex.md"; then
        opinions+="
### 전문가 C — Codex/GPT-5.4
$(cat "${SESSION_DIR}/r${round}_codex.md")
"
    fi

    # pipeline 모드 파일도 수집
    for stage in plan implement review; do
        if [[ -f "${SESSION_DIR}/r${round}_pipeline_${stage}.md" ]]; then
            opinions+="
### Pipeline: ${stage}
$(cat "${SESSION_DIR}/r${round}_pipeline_${stage}.md")
"
        fi
    done

    echo "$opinions"
}

collect_all_history() {
    local up_to_round=$1
    local history=""

    for ((r = 1; r <= up_to_round; r++)); do
        history+="
## 라운드 ${r}
$(collect_previous_opinions "$r")
"
    done
    echo "$history"
}

# ── 합의도 점수 ───────────────────────────────────────

score_consensus() {
    local round=$1
    local opinions
    opinions=$(collect_previous_opinions "$round")

    local scoring_prompt
    scoring_prompt=$(cat <<EOF
아래 전문가들의 의견을 읽고, 합의 정도를 0~100 점으로 평가하세요.
- 0: 완전히 다른 결론, 양립 불가
- 50: 부분 동의, 핵심 쟁점 남음
- 85+: 실질적 합의, 미세 차이만 존재
- 100: 완전 합의

반드시 아래 JSON 형식으로만 응답하세요 (다른 텍스트 없이):
{"score": <0-100>, "reason": "<한 줄 요약>"}

## 전문가 의견
${opinions}
EOF
)

    local score_file="${SESSION_DIR}/r${round}_consensus.json"

    # 가장 빠른 에이전트로 점수 평가
    if $USE_GEMINI; then
        call_gemini "$scoring_prompt" "$score_file" 2>/dev/null || true
    elif ! $INSIDE_CLAUDE_CODE && $USE_CLAUDE; then
        call_claude "$scoring_prompt" "$score_file" 2>/dev/null || true
    elif $USE_CODEX; then
        call_codex "$scoring_prompt" "$score_file" 2>/dev/null || true
    else
        echo '{"score": 0, "reason": "scoring unavailable"}' > "$score_file"
        echo "0"
        return
    fi

    # JSON에서 점수 추출 (응답에 markdown이 섞여 있을 수 있음)
    local score=0
    local reason="parse error"
    if [[ -s "$score_file" ]]; then
        # JSON 블록 추출 시도
        local json_content
        json_content=$(grep -o '{[^}]*}' "$score_file" | head -1 || true)
        if [[ -n "$json_content" ]]; then
            score=$(echo "$json_content" | jq -r '.score // 0' 2>/dev/null || echo "0")
            reason=$(echo "$json_content" | jq -r '.reason // "parse error"' 2>/dev/null || echo "parse error")
        fi
    fi

    update_manifest_consensus "$round" "$score" "$reason"
    log_info "  합의도: ${score}/100 — ${reason}"
    echo "$score"
}

# ── 라운드 실행 ───────────────────────────────────────

run_parallel_round() {
    local round=$1
    local prompt_type=$2  # "round1", "review", or "adversarial"
    local devil_agent="${3:-}"
    local pids=()
    local agents=()

    local all_history=""
    if [[ "$prompt_type" != "round1" ]]; then
        all_history=$(collect_all_history "$((round - 1))")
    fi

    # 에이전트별 프롬프트 생성 및 병렬 호출
    for agent in claude gemini codex; do
        local use_var="USE_$(echo "$agent" | tr '[:lower:]' '[:upper:]')"
        if ! ${!use_var}; then
            continue
        fi

        # 이전 라운드에서 실패한 에이전트 건너뛰기
        if [[ " ${DISABLED_AGENTS[*]:-} " =~ " ${agent} " ]]; then
            log_warn "  ${agent} 비활성 (이전 라운드 실패) — 건너뜀"
            continue
        fi

        local prompt=""
        local outfile="${SESSION_DIR}/r${round}_${agent}.md"
        local label
        label=$(agent_label "$agent")

        case "$prompt_type" in
            round1)
                prompt=$(build_round1_prompt "$label")
                ;;
            review)
                prompt=$(build_review_prompt "$label" "$round" "$all_history")
                ;;
            adversarial)
                if [[ "$agent" == "$devil_agent" ]]; then
                    prompt=$(build_adversarial_prompt "$label" "$round" "$all_history")
                else
                    prompt=$(build_review_prompt "$label" "$round" "$all_history")
                fi
                ;;
        esac

        call_agent_with_retry "$agent" "$prompt" "$outfile" &
        pids+=($!)
        agents+=("$agent")
    done

    # 병렬 대기: polling loop + grace period
    local first_done=false
    local grace_deadline=0
    local pid_status=()  # "running", "done", "killed"
    for i in "${!pids[@]}"; do
        pid_status[$i]="running"
    done

    while true; do
        local alive=0
        for i in "${!pids[@]}"; do
            [[ "${pid_status[$i]}" != "running" ]] && continue
            if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                pid_status[$i]="done"
                # 선착 에이전트 감지
                if ! $first_done && [[ $GRACE_PERIOD -gt 0 ]]; then
                    local outfile="${SESSION_DIR}/r${round}_${agents[$i]}.md"
                    if validate_response "$outfile" 2>/dev/null; then
                        first_done=true
                        grace_deadline=$((SECONDS + GRACE_PERIOD))
                        log_info "  ${agents[$i]} 선착 완료 — 나머지 ${GRACE_PERIOD}초 유예"
                    fi
                fi
                continue
            fi
            ((alive++))
        done

        [[ $alive -eq 0 ]] && break

        # 유예 시간 초과 — 남은 에이전트 강제 종료
        if $first_done && [[ $SECONDS -ge $grace_deadline ]]; then
            for i in "${!pids[@]}"; do
                [[ "${pid_status[$i]}" != "running" ]] && continue
                log_warn "  ${agents[$i]} 유예 시간 초과 (${GRACE_PERIOD}s) — 강제 종료"
                kill "${pids[$i]}" 2>/dev/null || true
                pkill -P "${pids[$i]}" 2>/dev/null || true
                pid_status[$i]="killed"
            done
            sleep 2
            break
        fi

        sleep 1
    done

    # 결과 수집
    local success=0
    local fail=0
    for i in "${!pids[@]}"; do
        local agent="${agents[$i]}"
        local outfile="${SESSION_DIR}/r${round}_${agent}.md"

        # killed 상태인 경우 프로세스 정리 대기
        if [[ "${pid_status[$i]}" == "killed" ]]; then
            wait "${pids[$i]}" 2>/dev/null || true
        fi

        if validate_response "$outfile" 2>/dev/null; then
            local duration=0
            local word_count=0
            [[ -f "${outfile}.meta" ]] && duration=$(cat "${outfile}.meta" | tr -d ' ')
            [[ -s "$outfile" ]] && word_count=$(wc -w < "$outfile" | tr -d ' ')

            local status_label="success"
            [[ "${pid_status[$i]}" == "killed" ]] && status_label="partial"
            log_ok "  ${agent} 완료 (${duration}s, ${word_count}단어${status_label:+, ${status_label}})"
            update_manifest_round "$round" "$agent" "$status_label" "$duration" "$word_count"
            ((success++))
        else
            local duration=0
            [[ -f "${outfile}.meta" ]] && duration=$(cat "${outfile}.meta" | tr -d ' ')

            local fail_reason="failed"
            [[ "${pid_status[$i]}" == "killed" ]] && fail_reason="grace_timeout"
            log_warn "  ${agent} 실패 (${duration}s, ${fail_reason})"
            update_manifest_round "$round" "$agent" "$fail_reason" "$duration" "0"
            DISABLED_AGENTS+=("$agent")
            ((fail++))
        fi
    done

    log_info "  결과: ${success} 성공, ${fail} 실패"
    print_token_summary "$round"

    if [[ $success -lt 1 ]]; then
        log_error "모든 에이전트가 실패했습니다."
        finalize_manifest "all_agents_failed"
        exit 2
    fi

    return 0
}

print_round_results() {
    local round=$1
    echo ""
    echo -e "${BOLD}━━━ 라운드 ${round} 결과 ━━━${NC}"

    if $USE_CLAUDE && [[ -f "${SESSION_DIR}/r${round}_claude.md" ]]; then
        echo ""
        echo -e "$(label_claude)"
        cat "${SESSION_DIR}/r${round}_claude.md"
    fi
    if $USE_GEMINI && [[ -f "${SESSION_DIR}/r${round}_gemini.md" ]]; then
        echo ""
        echo -e "$(label_gemini)"
        cat "${SESSION_DIR}/r${round}_gemini.md"
    fi
    if $USE_CODEX && [[ -f "${SESSION_DIR}/r${round}_codex.md" ]]; then
        echo ""
        echo -e "$(label_codex)"
        cat "${SESSION_DIR}/r${round}_codex.md"
    fi

    # pipeline 모드 파일
    for stage in plan implement review; do
        if [[ -f "${SESSION_DIR}/r${round}_pipeline_${stage}.md" ]]; then
            echo ""
            echo -e "${BOLD}[Pipeline: ${stage}]${NC}"
            cat "${SESSION_DIR}/r${round}_pipeline_${stage}.md"
        fi
    done
}

# ── 모드별 실행 함수 ──────────────────────────────────

run_debate_mode() {
    local start_round="${1:-1}"

    # Round 1: 자유 분석
    if [[ $start_round -le 1 ]]; then
        log_info "━━━ 라운드 1/${ROUNDS}: 자유 분석 ━━━"
        run_parallel_round 1 "round1"
        $VERBOSE && print_round_results 1
    fi

    # Round 2~N: 교차 리뷰
    for ((r = (start_round > 2 ? start_round : 2); r <= ROUNDS; r++)); do
        # 활성 에이전트 수 재확인 (disabled 제외)
        local active_now=0
        $USE_CLAUDE && [[ ! " ${DISABLED_AGENTS[*]:-} " =~ " claude " ]] && ((active_now++)) || true
        $USE_GEMINI && [[ ! " ${DISABLED_AGENTS[*]:-} " =~ " gemini " ]] && ((active_now++)) || true
        $USE_CODEX  && [[ ! " ${DISABLED_AGENTS[*]:-} " =~ " codex " ]]  && ((active_now++)) || true
        if [[ $active_now -lt 1 ]]; then
            log_error "활성 에이전트가 없습니다 — 토론 종료"
            finalize_manifest "no_active_agents"
            exit 3
        fi

        echo ""
        log_info "━━━ 라운드 ${r}/${ROUNDS}: 교차 리뷰 (활성: ${active_now}명) ━━━"
        run_parallel_round "$r" "review"
        $VERBOSE && print_round_results "$r"

        # 합의도 검사 (마지막 라운드 제외, threshold > 0)
        if [[ $CONSENSUS_THRESHOLD -gt 0 ]] && [[ $r -lt $ROUNDS ]]; then
            local consensus_score
            consensus_score=$(score_consensus "$r")
            if [[ $consensus_score -ge $CONSENSUS_THRESHOLD ]]; then
                log_ok "합의 도달 (${consensus_score}/${CONSENSUS_THRESHOLD}) — 추가 라운드를 건너뜁니다."
                ROUNDS=$r
                break
            fi
        fi
    done
}

run_adversarial_mode() {
    local start_round="${1:-1}"

    # 활성 에이전트 목록
    local agents=()
    $USE_CLAUDE && agents+=("claude")
    $USE_GEMINI && agents+=("gemini")
    $USE_CODEX  && agents+=("codex")

    # Round 1: 자유 분석 (debate와 동일)
    if [[ $start_round -le 1 ]]; then
        log_info "━━━ 라운드 1/${ROUNDS}: 자유 분석 ━━━"
        run_parallel_round 1 "round1"
        $VERBOSE && print_round_results 1
    fi

    # Round 2~N: 반대론자 순환
    for ((r = (start_round > 2 ? start_round : 2); r <= ROUNDS; r++)); do
        # 활성 에이전트 수 재확인 (disabled 제외)
        local active_now=0
        local active_agents=()
        $USE_CLAUDE && [[ ! " ${DISABLED_AGENTS[*]:-} " =~ " claude " ]] && ((active_now++)) && active_agents+=("claude") || true
        $USE_GEMINI && [[ ! " ${DISABLED_AGENTS[*]:-} " =~ " gemini " ]] && ((active_now++)) && active_agents+=("gemini") || true
        $USE_CODEX  && [[ ! " ${DISABLED_AGENTS[*]:-} " =~ " codex " ]]  && ((active_now++)) && active_agents+=("codex")  || true
        if [[ $active_now -lt 1 ]]; then
            log_error "활성 에이전트가 없습니다 — 토론 종료"
            finalize_manifest "no_active_agents"
            exit 3
        fi

        # 반대론자: 활성 에이전트 중에서만 순환
        local devil_idx=$(( (r - 2) % ${#active_agents[@]} ))
        local devil_agent="${active_agents[$devil_idx]}"
        echo ""
        log_info "━━━ 라운드 ${r}/${ROUNDS}: 교차 리뷰 (반대론자: ${devil_agent}, 활성: ${active_now}명) ━━━"
        run_parallel_round "$r" "adversarial" "$devil_agent"
        $VERBOSE && print_round_results "$r"

        # 합의도 검사
        if [[ $CONSENSUS_THRESHOLD -gt 0 ]] && [[ $r -lt $ROUNDS ]]; then
            local consensus_score
            consensus_score=$(score_consensus "$r")
            if [[ $consensus_score -ge $CONSENSUS_THRESHOLD ]]; then
                log_ok "합의 도달 (${consensus_score}/${CONSENSUS_THRESHOLD}) — 추가 라운드를 건너뜁니다."
                ROUNDS=$r
                break
            fi
        fi
    done
}

run_pipeline_mode() {
    local iteration="${1:-1}"

    # 에이전트 할당: planner, implementer, reviewer
    local planner="" implementer="" reviewer=""
    if $USE_GEMINI; then planner="gemini"
    elif $USE_CLAUDE && ! $INSIDE_CLAUDE_CODE; then planner="claude"
    elif $USE_CODEX; then planner="codex"
    fi

    if $USE_CLAUDE && ! $INSIDE_CLAUDE_CODE; then implementer="claude"
    elif $USE_CODEX; then implementer="codex"
    elif $USE_GEMINI; then implementer="gemini"
    fi

    if $USE_CODEX; then reviewer="codex"
    elif $USE_GEMINI && [[ "$planner" != "gemini" ]]; then reviewer="gemini"
    elif $USE_CLAUDE && ! $INSIDE_CLAUDE_CODE && [[ "$implementer" != "claude" ]]; then reviewer="claude"
    else reviewer="$planner"  # fallback: same agent reviews
    fi

    log_info "역할 분담: 계획=$(agent_label "$planner"), 구현=$(agent_label "$implementer"), 리뷰=$(agent_label "$reviewer")"

    for ((iter = iteration; iter <= ROUNDS; iter++)); do
        echo ""
        log_info "━━━ 파이프라인 반복 ${iter}/${ROUNDS} ━━━"

        # Stage 1: Plan
        log_info "  Stage 1/3: 계획 수립 ($(agent_label "$planner"))"
        local plan_prompt
        if [[ $iter -eq 1 ]]; then
            plan_prompt=$(build_pipeline_prompt "plan" "")
        else
            local prev_review
            prev_review=$(cat "${SESSION_DIR}/r$((iter - 1))_pipeline_review.md" 2>/dev/null || echo "")
            plan_prompt=$(build_pipeline_prompt "plan" "이전 리뷰 피드백:\n${prev_review}")
        fi
        call_agent_with_retry "$planner" "$plan_prompt" "${SESSION_DIR}/r${iter}_pipeline_plan.md"
        update_manifest_round "$iter" "pipeline_plan" "success" "0" "$(wc -w < "${SESSION_DIR}/r${iter}_pipeline_plan.md" | tr -d ' ')"

        local plan_content
        plan_content=$(cat "${SESSION_DIR}/r${iter}_pipeline_plan.md")

        # Stage 2: Implement
        log_info "  Stage 2/3: 구현/상세화 ($(agent_label "$implementer"))"
        local impl_prompt
        impl_prompt=$(build_pipeline_prompt "implement" "$plan_content")
        call_agent_with_retry "$implementer" "$impl_prompt" "${SESSION_DIR}/r${iter}_pipeline_implement.md"
        update_manifest_round "$iter" "pipeline_implement" "success" "0" "$(wc -w < "${SESSION_DIR}/r${iter}_pipeline_implement.md" | tr -d ' ')"

        local all_context="${plan_content}

---

$(cat "${SESSION_DIR}/r${iter}_pipeline_implement.md")"

        # Stage 3: Review
        log_info "  Stage 3/3: 리뷰 ($(agent_label "$reviewer"))"
        local review_prompt
        review_prompt=$(build_pipeline_prompt "review" "$all_context")
        call_agent_with_retry "$reviewer" "$review_prompt" "${SESSION_DIR}/r${iter}_pipeline_review.md"
        update_manifest_round "$iter" "pipeline_review" "success" "0" "$(wc -w < "${SESSION_DIR}/r${iter}_pipeline_review.md" | tr -d ' ')"

        $VERBOSE && print_round_results "$iter"
    done
}

# ── 종합 & 출력 ───────────────────────────────────────

run_synthesis() {
    local all_rounds=""
    for ((r = 1; r <= ROUNDS; r++)); do
        all_rounds+="
## 라운드 ${r}
$(collect_previous_opinions "$r")
"
    done

    echo "" >&2
    local synthesis_prompt
    synthesis_prompt=$(build_synthesis_prompt "$all_rounds")
    local final_file="${SESSION_DIR}/final_synthesis.md"

    if $INSIDE_CLAUDE_CODE; then
        log_info "━━━ 라운드 결과 (Claude Code에서 종합 필요) ━━━"
        echo "$all_rounds" > "$final_file"
    elif $USE_CLAUDE; then
        log_info "━━━ 최종 종합 (Claude/Opus-4.6) ━━━"
        if call_claude "$synthesis_prompt" "$final_file"; then
            log_ok "종합 완료"
        else
            log_warn "Claude 종합 실패 — Gemini로 대체"
            if $USE_GEMINI && call_gemini "$synthesis_prompt" "$final_file"; then
                log_ok "종합 완료 (Gemini 대체)"
            else
                log_error "종합 실패 — 마지막 라운드 결과 사용"
                collect_previous_opinions "$ROUNDS" > "$final_file"
            fi
        fi
    elif $USE_GEMINI; then
        log_info "━━━ 최종 종합 (Gemini/3.1-Pro-Preview) ━━━"
        if call_gemini "$synthesis_prompt" "$final_file"; then
            log_ok "종합 완료"
        else
            log_error "종합 실패 — 마지막 라운드 결과 사용"
            collect_previous_opinions "$ROUNDS" > "$final_file"
        fi
    else
        log_info "━━━ 최종 종합 (Codex/GPT-5.4) ━━━"
        if call_codex "$synthesis_prompt" "$final_file"; then
            log_ok "종합 완료"
        else
            collect_previous_opinions "$ROUNDS" > "$final_file"
        fi
    fi

    # manifest에 종합 결과 기록
    if [[ -s "$final_file" ]]; then
        local tmp="${SESSION_DIR}/manifest.json.tmp"
        jq --arg synthesis "$(cat "$final_file")" \
           '.final_synthesis = $synthesis' \
           "${SESSION_DIR}/manifest.json" > "$tmp" && mv "$tmp" "${SESSION_DIR}/manifest.json"
    fi

    echo "$final_file"
}

build_structured_report() {
    local final_file="$1"
    local report_file="${SESSION_DIR}/report.md"

    {
        echo "# LLM Council Report"
        echo ""
        echo "| Field | Value |"
        echo "|-------|-------|"
        echo "| Session | \`${SESSION_ID}\` |"
        echo "| Mode | ${MODE} |"
        echo "| Rounds | ${ROUNDS} |"
        echo "| Agents | $($USE_CLAUDE && echo 'Claude ')$($USE_GEMINI && echo 'Gemini ')$($USE_CODEX && echo 'Codex') |"
        echo "| Consensus | ${CONSENSUS_THRESHOLD} |"
        echo "| Started | $(jq -r '.started_at // "N/A"' "${SESSION_DIR}/manifest.json") |"
        echo "| Completed | $(jq -r '.completed_at // "N/A"' "${SESSION_DIR}/manifest.json") |"

        # 합의도 이력
        local consensus_count
        consensus_count=$(jq '.consensus_history | length' "${SESSION_DIR}/manifest.json" 2>/dev/null || echo "0")
        if [[ $consensus_count -gt 0 ]]; then
            echo ""
            echo "## Consensus Trajectory"
            echo ""
            jq -r '.consensus_history[] | "- Round \(.round): **\(.score)**/100 — \(.reason)"' "${SESSION_DIR}/manifest.json"
        fi

        echo ""
        echo "## Topic"
        echo ""
        echo "${PROMPT}"
        echo ""
        echo "---"
        echo ""
        echo "## Synthesis"
        echo ""
        cat "$final_file"

        # Token Usage 섹션
        echo ""
        echo "---"
        echo ""
        echo "## Token Usage"
        echo ""

        # Gemini / Codex 누적 토큰
        local has_token_data=false
        echo "### 라운드별 사용량"
        echo ""
        echo "| Agent | Round | Input | Output | Cached | Total |"
        echo "|-------|-------|-------|--------|--------|-------|"
        for ((r = 1; r <= ROUNDS; r++)); do
            for agent in gemini codex; do
                local tf="${SESSION_DIR}/r${r}_${agent}.md.tokens.json"
                [[ ! -s "$tf" ]] && continue
                local t_total
                t_total=$(jq -r '.total // .total_tokens // 0' "$tf" 2>/dev/null) || true
                [[ "$t_total" == "0" || "$t_total" == "null" || -z "$t_total" ]] && continue
                has_token_data=true
                local t_in t_out t_cache
                t_in=$(jq -r '.input // .input_tokens // 0' "$tf" 2>/dev/null)
                t_out=$(jq -r '.output // .output_tokens // 0' "$tf" 2>/dev/null)
                t_cache=$(jq -r '.cached // .cached_input_tokens // 0' "$tf" 2>/dev/null)
                echo "| $(agent_label "$agent") | R${r} | ${t_in} | ${t_out} | ${t_cache} | ${t_total} |"
            done
        done

        if ! $has_token_data; then
            echo "| - | - | - | - | - | (토큰 데이터 없음) |"
        fi

        # Claude 한도 현황
        echo ""
        echo "### 한도 현황"
        echo ""
        echo "| Agent | 한도 정보 |"
        echo "|-------|-----------|"
        if [[ -s "${SESSION_DIR}/claude_quota.json" ]]; then
            local h5 d7
            h5=$(jq -r '.five_hour_pct // "?"' "${SESSION_DIR}/claude_quota.json" 2>/dev/null)
            d7=$(jq -r '.seven_day_pct // "?"' "${SESSION_DIR}/claude_quota.json" 2>/dev/null)
            echo "| Claude | 5h: ${h5}% 사용, 7d: ${d7}% 사용 |"
        else
            echo "| Claude | (조회 불가) |"
        fi
        echo "| Gemini | (한도 조회 불가 — Google AI Studio에서 확인) |"
        echo "| Codex | (한도 조회 불가 — OpenAI 대시보드에서 확인) |"

        echo ""
        echo "---"
        echo ""
        echo "## Round Details"
        for ((r = 1; r <= ROUNDS; r++)); do
            echo ""
            echo "### Round ${r}"
            collect_previous_opinions "$r"
        done
    } > "$report_file"

    echo "$report_file"
}

# ── 메인 실행 ──────────────────────────────────────────

main() {
    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   LLM Council v2 - 멀티라운드 디베이트    ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    log_info "주제: ${PROMPT}"
    log_info "모드: ${MODE} | 라운드: ${ROUNDS} | 합의 임계: ${CONSENSUS_THRESHOLD} | 유예: ${GRACE_PERIOD}s"
    log_info "에이전트: $($USE_CLAUDE && echo 'Claude ')$($USE_GEMINI && echo 'Gemini ')$($USE_CODEX && echo 'Codex')"
    if $INSIDE_CLAUDE_CODE; then
        log_warn "Claude Code 내부 실행 감지 — Claude CLI 제외 (Claude Code가 직접 참여)"
    fi
    echo ""

    # 매니페스트 초기화 (재개 시 스킵)
    if [[ -z "$RESUME_SESSION" ]]; then
        init_manifest
    fi

    # 재개 시작 라운드 결정
    local start_round=1
    if [[ -n "$RESUME_SESSION" ]]; then
        start_round=${RESUME_FROM_ROUND:-1}
    fi

    # 모드별 실행
    case "$MODE" in
        debate)       run_debate_mode "$start_round" ;;
        adversarial)  run_adversarial_mode "$start_round" ;;
        pipeline)     run_pipeline_mode "$start_round" ;;
    esac

    # 최종 합의도 (마지막 라운드)
    if [[ $CONSENSUS_THRESHOLD -gt 0 ]] && [[ "$MODE" != "pipeline" ]]; then
        score_consensus "$ROUNDS" >/dev/null 2>&1 || true
    fi

    # 종합
    local final_file
    final_file=$(run_synthesis)

    # 매니페스트 마무리
    finalize_manifest "completed"

    # 결과 출력
    if $JSON_OUTPUT; then
        cat "${SESSION_DIR}/manifest.json"
    else
        echo ""
        echo -e "${BOLD}"
        echo "╔══════════════════════════════════════════╗"
        echo "║            최종 합의안                    ║"
        echo "╚══════════════════════════════════════════╝"
        echo -e "${NC}"
        cat "$final_file"

        # 구조화된 리포트 생성
        local report_file
        report_file=$(build_structured_report "$final_file")
        log_info "리포트: ${report_file}"
    fi

    # 파일 저장
    if [[ -n "$OUTPUT_FILE" ]]; then
        if $JSON_OUTPUT; then
            cp "${SESSION_DIR}/manifest.json" "$OUTPUT_FILE"
        else
            cp "$(build_structured_report "$final_file")" "$OUTPUT_FILE"
        fi
        log_ok "결과 저장: ${OUTPUT_FILE}"
    fi

    echo ""
    # 최종 토큰 요약 (Claude 한도 포함)
    log_info "━━━ 토큰 & 한도 요약 ━━━"
    print_token_summary "$ROUNDS"
    # Gemini/Codex 남은 한도 안내 (비대화형에서 조회 불가)
    $USE_GEMINI && log_info "  ${DIM}[Tip]${NC} Gemini 남은 한도: gemini 실행 후 /stats session"
    $USE_CODEX  && log_info "  ${DIM}[Tip]${NC} Codex 남은 한도: codex 실행 후 /status"

    echo ""
    log_info "세션 파일: ${SESSION_DIR}"
    log_info "전체 라운드 결과를 확인하려면: ls ${SESSION_DIR}/"
}

main
