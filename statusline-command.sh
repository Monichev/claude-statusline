#!/bin/bash

input=$(cat)

model_name=$(echo "$input" | jq -r '.model.display_name // .model.id')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
context_size=$(echo "$input" | jq -r '.context_window.context_window_size // 0')

if [ -z "$used_pct" ] || [ "$used_pct" = "null" ]; then
    echo "$model_name | Context: ░░░░░░░░░░░░░░░░░░░░ 0.0% [0/0]"
    exit 0
fi

total_tokens=$(printf "%.0f" "$(echo "$used_pct * $context_size / 100" | bc -l)")

if [ $total_tokens -ge 1000 ]; then
    total_tokens_fmt="$((total_tokens / 1000))K"
else
    total_tokens_fmt="$total_tokens"
fi

if [ $context_size -ge 1000 ]; then
    context_size_fmt="$((context_size / 1000))K"
else
    context_size_fmt="$context_size"
fi

bar_length=20
filled=$(printf "%.0f" $(echo "$used_pct * $bar_length / 100" | bc -l))
empty=$((bar_length - filled))

bar=""
for ((i=0; i<filled; i++)); do bar="${bar}▓"; done
for ((i=0; i<empty; i++)); do bar="${bar}░"; done

used_pct_fmt=$(printf "%.1f" "$used_pct")

# --- Git info ---
git_part=""
# Find .git dir for lock check (works inside worktrees too)
_git_dir=$(GIT_OPTIONAL_LOCKS=0 git rev-parse --git-dir 2>/dev/null)
if [ -n "$_git_dir" ] && [ ! -f "$_git_dir/index.lock" ] && GIT_OPTIONAL_LOCKS=0 git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # GIT_OPTIONAL_LOCKS=0 prevents git from taking the index lock for
    # optional operations (stat-cache refresh). This avoids contention
    # with Claude Code's own git commands running in parallel.
    branch=$(GIT_OPTIONAL_LOCKS=0 git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ ${#branch} -gt 20 ] && branch="${branch:0:19}…"

    eval $(GIT_OPTIONAL_LOCKS=0 git status --porcelain 2>/dev/null | awk '{
        x=substr($0,1,1); y=substr($0,2,1)
        if (x=="?" && y=="?") { u++; next }
        if (x=="A" || x=="R" || x=="C") { a++; next }
        if (x=="D" || y=="D") { d++; next }
        m++
    } END { printf "added=%d modified=%d deleted=%d untracked=%d", a+0, m+0, d+0, u+0 }')

    git_part="$branch"
    [ "$added" -gt 0 ] && git_part="$git_part +$added"
    [ "$modified" -gt 0 ] && git_part="$git_part ~$modified"
    [ "$deleted" -gt 0 ] && git_part="$git_part -$deleted"
    [ "$untracked" -gt 0 ] && git_part="$git_part ?$untracked"
fi

context_part="$model_name | Context: $bar $used_pct_fmt% [$total_tokens_fmt/$context_size_fmt]"

# --- Rate limits ---
CACHE_FILE="/tmp/claude-statusline-usage-cache.json"
CACHE_MAX_AGE=60
HISTORY_MAX=11

fetch_usage() {
    local token
    # macOS: Keychain
    if [[ "$OSTYPE" == "darwin"* ]]; then
        token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
            | jq -r '.claudeAiOauth.accessToken' 2>/dev/null)
    # Linux: credentials file
    else
        local cred_file="$HOME/.claude/.credentials.json"
        [ -f "$cred_file" ] || cred_file="$HOME/.claude/credentials.json"
        token=$(jq -r '.claudeAiOauth.accessToken' "$cred_file" 2>/dev/null)
    fi
    [ -z "$token" ] || [ "$token" = "null" ] && return 1

    local response
    response=$(curl -s --max-time 5 -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || return 1

    # Verify it's valid JSON with expected fields
    echo "$response" | jq -e '.five_hour.utilization' >/dev/null 2>&1 || return 1

    local now_iso
    now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local five_h_val seven_d_val
    five_h_val=$(echo "$response" | jq -r '.five_hour.utilization // 0')
    seven_d_val=$(echo "$response" | jq -r '.seven_day.utilization // 0')

    local new_entry
    new_entry=$(jq -n --arg ts "$now_iso" --argjson f "$five_h_val" --argjson s "$seven_d_val" \
        '{timestamp: $ts, five_hour_util: $f, seven_day_util: $s}')

    # Build cache with history
    if [ -f "$CACHE_FILE" ]; then
        local prev_history
        prev_history=$(jq -r '.history // []' "$CACHE_FILE" 2>/dev/null)
        [ "$prev_history" = "null" ] && prev_history="[]"
        jq -n \
            --arg ts "$now_iso" \
            --argjson current "$response" \
            --argjson prev "$prev_history" \
            --argjson entry "$new_entry" \
            --argjson max "$HISTORY_MAX" \
            '{
                last_updated: $ts,
                current: $current,
                history: ([$entry] + $prev | .[:$max])
            }' > "$CACHE_FILE"
    else
        jq -n \
            --arg ts "$now_iso" \
            --argjson current "$response" \
            --argjson entry "$new_entry" \
            '{
                last_updated: $ts,
                current: $current,
                history: [$entry]
            }' > "$CACHE_FILE"
    fi
}

