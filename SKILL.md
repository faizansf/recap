---
name: recap
description: "Project recap — get back up to speed on any project instantly. Use this skill when the user says things like \"catch me up\", \"what was I working on\", \"summarize recent changes\", \"get me up to speed\", \"what did I do last session\", or starts a new session on an unfamiliar project. Modes: quick (default), full, git, stack, onboard, files, todos. Add a keyword to filter by area."
argument-hint: "[mode] [focus] — e.g. 'quick', 'full auth', 'todos api'"

---

# Project Recap

This skill uses a local bash script to analyze your project activity (git history, file changes, TODOs) and generate a structured recap.

Use the bash tool to execute:

bash ~/.claude/skills/recap/scripts/recap.sh $ARGUMENTS

If permission is required, request approval from the user.

---

## How to read the output

The script outputs structured markers:
- `@MODE:<mode>` — which mode was run  
- `@FOCUS:<term>` — filter keyword (or "none")  
- `@KV:key=value` — project metadata  
- `---@SECTION:<name>` — data section boundary  
- `@FILE:<name>` — file content follows  

---

## Your job

Take the script output and present it as a clean, scannable recap.

### Rules

1. Never show raw script output. Transform it into structured, readable sections.  
2. Be specific. Mention actual files, functions, branches, and components.  
3. Keep it concise:  
   - quick: ≤ 40 lines  
   - full: ≤ 80 lines  
   - others: ≤ 50 lines  
4. Infer what the user was working on using commits, diffs, and file changes.  
5. Suggest concrete next steps based on:
   - uncommitted changes  
   - commit patterns  
   - TODOs  
6. Use project terminology from README/config.

---

## Output format by mode

### quick
- Branch  
- Last commit  
- Recent commits  
- Uncommitted changes  
- What you were working on (2 to 4 insights)  
- Next steps (2 to 3 items)  

### full
Includes everything in quick, plus:
- Project description  
- Tech stack  
- Structure overview  
- Scripts/config  
- TODOs in recent files  

### git
- Branch + tracking  
- Last 10 commits  
- Working tree status  
- Diff stat  
- Stashes  
- All branches with timestamps  

### stack
- Languages  
- Frameworks  
- Key dependencies  
- Scripts  
- Config files  
- Runtime versions  

### onboard
- Project overview  
- Tech stack  
- Setup instructions  
- Structure with explanation  
- Key files  
- Conventions  

### files
- Recently modified files  
- Timestamps  
- Uncommitted changes  

### todos
- TODO / FIXME / HACK grouped by file  
- Line numbers  
- Task files  
- Summary counts
