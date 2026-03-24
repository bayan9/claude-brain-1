#!/usr/bin/env bash
# merge-structured.sh — Deterministic JSON merge for structured brain data
# Merges settings, keybindings, MCP servers, skills, agents, rules
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BASE="$1"    # Base/consolidated brain JSON
OTHER="$2"   # Other machine's brain JSON
OUTPUT="$3"  # Output path for merged brain

if [ ! -f "$BASE" ] || [ ! -f "$OTHER" ]; then
  log_error "Input files not found."
  exit 1
fi


# Create a comprehensive merge using jq
jq -s '
def deep_merge:
  # Recursively merge two objects
  # Arrays are unioned (deduplicated), objects are recursively merged
  if (.[0] | type) == "object" and (.[1] | type) == "object" then
    .[0] as $a | .[1] as $b |
    ($a | keys) + ($b | keys) | unique | map(
      . as $key |
      if ($a | has($key)) and ($b | has($key)) then
        {($key): ([$a[$key], $b[$key]] | deep_merge)}
      elif ($a | has($key)) then
        {($key): $a[$key]}
      else
        {($key): $b[$key]}
      end
    ) | add // {}
  elif (.[0] | type) == "array" and (.[1] | type) == "array" then
    (.[0] + .[1]) | unique
  else
    # For scalar conflicts, prefer the second (other/newer)
    .[1] // .[0]
  end;

.[0] as $base | .[1] as $other |

# Collect deletions from both machines (backward compatible: default to empty)
($base.deletions // {}) as $base_del |
($other.deletions // {}) as $other_del |

# Helper: remove deleted keys from a merged object
def apply_deletions($dels; $section):
  ($dels[$section] // []) as $to_remove |
  if ($to_remove | length) > 0 then
    [to_entries[] | select(.key as $k | $to_remove | index($k) | not)] | from_entries
  else . end;

# Merge declarative: CLAUDE.md kept from base (semantic merge handles this)
# Merge declarative: rules (union by filename, minus deletions)
($base.declarative.rules // {}) as $base_rules |
($other.declarative.rules // {}) as $other_rules |
(($base_rules * $other_rules) | apply_deletions($base_del; "declarative.rules") | apply_deletions($other_del; "declarative.rules")) as $merged_rules |

# Merge procedural: skills (union by name, minus deletions)
($base.procedural.skills // {}) as $base_skills |
($other.procedural.skills // {}) as $other_skills |
(([$base_skills, $other_skills] | add // {}) | apply_deletions($base_del; "procedural.skills") | apply_deletions($other_del; "procedural.skills")) as $merged_skills |

# Merge procedural: agents (union by name, minus deletions)
($base.procedural.agents // {}) as $base_agents |
($other.procedural.agents // {}) as $other_agents |
(([$base_agents, $other_agents] | add // {}) | apply_deletions($base_del; "procedural.agents") | apply_deletions($other_del; "procedural.agents")) as $merged_agents |

# Merge procedural: output_styles (union)
($base.procedural.output_styles // {}) as $base_styles |
($other.procedural.output_styles // {}) as $other_styles |
([$base_styles, $other_styles] | add // {}) as $merged_styles |

# Merge environmental: settings (deep merge, arrays deduped)
($base.environmental.settings.content // {}) as $base_settings |
($other.environmental.settings.content // {}) as $other_settings |
([$base_settings, $other_settings] | deep_merge) as $merged_settings |

# Merge environmental: keybindings (deep merge)
($base.environmental.keybindings.content // {}) as $base_kb |
($other.environmental.keybindings.content // {}) as $other_kb |
([$base_kb, $other_kb] | deep_merge) as $merged_kb |

# Merge environmental: MCP servers (union by name)
($base.environmental.mcp_servers // {}) as $base_mcp |
($other.environmental.mcp_servers // {}) as $other_mcp |
($base_mcp * $other_mcp) as $merged_mcp |

# Merge experiential: auto_memory (union projects, within project keep base for semantic merge)
($base.experiential.auto_memory // {}) as $base_mem |
($other.experiential.auto_memory // {}) as $other_mem |
([$base_mem, $other_mem] | add // {}) as $merged_mem |

# Merge experiential: agent_memory (union agents, keep base content for semantic merge)
($base.experiential.agent_memory // {}) as $base_amem |
($other.experiential.agent_memory // {}) as $other_amem |
([$base_amem, $other_amem] | add // {}) as $merged_amem |

# Combine deletions from both machines
([$base_del, $other_del] | add // {}) as $merged_del |

# Assemble merged brain (explicit construction, not $base * {...} to avoid deep merge reintroducing deleted keys)
{
  schema_version: $base.schema_version,
  exported_at: $base.exported_at,
  machine: $base.machine,
  deletions: $merged_del,
  declarative: {
    claude_md: $base.declarative.claude_md,
    rules: $merged_rules
  },
  procedural: {
    skills: $merged_skills,
    agents: $merged_agents,
    output_styles: $merged_styles
  },
  experiential: {
    auto_memory: $merged_mem,
    agent_memory: $merged_amem
  },
  environmental: {
    settings: { content: $merged_settings, hash: "merged" },
    keybindings: { content: $merged_kb, hash: "merged" },
    mcp_servers: $merged_mcp
  },
  shared: {
    skills: (($base.shared.skills // {}) * ($other.shared.skills // {})),
    agents: (($base.shared.agents // {}) * ($other.shared.agents // {})),
    rules: (($base.shared.rules // {}) * ($other.shared.rules // {}))
  }
}
' "$BASE" "$OTHER" > "$OUTPUT"

log_info "Structured merge complete."
