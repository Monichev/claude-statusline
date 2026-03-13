# Claude Code Statusline

A custom statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that shows model info, context usage, rate limits, and git status at a glance.

```
Opus 4.6 | Context: ▓▓▓▓░░░░░░░░░░░░░░░░ 21.0% [42K/200K] | 5h: 4% reset 4h37m | 7d: 3% reset 5d12h @13:12:10 ░░░░░░░▁▂█ | main +2 ~5 ?3
```

## What it shows

| Section | Example | Description |
|---------|---------|-------------|
| Model | `Opus 4.6` | Current model name |
| Context | `▓▓▓▓░░░░ 21.0% [42K/200K]` | Context window usage with progress bar |
| Rate limits | `5h: 4% reset 4h37m \| 7d: 3% reset 5d12h` | 5-hour and 7-day usage with reset countdowns |
| Data age | `@13:12:10` | Absolute local time of last rate limit update |
| Sparkline | `░░░░░░░▁▂█` | Token consumption rate (1%=▁ … 8%+=█, ░=idle) |
| Git | `main +2 ~5 -1 ?3` | Branch and file changes |

### Git symbols

| Symbol | Meaning |
|--------|---------|
| `+N` | Added / renamed / copied files |
| `~N` | Modified files |
| `-N` | Deleted files |
| `?N` | Untracked files |

Zero-count indicators are hidden, so a clean repo just shows the branch name.

## Install

```bash
git clone https://github.com/Monichev/claude-statusline.git
cd claude-statusline
bash install.sh
```

The installer:
- Checks for required dependencies (`jq`, `curl`, `bc`) and installs missing ones
- Copies `statusline-command.sh` to `~/.claude/`
- Configures `~/.claude/settings.json` to use it (preserves existing settings)

Restart Claude Code after installing.

## Dependencies

- `jq` — JSON parsing
- `curl` — fetching rate limit data from Anthropic API
- `bc` — floating-point math

## How it works

Claude Code pipes JSON with model and context info to the statusline command via stdin. The script:

1. Parses model name and context window stats
2. Renders a progress bar for context usage
3. Fetches rate limit utilization from the Anthropic API (cached for 60s in `/tmp/claude-statusline-usage-cache.json`)
4. Maintains a history of the last 11 snapshots to compute 10 consumption rate deltas for the sparkline graph
5. Reads git status for the current working directory

## License

MIT
