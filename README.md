# /recap — AI coding agent project recap skill

Get back up to speed on any project instantly. Run `/recap` at the start of a session and get a synthesized summary of your branch, recent commits, uncommitted changes, and what you were working on — no more digging through git logs.

Works with any AI coding agent that supports skills/slash commands (Claude Code, Cursor, Windsurf, Gemini CLI, and others).

## Requirements

- [Node.js](https://nodejs.org) (to run `npx skills`)
- Git
- bash — built into macOS and Linux; Windows users need [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) or [Git Bash](https://git-scm.com/download/win)

## Install

```bash
npx skills add faizansf/recap@recap -g
```

Or search and install interactively:

```bash
npx skills find recap
```

## Usage

```
/recap               # quick summary (default)
/recap full          # full project overview
/recap git           # detailed git status
/recap stack         # tech stack and dependencies
/recap onboard       # onboarding view for new contributors
/recap files         # recently modified files
/recap todos         # all TODOs/FIXMEs by file
```

Add a keyword to filter any mode to a specific area:

```
/recap quick auth
/recap todos api
/recap files components
```

## Permissions

The skill runs a bash script to collect project info. Your agent may prompt you to approve it on first use — allow it to proceed.

## How it works

`/recap` runs a bash script that collects git state, recent file changes, TODOs, stack info, and config files from your project. The raw output is passed to your AI agent, which synthesizes it into a clean, scannable summary — no raw script output is shown.

## Uninstall

```bash
rm -rf ~/.agents/skills/recap
rm -rf ~/.claude/skills/recap
```
