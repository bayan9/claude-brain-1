# claude-brain

**Your Claude Code brain follows you everywhere.**

Sync and evolve your Claude Code brain across machines — memory, skills, agents, rules, settings — all of it, intelligently merged.

## How is this different?

| Tool | What it does | What claude-brain adds |
|------|-------------|----------------------|
| **claude-mem** | Enhances memory within a single machine | Syncs your *entire brain* across all machines |
| **chezmoi / dotfiles** | Copies config files | Intelligently *merges* accumulated knowledge — resolves contradictions, deduplicates |
| **Manual MEMORY.md copy** | Works but loses automatic management | Syncs silently on every session start/end, zero daily effort |

No other tool does cross-machine semantic merge of Claude Code's brain state.

## Security Notice

**Read this before using claude-brain.** This plugin syncs your Claude Code configuration and accumulated knowledge via a Git remote. Understand what data leaves your machine:

### What IS exported to the Git remote

- **CLAUDE.md, rules, skills, agents** — your instructions and workflows
- **Auto memory and agent memory** — patterns Claude learned from your sessions
- **Settings** — hooks, permissions, preferences (NOT env vars)
- **MCP server configurations** — command and args only (env vars containing API keys are **stripped**)
- **Keybindings** — your keyboard shortcuts
- **Machine hostname and project directory names** — used for merge tracking

### What is NEVER exported

- OAuth tokens and API keys
- `~/.claude.json` (internal state, credentials)
- Environment variables from settings
- MCP server `env` fields (may contain API keys/tokens)
- `.local` config files (settings.local.json, CLAUDE.local.md)
- Session transcripts

### Important security considerations

1. **Use a PRIVATE Git repository.** Your brain data is stored in plaintext. The plugin warns if it detects a public repo, but you are responsible for repo visibility.
2. **Memory may contain sensitive context.** Claude stores information from your sessions in memory files. Review `~/.claude/projects/*/memory/` before initializing. The export runs a pattern-based secret scan and warns if potential API keys or tokens are found, but this is not exhaustive.
3. **Git history is permanent.** Even if you later remove sensitive data from memory, it persists in Git history. Consider `git-filter-repo` or BFG Repo Cleaner if you need to purge history.
4. **Auto-sync runs silently.** On every Claude Code session start/end, your brain is automatically pushed/pulled. The plugin creates backups before each import.
5. **Semantic merge sends memory to Claude API.** When merging brains from multiple machines, memory content is sent to `claude -p` for intelligent deduplication. This is the same API your Claude Code sessions use.
6. **Trust all machines in your network.** Imported skills, agents, and rules execute with Claude's permissions. A compromised machine could inject malicious instructions. Only add machines you fully control.
7. **Backups are created automatically.** Before each import, a backup is saved to `~/.claude/brain-backups/`. Use `/brain-status` to check, and restore manually if needed.

## What It Does

Claude Code accumulates knowledge over time: auto-memory, custom agents, skills, rules, settings, and CLAUDE.md instructions. This plugin makes that knowledge portable across all your machines.

- **Export** your brain state to a portable format
- **Sync** brains across machines via Git (no central server)
- **Merge** intelligently: deterministic for structured data, LLM-powered for unstructured knowledge
- **Evolve** by promoting stable patterns from memory to durable configuration
- **Auto-sync** on every Claude Code session start/end via hooks

## Quick Start

### First machine (initialize)

```
/brain-init git@github.com:you/my-brain.git
```

### Other machines (join)

```
/brain-join git@github.com:you/my-brain.git
```

### That's it

Hooks auto-sync on every session start/end. Your brain follows you.

## See it in action

```bash
# Machine A (work laptop)
$ claude
> /brain-init git@github.com:you/my-brain.git
✓ Brain exported: 42 memory entries, 3 skills, 5 rules
✓ Pushed to remote

# Machine B (home desktop)
$ claude
> /brain-join git@github.com:you/my-brain.git
✓ Pulled brain: 42 memory entries, 3 skills, 5 rules
✓ Merged with local state
✓ Auto-sync enabled

# Later, on Machine B...
# Claude learns new patterns, you create a skill
# Session ends → auto-push

# Next day, Machine A...
# Session starts → auto-pull
# All of Machine B's learnings are now here
```

## Commands

| Command | Description |
|---------|-------------|
| `/brain-init <remote>` | Initialize brain network with a Git remote |
| `/brain-join <remote>` | Join an existing brain network |
| `/brain-status` | Show brain inventory and sync status |
| `/brain-sync` | Manually trigger full sync cycle |
| `/brain-evolve` | Promote stable patterns from memory |
| `/brain-conflicts` | Review and resolve merge conflicts |
| `/brain-share <type> <name>` | Share a skill, agent, or rule with the team |
| `/brain-shared-list` | List all shared artifacts in the network |
| `/brain-log` | Show sync history |

## How It Works

### Sync Model

Each machine pushes brain snapshots to a shared Git repo. When a machine pulls, it merges all snapshots:

