#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE_SCRIPT="$SCRIPT_DIR/statusline-command.sh"
TARGET_DIR="$HOME/.claude"
TARGET_SCRIPT="$TARGET_DIR/statusline-command.sh"
SETTINGS_FILE="$TARGET_DIR/settings.json"

# Check statusline-command.sh exists next to this script
if [ ! -f "$STATUSLINE_SCRIPT" ]; then
    echo "Error: statusline-command.sh not found in $SCRIPT_DIR"
    exit 1
fi

# --- Install dependencies ---
install_deps() {
    local missing=()
    for cmd in jq curl bc; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo "Dependencies: jq, curl, bc — all present"
        return
    fi

    echo "Missing: ${missing[*]}"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if command -v brew >/dev/null 2>&1; then
            brew install "${missing[@]}"
        else
            echo "Error: Homebrew not found. Install it from https://brew.sh or install ${missing[*]} manually."
            exit 1
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "${missing[@]}"
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm "${missing[@]}"
    else
        echo "Error: Could not detect package manager. Install ${missing[*]} manually."
        exit 1
    fi

    echo "Installed: ${missing[*]}"
}

install_deps

# --- Copy script ---
mkdir -p "$TARGET_DIR"
cp "$STATUSLINE_SCRIPT" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"
echo "Copied statusline-command.sh to $TARGET_DIR"

# --- Update settings.json ---
statusline_cmd="bash $TARGET_SCRIPT"
new_block='{"statusLine":{"type":"command","command":"'"$statusline_cmd"'"}}'

if [ -f "$SETTINGS_FILE" ]; then
    # Merge into existing settings
    updated=$(jq --argjson sl "$new_block" '. * $sl' "$SETTINGS_FILE")
    echo "$updated" > "$SETTINGS_FILE"
    echo "Updated $SETTINGS_FILE"
else
    echo "$new_block" | jq . > "$SETTINGS_FILE"
    echo "Created $SETTINGS_FILE"
fi

echo "Done. Restart Claude Code to see the status line."
