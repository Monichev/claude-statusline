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
for ((i=0; i<filled; i++)); do bar="${bar}█"; done
for ((i=0; i<empty; i++)); do bar="${bar}░"; done

used_pct_fmt=$(printf "%.1f" "$used_pct")

# --- Git info ---
git_part=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ ${#branch} -gt 20 ] && branch="${branch:0:19}…"

    eval $(git status --porcelain 2>/dev/null | awk '{
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

    echo "$response" > "$CACHE_FILE"
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
    five_h_util=$(jq -r '.five_hour.utilization // empty' "$CACHE_FILE" 2>/dev/null)
    five_h_reset=$(jq -r '.five_hour.resets_at // empty' "$CACHE_FILE" 2>/dev/null)
    seven_d_util=$(jq -r '.seven_day.utilization // empty' "$CACHE_FILE" 2>/dev/null)
    seven_d_reset=$(jq -r '.seven_day.resets_at // empty' "$CACHE_FILE" 2>/dev/null)

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

        limits_part="5h: ${five_h_int}%${reset_str}"
        if [ -n "$seven_d_int" ]; then
            limits_part="${limits_part} | 7d: ${seven_d_int}%${seven_d_reset_str}"
        fi
    fi
fi

output="$context_part"
[ -n "$limits_part" ] && output="$output | $limits_part"
[ -n "$git_part" ] && output="$output | $git_part"
echo "$output"