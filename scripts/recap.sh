#!/usr/bin/env bash
set -uo pipefail

# ============================================================================
# recap.sh — Project recap data gatherer
# Usage: bash .claude/commands/recap.sh <mode> [focus]
# Modes: quick | full | git | stack | onboard | files | todos
# ============================================================================

MODE="${1:-quick}"
FOCUS="${2:-}"

# --- Excluded dirs for find/grep ---
EXCLUDE=(-not -path '*/node_modules/*' -not -path '*/vendor/*' -not -path '*/.git/*' -not -path '*/dist/*' -not -path '*/build/*' -not -path '*/__pycache__/*' -not -path '*/.next/*' -not -path '*/storage/framework/*' -not -path '*/bootstrap/cache/*')
GREP_EXCLUDE="--exclude-dir=node_modules --exclude-dir=vendor --exclude-dir=.git --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ --exclude-dir=.next"
SRC_EXT_FIND='\.(ts|js|tsx|jsx|php|py|rs|go|vue|svelte|rb|css|scss|blade\.php)$'
SRC_EXT_GREP='\.(ts|js|tsx|jsx|php|py|rs|go|vue|svelte|rb|css|scss|blade\.php):'

# --- Helpers ---
separator() { echo ""; echo "---@SECTION:$1"; }
kv() { echo "@KV:$1=$2"; }

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

detect_stack() {
  local stack=""
  [[ -f package.json ]] && stack="$stack node"
  [[ -f composer.json ]] && stack="$stack php"
  [[ -f Cargo.toml ]] && stack="$stack rust"
  [[ -f pyproject.toml || -f requirements.txt ]] && stack="$stack python"
  [[ -f go.mod ]] && stack="$stack go"
  [[ -f Gemfile ]] && stack="$stack ruby"
  echo "${stack:- unknown}"
}

# --- Git helpers ---
git_branch() { git branch --show-current 2>/dev/null || echo "detached"; }
git_recent_commits() {
  local count="${1:-5}"
  if [[ -n "$FOCUS" ]]; then
    git log --oneline -"$count" --grep="$FOCUS" 2>/dev/null || echo "No commits matching '$FOCUS'"
  else
    git log --oneline -"$count" 2>/dev/null || echo "Not a git repo"
  fi
}
git_status_short() { git status --short 2>/dev/null || echo "Not a git repo"; }
git_diff_stat() { git diff --stat 2>/dev/null; }
git_staged_stat() { git diff --cached --stat 2>/dev/null; }
git_last_commit_relative() { git log -1 --format="%h %s (%cr)" 2>/dev/null || echo "No commits"; }
git_tracking() {
  local upstream
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || { echo "no upstream"; return; }
  git rev-list --left-right --count "$upstream"...HEAD 2>/dev/null | awk '{print "↓"$1" ↑"$2" vs '$upstream'"}'
}

# --- Source file finders ---
recent_source_files() {
  local count="${1:-15}"
  local cmd=(find . -type f "${EXCLUDE[@]}" -regextype posix-extended -regex ".*${SRC_EXT_FIND}")
  if [[ -n "$FOCUS" ]]; then
    cmd+=(-path "*${FOCUS}*")
  fi
  "${cmd[@]}" -printf '%T@ %Tc | %p\n' 2>/dev/null | sort -rn | head -"$count" | sed 's/^[0-9.]* //'
}

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
  todo=$(echo "$results" | grep -ci 'TODO' || true)
  fixme=$(echo "$results" | grep -ci 'FIXME' || true)
  hack=$(echo "$results" | grep -ci 'HACK\|XXX' || true)
  files=$(echo "$results" | cut -d: -f1 | sort -u | wc -l)
  echo "${todo} TODOs, ${fixme} FIXMEs, ${hack} HACKs across ${files} files (${total} total)"
}

project_tree() { tree -L 2 -I 'node_modules|vendor|.git|dist|build|__pycache__|.next|storage|bootstrap' --dirsfirst 2>/dev/null || find . -maxdepth 2 -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/vendor/*' | head -40; }

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
  [[ -f Makefile ]] && echo "@FILE:Makefile targets" && grep -E '^[a-zA-Z_-]+:' Makefile 2>/dev/null | head -10 | sed 's/^/  /'
}

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

readme_content() {
  if [[ -f README.md ]]; then
    echo "@FILE:README.md"
    head -50 README.md
  else
    echo "No README.md found"
  fi
}

claude_md_content() {
  if [[ -f .claude/CLAUDE.md ]]; then
    echo "@FILE:.claude/CLAUDE.md"
    head -40 .claude/CLAUDE.md
  elif [[ -f CLAUDE.md ]]; then
    echo "@FILE:CLAUDE.md"
    head -40 CLAUDE.md
  fi
}

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
# ============================================================================

echo "@MODE:$MODE"
echo "@FOCUS:${FOCUS:-none}"
kv "project" "$(detect_project_name)"
kv "stack" "$(detect_stack)"

case "$MODE" in

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
    git branch -a --sort=-committerdate --format='%(refname:short) (%(committerdate:relative))' 2>/dev/null | head -15
    ;;

  stack)
    separator "deps"
    manifest_deps
    separator "scripts"
    manifest_scripts
    separator "config_files"
    config_files
    separator "runtime"
    _found_runtime=0
    for f in .nvmrc .node-version .php-version .python-version .tool-versions; do
      if [[ -f "$f" ]]; then echo "$f: $(cat "$f")"; _found_runtime=1; fi
    done
    [[ $_found_runtime -eq 0 ]] && echo "None detected"
    ;;

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

  files)
    separator "recent_files"
    recent_source_files 15
    separator "status"
    git_status_short
    separator "diff_stat"
    git_diff_stat
    ;;

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