# Check cache freshness and refresh if needed
need_refresh=false
if [ ! -f "$CACHE_FILE" ]; then
    need_refresh=true
else
    if [[ "$OSTYPE" == "darwin"* ]]; then
        cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE") ))
    else
        cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE") ))
    fi
    [ "$cache_age" -ge "$CACHE_MAX_AGE" ] && need_refresh=true
fi

if $need_refresh; then
    fetch_usage
fi

# Parse cached data
limits_part=""
if [ -f "$CACHE_FILE" ]; then
    five_h_util=$(jq -r '.current.five_hour.utilization // empty' "$CACHE_FILE" 2>/dev/null)
    five_h_reset=$(jq -r '.current.five_hour.resets_at // empty' "$CACHE_FILE" 2>/dev/null)
    seven_d_util=$(jq -r '.current.seven_day.utilization // empty' "$CACHE_FILE" 2>/dev/null)
    seven_d_reset=$(jq -r '.current.seven_day.resets_at // empty' "$CACHE_FILE" 2>/dev/null)
    cache_updated=$(jq -r '.last_updated // empty' "$CACHE_FILE" 2>/dev/null)

    if [ -n "$five_h_util" ] && [ "$five_h_util" != "null" ]; then
        five_h_int=$(printf "%.0f" "$five_h_util")

        # Calculate time until reset
        reset_str=""
        if [ -n "$five_h_reset" ] && [ "$five_h_reset" != "null" ]; then
            # API returns UTC times — parse accordingly
            stripped=$(echo "$five_h_reset" | sed 's/\.[0-9]*[+-].*//;s/[+-][0-9][0-9]:[0-9][0-9]$//')
            if [[ "$OSTYPE" == "darwin"* ]]; then
                reset_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$stripped" +%s 2>/dev/null)
            else
                reset_epoch=$(date -ud "$five_h_reset" +%s 2>/dev/null)
            fi

            if [ -n "$reset_epoch" ]; then
                now_epoch=$(date +%s)
                diff_s=$((reset_epoch - now_epoch))
                if [ "$diff_s" -gt 0 ]; then
                    diff_h=$((diff_s / 3600))
                    diff_m=$(( (diff_s % 3600) / 60 ))
                    if [ "$diff_h" -gt 0 ]; then
                        reset_str=" reset ${diff_h}h${diff_m}m"
                    else
                        reset_str=" reset ${diff_m}m"
                    fi
                fi
            fi
        fi

        seven_d_int=""
        seven_d_reset_str=""
        if [ -n "$seven_d_util" ] && [ "$seven_d_util" != "null" ]; then
            seven_d_int=$(printf "%.0f" "$seven_d_util")
        fi

        if [ -n "$seven_d_reset" ] && [ "$seven_d_reset" != "null" ]; then
            stripped7d=$(echo "$seven_d_reset" | sed 's/\.[0-9]*[+-].*//;s/[+-][0-9][0-9]:[0-9][0-9]$//')
            if [[ "$OSTYPE" == "darwin"* ]]; then
                reset7d_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$stripped7d" +%s 2>/dev/null)
            else
                reset7d_epoch=$(date -ud "$seven_d_reset" +%s 2>/dev/null)
            fi

            if [ -n "$reset7d_epoch" ]; then
                now7d_epoch=$(date +%s)
                diff7d_s=$((reset7d_epoch - now7d_epoch))
                if [ "$diff7d_s" -gt 0 ]; then
                    diff7d_d=$((diff7d_s / 86400))
                    diff7d_h=$(( (diff7d_s % 86400) / 3600 ))
                    if [ "$diff7d_d" -gt 0 ]; then
                        seven_d_reset_str=" reset ${diff7d_d}d${diff7d_h}h"
                    else
                        seven_d_reset_str=" reset ${diff7d_h}h"
                    fi
                fi
            fi
        fi

        # Build sparkline from history — shows token consumption rate (deltas)
        sparkline=""
        history_count=$(jq -r '.history | length' "$CACHE_FILE" 2>/dev/null)
        if [ -n "$history_count" ] && [ "$history_count" -gt 1 ]; then
            spark_chars=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
            # Compute deltas between consecutive entries (newest first in history)
            # Delta = newer.util - older.util (consumption between two snapshots)
            deltas=$(jq -r '
                [range(.history | length - 1)] as $indices |
                [$indices[] as $i |
                    (.history[$i].five_hour_util - .history[$i+1].five_hour_util)
                    | if . < 0 then 0 else . end
                ] | reverse | @tsv' "$CACHE_FILE" 2>/dev/null)
            # Find max delta for normalization (minimum 1% to avoid flat graph)
            max_delta=1000  # 1% * 1000
            for d in $deltas; do
                d_int=$(printf "%.0f" "$(echo "$d * 1000" | bc -l)" 2>/dev/null)
                [ -z "$d_int" ] && d_int=0
                [ "$d_int" -gt "$max_delta" ] && max_delta=$d_int
            done
            # Number of deltas = history_count - 1
            delta_count=$((history_count - 1))
            pad_count=$((HISTORY_MAX - 1 - delta_count))  # 11-1=10 slots for deltas
            [ "$pad_count" -lt 0 ] && pad_count=0
            for ((i=0; i<pad_count; i++)); do sparkline="${sparkline}░"; done
            for d in $deltas; do
                d_int=$(printf "%.0f" "$(echo "$d * 1000" | bc -l)" 2>/dev/null)
                [ -z "$d_int" ] && d_int=0
                if [ "$d_int" -eq 0 ]; then
                    sparkline="${sparkline}░"
                else
                    idx=$(printf "%.0f" "$(echo "$d * 1000 * 7 / $max_delta" | bc -l)" 2>/dev/null)
                    [ -z "$idx" ] && idx=1
                    [ "$idx" -lt 1 ] && idx=1
                    [ "$idx" -gt 7 ] && idx=7
                    sparkline="${sparkline}${spark_chars[$idx]}"
                fi
            done
        fi

        # Format last updated timestamp
        updated_str=""
        if [ -n "$cache_updated" ] && [ "$cache_updated" != "null" ]; then
            # Convert UTC timestamp to local time for display
            stripped_upd=$(echo "$cache_updated" | sed 's/Z$//')
            if [[ "$OSTYPE" == "darwin"* ]]; then
                upd_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%S" "$stripped_upd" +%s 2>/dev/null)
            else
                upd_epoch=$(date -ud "$cache_updated" +%s 2>/dev/null)
            fi
            if [ -n "$upd_epoch" ]; then
                now_epoch=$(date +%s)
                age_s=$((now_epoch - upd_epoch))
                if [ "$age_s" -lt 60 ]; then
                    updated_str=" @${age_s}s ago"
                elif [ "$age_s" -lt 3600 ]; then
                    updated_str=" @$((age_s / 60))m ago"
                else
                    updated_str=" @$((age_s / 3600))h ago"
                fi
            fi
        fi

        limits_part="5h: ${five_h_int}%${reset_str}"
        [ -n "$sparkline" ] && limits_part="${limits_part} ${sparkline}"
        if [ -n "$seven_d_int" ]; then
            limits_part="${limits_part} | 7d: ${seven_d_int}%${seven_d_reset_str}"
        fi
        limits_part="${limits_part}${updated_str}"
    fi
fi

output="$context_part"
[ -n "$limits_part" ] && output="$output | $limits_part"
[ -n "$git_part" ] && output="$output | $git_part"
echo "$output"