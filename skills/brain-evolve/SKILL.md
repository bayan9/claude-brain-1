---
name: brain-evolve
description: Analyze accumulated brain memory and propose promotions to CLAUDE.md, rules, or new skills. Makes your brain smarter over time.
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

The user wants to evolve their brain by promoting stable patterns from memory.

## Steps

1. Prepare the evolution context (this does NOT call claude -p, works inside active sessions):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve-prepare.sh" --output ~/.claude/brain-repo/meta/evolve-context.json
   ```

2. Read the prepared context:
   ```bash
   cat ~/.claude/brain-repo/meta/evolve-context.json
   ```

3. Using the `evolve_prompt` field from the context, **analyze the brain yourself** (you ARE the LLM — no need to shell out to `claude -p`). Look for:

   **Promotions to CLAUDE.md:** Coding standards, tool preferences, workflow rules that appear consistently across projects.

   **Promotions to Rules:** Path-specific or language-specific patterns.

   **New Skills:** Repeated multi-step workflows that could be templated.

   **Stale entries:** Notes about tools/versions that are outdated, or observations contradicted by newer entries.

   Apply criteria: pattern in 2+ projects OR explicitly stated as universal, not already in CLAUDE.md/rules, actionable and specific.

4. For each recommendation, present it to the user:

   **For claude_md promotions:**
   - Show the proposed addition and reason
   - Ask: Accept / Skip / Edit first
   - If accepted, append to ~/.claude/CLAUDE.md

   **For rule promotions:**
   - Show the proposed rule content and reason
   - Ask: Accept / Skip / Edit first
   - If accepted, write to ~/.claude/rules/<appropriate-name>.md

   **For skill suggestions:**
   - Show the proposed skill and reason
   - Ask: Accept / Skip / Edit first
   - If accepted, create in ~/.claude/skills/<name>/SKILL.md

5. For each stale entry, ask:
   - Archive (remove from memory) / Keep
   - If archived, note in the memory file that it was archived

6. Save results:
   ```bash
   # Write results for audit trail
   cat > ~/.claude/brain-repo/meta/last-evolve.json << 'EVOLVE_EOF'
   {your JSON results here with promotions, stale_entries, summary}
   EVOLVE_EOF
   ```

7. After all changes are applied:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/push.sh"
   ```

8. Show summary: "Brain evolved: X promotions accepted, Y stale entries archived."

## Important
- The old `evolve.sh` called `claude -p` which cannot run inside an active Claude session.
- This skill uses `evolve-prepare.sh` (data gathering only) + your own analysis (no nested claude call needed).
- Follow the autoresearch pattern: propose → user approves → apply. Never auto-apply.
