#!/usr/bin/env bash
# Exit on unset variables and pipe failures, but not on simple non-zero exits.
# -u catches typos in variable names. -o pipefail catches silent failures in
# piped commands like `git log | head -5` where git fails but head succeeds.
set -uo pipefail

# ============================================================================
# recap.sh — Project recap data gatherer
#
# This script collects raw project state (git history, file changes, TODOs,
# stack info) and prints it as structured output for Claude to synthesize.
#
# Claude reads the markers below to parse sections — it never shows this
# raw output to the user, only the synthesized recap.
#
# Usage: bash recap.sh <mode> [focus]
# Modes: quick | full | git | stack | onboard | files | todos
# ============================================================================

# $1 = mode (defaults to "quick" if not provided)
# $2 = optional focus keyword to filter results (e.g. "auth", "api")
MODE="${1:-quick}"
FOCUS="${2:-}"

# --- Exclusion lists ---------------------------------------------------------
# Used to skip irrelevant directories in find and grep calls.
# These are the most common generated/vendor dirs across JS, PHP, Python, etc.
EXCLUDE=(-not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/__pycache__/*' -not -path '*/.next/*' -not -path '*/storage/framework/*' -not -path '*/bootstrap/cache/*')
GREP_EXCLUDE="--exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ --exclude-dir=.next"

# File extensions considered "source code" — used to filter find and grep
# results so we don't show binary files, lock files, or generated assets.
SRC_EXT_FIND='\.(ts|js|tsx|jsx|php|py|rs|go|vue|svelte|rb|css|scss|blade\.php)$'
SRC_EXT_GREP='\.(ts|js|tsx|jsx|php|py|rs|go|vue|svelte|rb|css|scss|blade\.php):'

# --- Output helpers ----------------------------------------------------------
# Claude parses these markers to split the output into named sections.
# @MODE / @FOCUS / @KV are single-value metadata lines emitted at the top.
# ---@SECTION:<name> marks the start of a named data block.
# @FILE:<name> marks a file whose contents follow immediately after.
separator() { echo ""; echo "---@SECTION:$1"; }
kv()        { echo "@KV:$1=$2"; }

# --- Project detection -------------------------------------------------------

# Reads "name" from package.json or composer.json if present,
# otherwise falls back to the current directory name.
detect_project_name() {
  for manifest in package.json composer.json; do
    if [[ -f "$manifest" ]]; then
      local name
      name=$(python3 -c "import json; print(json.load(open('$manifest')).get('name',''))" 2>/dev/null)
      if [[ -n "$name" ]]; then echo "$name"; return; fi
    fi
  done
  basename "$(pwd)"
}

# Detects which language ecosystems are present by checking for
# well-known manifest/lockfiles. Multiple stacks can be active at once
# (e.g. a Laravel+Vue project will emit both "php" and "node").
detect_stack() {
  local stack=""
  [[ -f package.json ]]                          && stack="$stack node"
  [[ -f composer.json ]]                         && stack="$stack php"
  [[ -f Cargo.toml ]]                            && stack="$stack rust"
  [[ -f pyproject.toml || -f requirements.txt ]] && stack="$stack python"
  [[ -f go.mod ]]                                && stack="$stack go"
  [[ -f Gemfile ]]                               && stack="$stack ruby"
  echo "${stack:- unknown}"
}

# --- Git helpers -------------------------------------------------------------

# Current branch name, or "detached" if in detached HEAD state.
git_branch() { git branch --show-current 2>/dev/null || echo "detached"; }

# Last N commits as one-liners. If FOCUS is set, filters by commit message
# so you only see commits relevant to the area you're recapping.
git_recent_commits() {
  local count="${1:-5}"
  if [[ -n "$FOCUS" ]]; then
    git log --oneline -"$count" --grep="$FOCUS" 2>/dev/null || echo "No commits matching '$FOCUS'"
  else
    git log --oneline -"$count" 2>/dev/null || echo "Not a git repo"
  fi
}

# Short working tree status (M=modified, A=added, D=deleted, ??=untracked).
git_status_short()        { git status --short 2>/dev/null || echo "Not a git repo"; }

# Stat of unstaged changes (shows which files changed and by how many lines).
git_diff_stat()           { git diff --stat 2>/dev/null; }

# Stat of staged changes (what's queued for the next commit).
git_staged_stat()         { git diff --cached --stat 2>/dev/null; }

# Most recent commit as: <hash> <subject> (<relative time>)
git_last_commit_relative() { git log -1 --format="%h %s (%cr)" 2>/dev/null || echo "No commits"; }

# Shows how far ahead/behind the local branch is vs its remote tracking branch.
# Output format: ↓<behind> ↑<ahead> vs origin/main
git_tracking() {
  local upstream
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || { echo "no upstream"; return; }
  git rev-list --left-right --count "$upstream"...HEAD 2>/dev/null | awk '{print "↓"$1" ↑"$2" vs '$upstream'"}'
}

# --- Source file finders -----------------------------------------------------

# Lists recently modified source files, sorted newest first.
# Uses find's -printf to get modification timestamps for sorting.
# If FOCUS is set, restricts results to paths containing that keyword.
recent_source_files() {
  local count="${1:-15}"
  local cmd=(find . -type f "${EXCLUDE[@]}" -regextype posix-extended -regex ".*${SRC_EXT_FIND}")
  if [[ -n "$FOCUS" ]]; then
    cmd+=(-path "*${FOCUS}*")
  fi
  # %T@ = modification time as Unix timestamp (for sort)
  # %Tc = modification time as human-readable string (for display)
  # %p  = file path
  "${cmd[@]}" -printf '%T@ %Tc | %p\n' 2>/dev/null | sort -rn | head -"$count" | sed 's/^[0-9.]* //'
}

# Searches for TODO/FIXME/HACK/XXX/@todo across source files.
# If FOCUS is set, restricts to filenames matching that keyword.
find_todos() {
  local pattern='TODO\|FIXME\|HACK\|XXX\|@todo'
  if [[ -n "$FOCUS" ]]; then
    # shellcheck disable=SC2086
    grep -rn "$pattern" $GREP_EXCLUDE --include="*${FOCUS}*" . 2>/dev/null | head -50 || echo "None found"
  else
    # shellcheck disable=SC2086
    grep -rn "$pattern" $GREP_EXCLUDE . 2>/dev/null | grep -E "$SRC_EXT_GREP" | head -50 || echo "None found"
  fi
}

# Counts TODOs by type across the whole codebase and reports a summary line.
# Runs a single grep pass then counts variants from the in-memory result
# to avoid scanning the filesystem multiple times.
todo_counts() {
  # shellcheck disable=SC2086
  local results
  results=$(grep -rn 'TODO\|FIXME\|HACK\|XXX\|@todo' $GREP_EXCLUDE . 2>/dev/null | grep -E "$SRC_EXT_GREP" || true)
  if [[ -z "$results" ]]; then
    echo "0 TODOs, 0 FIXMEs, 0 HACKs across 0 files (0 total)"
    return
  fi
  local total todo fixme hack files
  total=$(echo "$results" | wc -l)
  todo=$(echo  "$results" | grep -ci 'TODO'     || true)
  fixme=$(echo "$results" | grep -ci 'FIXME'    || true)
  hack=$(echo  "$results" | grep -ci 'HACK\|XXX' || true)
  # Count unique files by extracting the part before the first colon
  files=$(echo "$results" | cut -d: -f1 | sort -u | wc -l)
  echo "${todo} TODOs, ${fixme} FIXMEs, ${hack} HACKs across ${files} files (${total} total)"
}

# Prints a 2-level directory tree. Falls back to a plain find listing if
# the `tree` binary isn't installed (common on minimal Linux environments).
project_tree() {
  tree -L 2 -I 'node_modules|vendor|.git|dist|build|__pycache__|.next|storage|bootstrap' --dirsfirst 2>/dev/null \
    || find . -maxdepth 2 -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' | head -40
}

# Extracts named scripts from package.json (npm/yarn) and composer.json,
# and lists Makefile targets if a Makefile is present.
manifest_scripts() {
  if [[ -f package.json ]]; then
    echo "@FILE:package.json scripts"
    python3 -c "
import json,sys
try:
  d=json.load(open('package.json'))
  for k,v in d.get('scripts',{}).items(): print(f'  {k}: {v}')
except: pass
" 2>/dev/null || echo "  (could not parse)"
  fi
  if [[ -f composer.json ]]; then
    echo "@FILE:composer.json scripts"
    python3 -c "
import json,sys
try:
  d=json.load(open('composer.json'))
  for k,v in d.get('scripts',{}).items():
    if isinstance(v,list): v='; '.join(v)
    print(f'  {k}: {v}')
except: pass
" 2>/dev/null || echo "  (could not parse)"
  fi
  # Extract lines that look like "target:" from Makefile
  [[ -f Makefile ]] && echo "@FILE:Makefile targets" && grep -E '^[a-zA-Z_-]+:' Makefile 2>/dev/null | head -10 | sed 's/^/  /'
}

# Lists top-15 dependencies from package.json and/or composer.json.
# Caps at 15 per section to avoid overwhelming Claude's context with lockfile noise.
manifest_deps() {
  if [[ -f package.json ]]; then
    echo "@FILE:package.json"
    python3 -c "
import json
try:
  d=json.load(open('package.json'))
  for section in ['dependencies','devDependencies']:
    deps=d.get(section,{})
    if deps:
      print(f'  {section}:')
      for k,v in list(deps.items())[:15]: print(f'    {k}: {v}')
      if len(deps)>15: print(f'    ... and {len(deps)-15} more')
except: pass
" 2>/dev/null
  fi
  if [[ -f composer.json ]]; then
    echo "@FILE:composer.json"
    python3 -c "
import json
try:
  d=json.load(open('composer.json'))
  for section in ['require','require-dev']:
    deps=d.get(section,{})
    if deps:
      print(f'  {section}:')
      for k,v in list(deps.items())[:15]: print(f'    {k}: {v}')
      if len(deps)>15: print(f'    ... and {len(deps)-15} more')
except: pass
" 2>/dev/null
  fi
}

# Checks for the presence of common config files and lists which ones exist.
# Covers env files, Docker, linters, TypeScript, bundlers, CI, and runtime
# version pins — anything that tells Claude how the project is configured.
config_files() {
  local found=0
  local configs=(.env .env.example .env.local docker-compose.yml docker-compose.yaml Dockerfile .dockerignore
    .eslintrc .eslintrc.js .eslintrc.json .prettierrc .prettierrc.js prettier.config.js
    tsconfig.json jsconfig.json vite.config.ts vite.config.js webpack.config.js
    .github/workflows tailwind.config.js tailwind.config.ts postcss.config.js
    phpunit.xml phpunit.xml.dist .php-cs-fixer.php .php-cs-fixer.dist.php
    .nvmrc .node-version .php-version .python-version .tool-versions
    jest.config.js jest.config.ts vitest.config.ts)
  for f in "${configs[@]}"; do
    if [[ -e "$f" ]]; then
      echo "  $f"
      found=1
    fi
  done
  [[ $found -eq 0 ]] && echo "  None found"
}

# Reads the first 50 lines of README.md — enough to capture the project
# description and setup instructions without dumping the whole file.
readme_content() {
  if [[ -f README.md ]]; then
    echo "@FILE:README.md"
    head -50 README.md
  else
    echo "No README.md found"
  fi
}

# Reads CLAUDE.md if present — this file contains project-specific
# instructions for Claude and is especially useful in onboard/full modes.
claude_md_content() {
  if [[ -f .claude/CLAUDE.md ]]; then
    echo "@FILE:.claude/CLAUDE.md"
    head -40 .claude/CLAUDE.md
  elif [[ -f CLAUDE.md ]]; then
    echo "@FILE:CLAUDE.md"
    head -40 CLAUDE.md
  fi
}

# Reads well-known task/roadmap files (TODO.md, TASKS.md, etc.) if present.
# These give Claude context about planned work beyond just git TODOs.
task_files() {
  local found=0
  for f in TODO.md TASKS.md .todo tasks.md ROADMAP.md; do
    if [[ -f "$f" ]]; then
      echo "@FILE:$f"
      head -30 "$f"
      echo ""
      found=1
    fi
  done
  if [[ $found -eq 0 ]]; then echo "None found"; fi
}

# ============================================================================
# Mode execution
#
# Each mode emits a different combination of sections. All modes start with
# the same three metadata lines so Claude always knows the project context.
# ============================================================================

# Emit top-level metadata — always present regardless of mode
echo "@MODE:$MODE"
echo "@FOCUS:${FOCUS:-none}"
kv "project" "$(detect_project_name)"
kv "stack"   "$(detect_stack)"

case "$MODE" in

  # quick — default mode. Focused entirely on git state so Claude can infer
  # what you were working on from branch name, recent commits, and diffs.
  quick)
    separator "branch"
    git_branch
    separator "last_commit"
    git_last_commit_relative
    separator "recent_commits"
    git_recent_commits 5
    separator "status"
    git_status_short
    separator "diff_stat"
    git_diff_stat
    separator "staged_stat"
    git_staged_stat
    ;;

  # full — everything in quick, plus project structure, README, scripts,
  # config files, and a sample of TODOs for broader context.
  full)
    separator "branch"
    git_branch
    separator "last_commit"
    git_last_commit_relative
    separator "tracking"
    git_tracking
    separator "recent_commits"
    git_recent_commits 7
    separator "status"
    git_status_short
    separator "diff_stat"
    git_diff_stat
    separator "staged_stat"
    git_staged_stat
    separator "stashes"
    git stash list 2>/dev/null || echo "None"
    separator "readme"
    readme_content
    separator "claude_md"
    claude_md_content
    separator "tree"
    project_tree
    separator "scripts"
    manifest_scripts
    separator "config_files"
    config_files
    separator "recent_todos"
    find_todos | head -20
    ;;

  # git — deep dive into git state only. Useful when you need to understand
  # branch history, stashes, and all remote branches at a glance.
  git)
    separator "branch"
    git_branch
    separator "last_commit"
    git_last_commit_relative
    separator "tracking"
    git_tracking
    separator "recent_commits"
    git_recent_commits 10
    separator "status"
    git_status_short
    separator "diff_stat"
    git_diff_stat
    separator "staged_stat"
    git_staged_stat
    separator "stashes"
    git stash list 2>/dev/null || echo "None"
    separator "branches"
    # Lists all branches sorted by most recent commit, with relative timestamps
    git branch -a --sort=-committerdate --format='%(refname:short) (%(committerdate:relative))' 2>/dev/null | head -15
    ;;

  # stack — focused on what the project is built with. No git info.
  # Useful when starting work on an unfamiliar codebase.
  stack)
    separator "deps"
    manifest_deps
    separator "scripts"
    manifest_scripts
    separator "config_files"
    config_files
    separator "runtime"
    # Check for runtime version pins (.nvmrc, .tool-versions, etc.)
    _found_runtime=0
    for f in .nvmrc .node-version .php-version .python-version .tool-versions; do
      if [[ -f "$f" ]]; then echo "$f: $(cat "$f")"; _found_runtime=1; fi
    done
    [[ $_found_runtime -eq 0 ]] && echo "None detected"
    ;;

  # onboard — tailored for someone new to the project. Prioritizes README,
  # CLAUDE.md, structure, and setup info over git history.
  onboard)
    separator "readme"
    readme_content
    separator "claude_md"
    claude_md_content
    separator "tree"
    project_tree
    separator "deps"
    manifest_deps
    separator "scripts"
    manifest_scripts
    separator "config_files"
    config_files
    ;;

  # files — shows which source files changed recently and their git status.
  # Useful for picking up where you left off after a context switch.
  files)
    separator "recent_files"
    recent_source_files 15
    separator "status"
    git_status_short
    separator "diff_stat"
    git_diff_stat
    ;;

  # todos — full TODO/FIXME/HACK scan plus task files.
  # Useful for triaging technical debt or planning the next work session.
  todos)
    separator "todos"
    find_todos
    separator "todo_counts"
    todo_counts
    separator "task_files"
    task_files
    ;;

  *)
    echo "Unknown mode: $MODE"
    echo "Available: quick | full | git | stack | onboard | files | todos"
    exit 1
    ;;
esac
