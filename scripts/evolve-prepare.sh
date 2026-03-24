#!/usr/bin/env bash
# evolve-prepare.sh — Gather brain context for evolution analysis (NO LLM call)
#
# Extracts all memory, CLAUDE.md, rules, skills from consolidated brain
# and writes a JSON context file that the /brain-evolve skill can use
# to run the analysis in the current Claude session.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

OUTPUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

load_config

# ── Gather context ────────────────────────────────────────────────────────────
brain_file="${BRAIN_REPO}/consolidated/brain.json"
if [ ! -f "$brain_file" ]; then
  log_error "No consolidated brain found. Run /brain-sync first."
  exit 1
fi

# Extract all memory content
all_memory=$(jq -r '
  [.experiential.auto_memory // {} | to_entries[] |
   "## Project: \(.key)\n\(.value | to_entries[] | "### \(.key)\n\(.value.content // "")")"] |
  join("\n\n")
' "$brain_file")

# Extract current CLAUDE.md
current_claude_md=$(jq -r '.declarative.claude_md.content // ""' "$brain_file")

# Extract current rules
current_rules=$(jq -r '
  [.declarative.rules // {} | to_entries[] |
   "### \(.key)\n\(.value.content // "")"] |
  join("\n\n")
' "$brain_file")

# Extract current skills
current_skills=$(jq -r '
  [.procedural.skills // {} | keys[] ] | join(", ")
' "$brain_file")

# Machine count
machine_count=1
if [ -f "${BRAIN_REPO}/meta/machines.json" ]; then
  machine_count=$(jq '.machines | length' "${BRAIN_REPO}/meta/machines.json")
fi

# ── Build prompt from template ────────────────────────────────────────────────
TEMPLATE=""
if [ -f "${PLUGIN_ROOT:-${SCRIPT_DIR}/..}/templates/evolve-prompt.md" ]; then
  TEMPLATE=$(cat "${PLUGIN_ROOT:-${SCRIPT_DIR}/..}/templates/evolve-prompt.md")
else
  TEMPLATE="Analyze the brain memory below for patterns worth promoting to CLAUDE.md, rules, or skills. Flag stale entries."
fi

PROMPT="${TEMPLATE}

## Current CLAUDE.md:
\`\`\`
${current_claude_md}
\`\`\`

## Current Rules:
\`\`\`
${current_rules}
\`\`\`

## Current Skills: ${current_skills}

## Machines in network: ${machine_count}

## All Memory Content:
\`\`\`
${all_memory}
\`\`\`"

# ── Output context as JSON ────────────────────────────────────────────────────
context=$(jq -n \
  --arg claude_md "$current_claude_md" \
  --arg memory "$all_memory" \
  --arg rules "$current_rules" \
  --arg skills "$current_skills" \
  --argjson machines "$machine_count" \
  --arg prompt "$PROMPT" \
  --arg ts "$(now_iso)" \
  '{
    prepared_at: $ts,
    current_claude_md: $claude_md,
    all_memory: $memory,
    current_rules: $rules,
    current_skills: $skills,
    machine_count: $machines,
    evolve_prompt: $prompt
  }')

if [ -n "$OUTPUT" ]; then
  echo "$context" > "$OUTPUT"
  log_info "Evolution context prepared at $OUTPUT"
else
  echo "$context"
fi
