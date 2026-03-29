---
name: recap
description: "Project recap — get back up to speed. Modes: quick (default), full, git, stack, onboard, files, todos. Add keyword to filter."
argument-hint: "[mode] [focus] — e.g. 'quick', 'full auth', 'todos api'"
---

# Project Recap

Script output:

!`bash ~/.claude/skills/recap/scripts/recap.sh $ARGUMENTS`

## How to read the output

The script outputs structured markers:
- `@MODE:<mode>` — which mode was run
- `@FOCUS:<term>` — filter keyword (or "none")
- `@KV:key=value` — project metadata
- `---@SECTION:<name>` — data section boundary
- `@FILE:<name>` — file content follows

## Your job

Take the script output and present it as a **clean, scannable recap**. Follow these rules:

1. **Never show raw script output.** Transform it into polished prose and formatted sections.
2. **Be specific.** Name files, functions, branches, components. Never say "continue the feature."
3. **Keep it tight.** quick mode: under 40 lines. full mode: under 80 lines. Other modes: under 50 lines.
4. **Infer "what was I working on"** from the diff stat, recent commits, and changed files. Connect the dots — don't just list files.
5. **Suggest concrete next steps** based on uncommitted changes, recent commit patterns, and TODOs.
6. **Use the project's own terminology** from README/config content in the output.

## Output format by mode

**quick** → Branch, last commit, recent commits, uncommitted changes, "What you were working on" (2-4 bullets synthesized from data), Next steps (2-3 items).

**full** → Everything in quick, plus: project description (from README), tech stack, project structure, scripts/config, TODOs in recent files.

**git** → Branch, tracking info, last 10 commits, working tree status, diff stat, stashes, all branches with dates.

**stack** → Languages, frameworks, key dependencies, available scripts, config files, runtime versions.

**onboard** → Project description, tech stack, how to run/test, project structure with annotations, key files to read, conventions.

**files** → Recently modified files with timestamps, uncommitted changes.

**todos** → TODO/FIXME/HACK grouped by file with line numbers, task files, summary counts.
