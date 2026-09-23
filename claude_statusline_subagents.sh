#!/bin/bash
# Emits one status line per subagent of the current session, showing that
# subagent's own context-window usage.
#
# Claude Code passes no subagent state to the statusline, so this reads the
# per-agent transcripts the CLI writes next to the session transcript:
#   <project>/<session-id>/subagents/agent-<id>.jsonl   (live token usage)
#   <project>/<session-id>/subagents/agent-<id>.meta.json (agent type, model)
#
# Only running agents are listed; a finished one disappears on the next refresh.
# Completion is read from the agent's own transcript: its last non-null
# stop_reason is "tool_use" while the agent loop is turning and "end_turn" once
# it answers. Completion is deliberately not read from the parent transcript —
# a background agent's tool_result is written at launch, not at finish.
#
# Usage: claude_statusline_subagents.sh <transcript_path> <main_model_id> <main_window_size>

set -uo pipefail

TRANSCRIPT_PATH=${1:?transcript_path required}
MAIN_MODEL=${2:?main model id required}
MAIN_WINDOW=${3:?main context window size required}

SUBAGENT_DIR="${TRANSCRIPT_PATH%.jsonl}/subagents"
[ -d "$SUBAGENT_DIR" ] || exit 0

# How long a stalled final-answer partial waits before it counts as finished.
UNFLUSHED_ANSWER_SECONDS=20
# An agent killed mid-turn never records a terminal stop_reason, so fall back to
# silence. Generous, so a genuinely slow tool call is not mistaken for a corpse.
STALE_AFTER_SECONDS=600
MAX_ROWS=6
BAR_WIDTH=10

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# Context window for a subagent's model. The main agent's window is reused when
# the models match, so a session-level override needs no table entry. Unknown
# models yield 0, which the caller renders as "?" rather than a wrong bar.
context_window_for() {
    local model=$1
    if [ "$model" = "$MAIN_MODEL" ]; then
        echo "$MAIN_WINDOW"
        return
    fi
    case "$model" in
        *haiku-4-5*)                                echo 200000 ;;
        *opus-5*|*sonnet-5*|*fable-5*|*mythos-5*)   echo 1000000 ;;
        *opus-4-*|*sonnet-4-6*)                     echo 1000000 ;;
        *)                                          echo 0 ;;
    esac
}

# Trim the model id down to what distinguishes it, for a narrow status line:
# drop the "claude-" prefix, a "[1m]"-style suffix and a date stamp, and render
# the version as major.minor (claude-opus-5-5 -> opus-5.5).
short_model_name() {
    local model=${1#claude-}
    model=${model%%\[*}
    sed -E 's/-[0-9]{8}$//; s/-([0-9]+)-([0-9]+)$/-\1.\2/' <<<"$model"
}

format_tokens() {
    local tokens=$1
    if [ "$tokens" -ge 1000000 ]; then
        printf '%d.%dM' $((tokens / 1000000)) $(((tokens % 1000000) / 100000))
    else
        printf '%dk' $((tokens / 1000))
    fi
}

format_duration() {
    local seconds=$1
    if [ "$seconds" -ge 60 ]; then
        printf '%dm%02ds' $((seconds / 60)) $((seconds % 60))
    else
        printf '%ds' "$seconds"
    fi
}

render_bar() {
    local pct=$1 filled empty fill pad
    filled=$((pct * BAR_WIDTH / 100))
    [ "$filled" -gt "$BAR_WIDTH" ] && filled=$BAR_WIDTH
    empty=$((BAR_WIDTH - filled))
    printf -v fill "%${filled}s"
    printf -v pad "%${empty}s"
    printf '%s%s' "${fill// /█}" "${pad// /░}"
}

now=$(date +%s)
rows=()

for meta in "$SUBAGENT_DIR"/agent-*.meta.json; do
    [ -e "$meta" ] || continue
    jsonl="${meta%.meta.json}.jsonl"
    [ -f "$jsonl" ] || continue

    agent_type=$(jq -r '.agentType // "agent"' "$meta")

    idle=$((now - $(stat -c %Y "$jsonl")))
    [ "$idle" -le "$STALE_AFTER_SECONDS" ] || continue

    # The loop is still turning only while the newest settled turn ended in a
    # tool call. Partial streaming entries carry a null stop_reason, so match on
    # a quoted value to skip them and find the last turn that actually settled.
    stop_line=$(tac "$jsonl" | grep -m1 -F '"stop_reason":"')
    if [ -n "$stop_line" ]; then
        stop_reason=$(printf '%s' "$stop_line" | jq -r '.message.stop_reason // ""')
        [ "$stop_reason" = "tool_use" ] || continue
    fi

    # The settled "end_turn" entry is not always flushed before the agent exits,
    # leaving a final-answer partial as the last line. A partial that has gone
    # quiet means the agent answered and left. While a slow tool runs the last
    # line is instead a settled tool_use entry, so waiting here costs it nothing.
    IFS=$'\t' read -r last_type last_stop < <(
        tail -n 1 "$jsonl" | jq -r '[.type // "", (.message.stop_reason // "")] | @tsv' 2>/dev/null
    )
    if [ "$last_type" = assistant ] && [ -z "$last_stop" ] \
       && [ "$idle" -gt "$UNFLUSHED_ANSWER_SECONDS" ]; then
        continue
    fi

    # Only the most recent assistant turn is needed: its usage counts describe
    # the whole prompt currently in that agent's context.
    usage_line=$(tac "$jsonl" | grep -m1 -F '"usage"')
    [ -n "$usage_line" ] || continue

    IFS=$'\t' read -r model tokens < <(
        printf '%s' "$usage_line" | jq -r '
            [ .message.model // "",
              ( (.message.usage.input_tokens // 0)
              + (.message.usage.cache_read_input_tokens // 0)
              + (.message.usage.cache_creation_input_tokens // 0)
              + (.message.usage.output_tokens // 0) )
            ] | @tsv'
    )

    started=$(stat -c %Y "$meta")
    elapsed=$((now - started))

    window=$(context_window_for "$model")
    if [ "$window" -gt 0 ]; then
        pct=$((tokens * 100 / window))
        if   [ "$pct" -ge 90 ]; then bar_color=$RED
        elif [ "$pct" -ge 70 ]; then bar_color=$YELLOW
        else                         bar_color=$GREEN
        fi
        gauge=$(printf '%b%s%b %3d%%' "$bar_color" "$(render_bar "$pct")" "$RESET" "$pct")
    else
        gauge=$(printf '%s   ?%%' "$(render_bar 0)")
    fi

    line=$(printf '  ● %-16s %-9s %s %6s  %s' \
        "${agent_type:0:16}" "$(short_model_name "$model")" "$gauge" \
        "$(format_tokens "$tokens")" "$(format_duration "$elapsed")")

    # Longest-running first, so the row order stays stable as agents come and go.
    rows+=("$(printf '%d\t%s' "$started" "$line")")
done

[ ${#rows[@]} -gt 0 ] || exit 0

printf '%s\n' "${rows[@]}" \
    | sort -t$'\t' -k1,1n \
    | head -n "$MAX_ROWS" \
    | cut -f2-