- **Structured data** (settings, keybindings, MCP servers): Deterministic JSON deep-merge
- **Unstructured data** (memory, CLAUDE.md): LLM-powered semantic merge via `claude -p`

### What Gets Synced

| Component | Synced? | Strategy |
|-----------|---------|----------|
| CLAUDE.md | Yes | Semantic merge |
| Rules | Yes | Union by filename |
| Skills | Yes | Union by name |
| Agents | Yes | Union by name |
| Auto memory | Yes | Semantic merge |
| Agent memory | Yes | Semantic merge |
| Settings (hooks, permissions) | Yes | Deep merge (env vars excluded) |
| Keybindings | Yes | Union |
| MCP servers | Yes | Union, paths rewritten, env vars stripped |
| Shared skills/agents/rules | Yes | Union via shared namespace |
| OAuth tokens | Never | Security |
| Env vars | Never | Machine-specific |
| MCP server env fields | Never | May contain API keys |

## API Usage & Costs

claude-brain uses `claude -p` (Sonnet) for semantic merges. Here's what costs money and what doesn't:

| Operation | API Cost | When |
|-----------|----------|------|
| Structured merge (settings, keybindings, MCP) | **Free** | Every sync |
| Semantic merge (memory, CLAUDE.md) | ~$0.01–0.05 | Only when content differs across machines |
| Auto-evolve | ~$0.02–0.10 | At most once per 7 days |
| Export / import | **Free** | Every sync |

- **Budget cap**: $0.50 per merge call (configurable in `defaults.json`)
- **Fallback**: If `claude -p` fails, content is concatenated with markers — no data loss, no cost
- **Typical monthly cost**: $0.50–2.00 for active multi-machine use

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Linux | ✅ Fully supported | Primary development target |
| macOS | ✅ Fully supported | Tested on Apple Silicon and Intel |
| WSL | ✅ Fully supported | WSL2 recommended; auto-detected with path handling |
| Windows native | ❌ Not supported | Use WSL instead |

## Encryption

Brain snapshots can be encrypted at rest using [age](https://github.com/FiloSottile/age).

### Enable on init
```
/brain-init git@github.com:you/my-brain.git --encrypt
```

### How it works
- Generates an `age` keypair per machine
- Snapshots are encrypted before pushing to Git
- Decrypted on pull using your machine's private key
- Recipients file in `meta/recipients.txt` controls who can decrypt
- Backward compatible: unencrypted snapshots are handled transparently

### Adding a new machine to an encrypted network
When you `/brain-join` an encrypted network, the plugin guides you through keypair generation. The network owner must add your public key to `meta/recipients.txt`.

### Install age
- macOS: `brew install age`
- Ubuntu/Debian: `apt install age`
- Other: https://github.com/FiloSottile/age

## Team Sharing

Share skills, agents, and rules with teammates via the shared namespace:

```
/brain-share skill my-useful-tool.md
/brain-share agent debugger.md
/brain-share rule security.md
```

Shared artifacts live in `shared/skills/`, `shared/agents/`, `shared/rules/` in the brain repo. Memory is **never** shared (personal only). Team members receive shared artifacts on their next sync.

## Auto-Evolve

The brain automatically runs evolution analysis every 7 days (configurable via `evolve_interval_days` in `defaults.json`). During auto-evolve:

- High-confidence promotions (>0.9) are applied automatically
- Lower-confidence suggestions are queued as conflicts for manual review via `/brain-conflicts`
- The timer resets after each evolution run

You can always trigger manually with `/brain-evolve`.

## Dependencies

- `git` (for sync transport)
- `jq` (for JSON processing — install: `apt install jq` / `brew install jq` / `pacman -S jq`)
- `claude` CLI (for semantic merge — already installed if you have Claude Code)
- `age` (optional, for encryption)

## Architecture

```
Machine A              Machine B              Machine C
┌──────────┐          ┌──────────┐          ┌──────────┐
│ claude-   │          │ claude-   │          │ claude-   │
│ brain     │          │ brain     │          │ brain     │
│ plugin    │          │ plugin    │          │ plugin    │
└─────┬─────┘          └─────┬─────┘          └─────┬─────┘
      │                      │                      │
      └──────────┬───────────┴──────────┬───────────┘
                 │     Git Remote       │
                 │  (user's private     │
                 │       repo)          │
                 └──────────────────────┘
```

No central server. Each machine merges on pull. Git handles transport.

## Installation

### From marketplace (when available)

```
/plugin marketplace add toroleapinc/claude-brain
/plugin install claude-brain
```

### Local development

```
claude --plugin-dir ./claude-brain
```

## Export flags

| Flag | Description |
|------|-------------|
| `--skip-secret-scan` | Suppress the automatic secret pattern scan on export |
| `--quiet` | Suppress informational output |

## Recommended CLAUDE.md Addition

Once brain sync is active, add this to your project's `CLAUDE.md` so Claude Code is aware:

```markdown
# Brain Sync
This machine syncs brain state via claude-brain plugin. Do not modify ~/.claude/brain-repo/ directly.
```

## License

MIT
