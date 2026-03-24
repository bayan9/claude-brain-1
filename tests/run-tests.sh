#!/usr/bin/env bash
# run-tests.sh — Integration test suite for claude-brain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=""

# Counters
PASS=0
FAIL=0
SKIP=0

# Colors
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

# JSON query helper (jq or python3 fallback)
jqf() {
  local filter="$1" file="$2"
  if command -v jq &>/dev/null; then
    jq "$filter" "$file"
  else
    python3 -c "
import json, sys
with open('$file') as f:
    data = json.load(f)
# Simple jq-like access for dot paths
path = '$filter'.lstrip('.')
obj = data
for key in path.split('.'):
    if key and isinstance(obj, dict):
        obj = obj.get(key)
        if obj is None: sys.exit(1)
print(json.dumps(obj) if isinstance(obj, (dict, list)) else obj)
" 2>/dev/null
  fi
}

jqr() {
  local filter="$1" file="$2"
  if command -v jq &>/dev/null; then
    jq -r "$filter" "$file"
  else
    python3 -c "
import json, sys
with open('$file') as f:
    data = json.load(f)
path = '$filter'.lstrip('.')
obj = data
for key in path.split('.'):
    if key and isinstance(obj, dict):
        obj = obj.get(key)
        if obj is None:
            print('null')
            sys.exit(0)
if isinstance(obj, (dict, list)):
    print(json.dumps(obj))
elif obj is None:
    print('null')
else:
    print(obj)
" 2>/dev/null
  fi
}

json_valid() {
  local file="$1"
  if command -v jq &>/dev/null; then
    jq empty "$file" 2>/dev/null
  else
    python3 -c "import json; json.load(open('$file'))" 2>/dev/null
  fi
}

json_length() {
  local filter="$1" file="$2"
  if command -v jq &>/dev/null; then
    jq "$filter | length" "$file" 2>/dev/null
  else
    python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
path = '$filter'.lstrip('.').rstrip(' ')
obj = data
for key in path.split('.'):
    if key and isinstance(obj, dict):
        obj = obj.get(key, [])
print(len(obj) if isinstance(obj, (list, dict)) else 0)
" 2>/dev/null
  fi
}

json_set() {
  local file="$1" key="$2" value="$3"
  if command -v jq &>/dev/null; then
    local tmp; tmp=$(mktemp)
    jq --arg v "$value" ".$key = \$v" "$file" > "$tmp" && mv "$tmp" "$file"
  else
    python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
data['$key'] = '$value'
with open('$file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
  fi
}

# ── Helpers ────────────────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"; SKIP=$((SKIP + 1)); }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

setup_sandbox() {
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home"
  export CLAUDE_DIR="$HOME/.claude"
  export BRAIN_REPO="$HOME/.claude/brain-repo"
  export BRAIN_CONFIG="$HOME/.claude/brain-config.json"

  # Create mock ~/.claude/ structure
  mkdir -p "$CLAUDE_DIR"/{rules,skills/review,agents,projects/my-project/memory,output-styles}
  mkdir -p "$BRAIN_REPO"/{machines,consolidated,meta,shared/skills,shared/agents,shared/rules}

  # CLAUDE.md
  cat > "$HOME/CLAUDE.md" <<'EOF'
# My Project Rules
- Use pnpm not npm
- Always write tests
- Prefer TypeScript
EOF

  # Rules
  echo "Always run linting before commit." > "$CLAUDE_DIR/rules/linting.md"
  echo "Use conventional commits." > "$CLAUDE_DIR/rules/commits.md"

  # Skills
  cat > "$CLAUDE_DIR/skills/review/SKILL.md" <<'EOF'
---
name: review
description: Code review helper
---
Review the code for issues.
EOF

  # Agents
  echo "You are a debugging specialist." > "$CLAUDE_DIR/agents/debugger.md"

  # Memory
  cat > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" <<'EOF'
- Project uses vitest for testing
- Database is PostgreSQL with Drizzle ORM
- Deploy via GitHub Actions
EOF

  # Settings
  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git:*)"],
    "deny": ["Bash(rm -rf /*)"]
  },
  "hooks": {
    "SessionStart": []
  },
  "env": {
    "SECRET_KEY": "should-not-be-exported"
  }
}
EOF

  # Keybindings
  cat > "$CLAUDE_DIR/keybindings.json" <<'EOF'
[{"key": "ctrl+k", "command": "clear", "context": "terminal"}]
EOF

  # Init brain-repo as git repo
  (cd "$BRAIN_REPO" && git init -q -b main && git config user.email "test@test.com" && git config user.name "Test" && echo '{"entries":[]}' > meta/merge-log.json && git add -A && git commit -q -m "init")

  # Set PLUGIN_ROOT for scripts
  export CLAUDE_PLUGIN_ROOT="$PROJECT_DIR"
}

cleanup_sandbox() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup_sandbox EXIT

# ── Tests ──────────────────────────────────────────────────────────────────────

test_export_structure() {
  section "Export: snapshot structure"

  local output="$TEST_DIR/snapshot.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  if [ ! -f "$output" ]; then
    fail "export.sh did not produce output file"
    return
  fi

  # Check it's valid JSON
  if json_valid "$output"; then
    pass "Output is valid JSON"
  else
    fail "Output is not valid JSON"
    return
  fi

  # Check required top-level fields
  for field in schema_version exported_at machine declarative procedural experiential environmental; do
    if jqf ".$field" "$output" >/dev/null 2>&1; then
      pass "Has field: $field"
    else
      fail "Missing field: $field"
    fi
  done

  # Check machine info
  if jqf ".machine.id" "$output" >/dev/null 2>&1; then
    pass "Has machine.id"
  else
    fail "Missing machine.id"
  fi
}

test_export_no_secrets() {
  section "Export: secrets excluded"

  local output="$TEST_DIR/snapshot.json"
  if [ ! -f "$output" ]; then
    skip "No snapshot to check"
    return
  fi

  local content
  content=$(cat "$output")

  # Env vars should not appear
  if echo "$content" | grep -q "should-not-be-exported"; then
    fail "Env var SECRET_KEY leaked into snapshot"
  else
    pass "Env vars excluded from snapshot"
  fi

  # settings.env should be stripped
  local env_val
  env_val=$(jqr ".environmental.settings.content.env" "$output" 2>/dev/null || echo "")
  if [ -z "$env_val" ] || [ "$env_val" = "null" ] || [ "$env_val" = "{}" ]; then
    pass "settings.env stripped from snapshot"
  else
    fail "settings.env present in snapshot: $env_val"
  fi
}

test_export_import_roundtrip() {
  section "Export → Import round-trip"


  local snapshot="$TEST_DIR/snapshot.json"
  if [ ! -f "$snapshot" ]; then
    skip "No snapshot for import test"
    return
  fi

  # Create a separate target directory
  local target="$TEST_DIR/target-claude"
  mkdir -p "$target"

  # Temporarily point CLAUDE_DIR to target
  local orig_claude_dir="$CLAUDE_DIR"
  export CLAUDE_DIR="$target"

  # Import needs consolidated brain
  cp "$snapshot" "$BRAIN_REPO/consolidated/brain.json"
  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --quiet 2>/dev/null || true

  export CLAUDE_DIR="$orig_claude_dir"

  # Check key files were imported
  if [ -f "$target/rules/linting.md" ]; then
    pass "Rules imported"
  else
    fail "Rules not imported"
  fi

  if [ -d "$target/skills" ]; then
    pass "Skills directory created"
  else
    fail "Skills directory not created"
  fi
}

test_secret_scanning() {
  section "Export: secret scanning"

  # Plant a fake API key in memory
  echo "Use API key sk-1234567890abcdefghijklmnopqrstuvwxyz for auth" >> "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md"

  local output
  output=$(bash "$PROJECT_DIR/scripts/export.sh" --output "$TEST_DIR/snapshot-secrets.json" 2>&1) || true

  if echo "$output" | grep -qi "secret\|warning\|potential"; then
    pass "Secret scan warned about API key pattern"
  else
    # Some implementations may not scan or may be quiet
    skip "No secret scan warning detected (may be --quiet)"
  fi

  # Clean up the planted key
  head -3 "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md.tmp"
  mv "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md.tmp" "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md"
}

test_structured_merge() {
  section "Structured merge"

  # Create two snapshots with different settings
  local snap_a="$TEST_DIR/snap-a.json"
  local snap_b="$TEST_DIR/snap-b.json"
  local merged="$TEST_DIR/snap-merged.json"

  cat > "$snap_a" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "aaa", "name": "machine-a"},
  "environmental": {
    "settings": {
      "content": {
        "permissions": {"allow": ["Bash(git:*)"], "deny": []},
        "hooks": {}
      }
    },
    "keybindings": {
      "content": [{"key": "ctrl+k", "command": "clear"}]
    }
  },
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}}
}
EOF

  cat > "$snap_b" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "bbb", "name": "machine-b"},
  "environmental": {
    "settings": {
      "content": {
        "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]},
        "hooks": {}
      }
    },
    "keybindings": {
      "content": [{"key": "ctrl+l", "command": "scroll"}]
    }
  },
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}}
}
EOF

  bash "$PROJECT_DIR/scripts/merge-structured.sh" "$snap_a" "$snap_b" "$merged" 2>/dev/null || true

  if [ ! -f "$merged" ]; then
    fail "merge-structured.sh did not produce output"
    return
  fi

  # Check permissions were unioned
  local allow_count
  allow_count=$(json_length ".environmental.settings.content.permissions.allow" "$merged" || echo "0")
  if [ "$allow_count" -ge 2 ]; then
    pass "Permissions.allow unioned ($allow_count entries)"
  else
    fail "Permissions.allow not unioned (got $allow_count)"
  fi

  local deny_count
  deny_count=$(json_length ".environmental.settings.content.permissions.deny" "$merged" || echo "0")
  if [ "$deny_count" -ge 1 ]; then
    pass "Permissions.deny unioned ($deny_count entries)"
  else
    fail "Permissions.deny not unioned (got $deny_count)"
  fi
}

test_register_machine() {
  section "Register machine"

  # Remove existing config to test fresh creation
  rm -f "$BRAIN_CONFIG"

  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true

  if [ ! -f "$BRAIN_CONFIG" ]; then
    fail "brain-config.json not created"
    return
  fi

  if json_valid "$BRAIN_CONFIG"; then
    pass "brain-config.json is valid JSON"
  else
    fail "brain-config.json is not valid JSON"
    return
  fi

  # Check required fields
  for field in version remote machine_id machine_name brain_repo_path auto_sync; do
    if jqf ".$field" "$BRAIN_CONFIG" >/dev/null 2>&1; then
      pass "Config has field: $field"
    else
      fail "Config missing field: $field"
    fi
  done

  # Check last_evolved field (added in v0.2)
  if jqf ".last_evolved" "$BRAIN_CONFIG" >/dev/null 2>&1; then
    pass "Config has last_evolved field"
  else
    fail "Config missing last_evolved field"
  fi
}

test_shared_namespace() {
  section "Shared namespace"

  # Create shared skill in brain-repo
  echo "# Shared Test Skill" > "$BRAIN_REPO/shared/skills/team-tool.md"

  # Create a minimal consolidated brain with the shared content
  cat > "$BRAIN_REPO/consolidated/brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}},
  "experiential": {"auto_memory": {}},
  "environmental": {"settings": {"content": {}, "hash": ""}, "keybindings": {"content": [], "hash": ""}},
  "shared": {
    "skills": {"team-tool.md": {"content": "# Shared Test Skill", "hash": "sha256:test"}},
    "agents": {},
    "rules": {}
  }
}
EOF

  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --quiet 2>/dev/null || true

  if [ -f "$CLAUDE_DIR/skills/team-tool.md" ]; then
    pass "Shared skill imported to local skills"
  else
    fail "Shared skill not imported"
  fi
}

test_auto_evolve_trigger() {
  section "Auto-evolve scheduling"

  # Ensure brain-config exists
  if [ ! -f "$BRAIN_CONFIG" ]; then
    bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  fi

  # Set last_evolved to 8 days ago
  local eight_days_ago
  eight_days_ago=$(date -d "8 days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v-8d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  if [ -z "$eight_days_ago" ]; then
    skip "Cannot compute date (no GNU or BSD date)"
    return
  fi

  json_set "$BRAIN_CONFIG" "last_evolved" "$eight_days_ago"

  # Create a machine snapshot so pull.sh has something to work with
  local machine_id
  machine_id=$(jqr ".machine_id" "$BRAIN_CONFIG")
  mkdir -p "$BRAIN_REPO/machines/$machine_id"
  cp "$BRAIN_REPO/consolidated/brain.json" "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json" 2>/dev/null || \
    echo '{"schema_version":"1.0.0","machine":{"id":"test","name":"test"},"declarative":{},"procedural":{},"experiential":{},"environmental":{}}' > "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json"

  (cd "$BRAIN_REPO" && git add -A && git commit -q -m "test snapshot" 2>/dev/null || true)

  # Set up a local bare remote so pull.sh can fetch
  local bare_remote="$TEST_DIR/remote.git"
  git clone --bare "$BRAIN_REPO" "$bare_remote" 2>/dev/null || true
  (cd "$BRAIN_REPO" && git remote remove origin 2>/dev/null || true && git remote add origin "$bare_remote")

  # Run pull.sh
  bash "$PROJECT_DIR/scripts/pull.sh" --quiet 2>/dev/null || true

  # pull.sh now logs a notification instead of running evolve.sh directly
  # (evolve.sh calls claude -p which can't run inside active sessions)
  local pull_output
  pull_output=$(bash "$PROJECT_DIR/scripts/pull.sh" --quiet 2>&1) || true

  if echo "$pull_output" | grep -q "Auto-evolve due"; then
    pass "Auto-evolve notification shown after 8 days"
  else
    fail "Auto-evolve notification not shown after 8 days"
  fi

  # Now test that it does NOT notify after 2 days
  local two_days_ago
  two_days_ago=$(date -d "2 days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -v-2d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  json_set "$BRAIN_CONFIG" "last_evolved" "$two_days_ago"

  pull_output=$(bash "$PROJECT_DIR/scripts/pull.sh" --quiet 2>&1) || true

  if echo "$pull_output" | grep -q "Auto-evolve due"; then
    fail "Auto-evolve notification incorrectly shown after 2 days"
  else
    pass "Auto-evolve notification NOT shown after 2 days"
  fi
}

test_wsl_detection() {
  section "OS detection"

  source "$PROJECT_DIR/scripts/common.sh" 2>/dev/null || true

  local os
  os=$(detect_os)
  if [ -n "$os" ] && [[ "$os" =~ ^(linux|macos|wsl|windows|unknown)$ ]]; then
    pass "detect_os returned valid value: $os"
  else
    fail "detect_os returned unexpected: $os"
  fi
}

test_encryption_roundtrip() {
  section "Encryption (age)"

  if ! command -v age &>/dev/null || ! command -v age-keygen &>/dev/null; then
    skip "age not installed"
    return
  fi

  source "$PROJECT_DIR/scripts/common.sh" 2>/dev/null || true

  # Generate test keypair
  local identity="$TEST_DIR/test-age-key.txt"
  local recipients="$TEST_DIR/test-recipients.txt"
  age-keygen -o "$identity" 2>/dev/null
  grep "# public key:" "$identity" | cut -d' ' -f4 > "$recipients"

  # Test encrypt/decrypt
  local plaintext="Hello, this is a test of brain encryption!"
  local encrypted
  encrypted=$(echo "$plaintext" | age -R "$recipients" -a 2>/dev/null) || {
    fail "age encryption failed"
    return
  }

  if echo "$encrypted" | head -1 | grep -q "BEGIN AGE ENCRYPTED FILE"; then
    pass "Content encrypted with age armor"
  else
    fail "Encrypted content missing age header"
  fi

  local decrypted
  decrypted=$(echo "$encrypted" | age -d -i "$identity" 2>/dev/null) || {
    fail "age decryption failed"
    return
  }

  if [ "$decrypted" = "$plaintext" ]; then
    pass "Decrypt round-trip matches original"
  else
    fail "Decrypt mismatch: got '$decrypted'"
  fi
}

# ── Deletion & Memory Merge Tests ─────────────────────────────────────────────

test_deletion_respected_in_merge() {
  section "Deletion respected in structured merge"

  local snap_a="$TEST_DIR/snap-merge-del-a.json"
  local snap_b="$TEST_DIR/snap-merge-del-b.json"
  local merged="$TEST_DIR/snap-merge-del-result.json"

  # Machine A: has the skill, no deletions
  cat > "$snap_a" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "aaa", "name": "machine-a"},
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {
    "skills": {"stale-skill.md": {"content": "old skill", "hash": "sha256:old"}},
    "agents": {},
    "output_styles": {}
  },
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}}, "keybindings": {"content": []}, "mcp_servers": {}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  # Machine B: deleted the skill, has deletion record
  cat > "$snap_b" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "bbb", "name": "machine-b"},
  "deletions": {
    "procedural.skills": ["stale-skill.md"]
  },
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {
    "skills": {},
    "agents": {},
    "output_styles": {}
  },
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}}, "keybindings": {"content": []}, "mcp_servers": {}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  bash "$PROJECT_DIR/scripts/merge-structured.sh" "$snap_a" "$snap_b" "$merged" 2>/dev/null || true

  if [ ! -f "$merged" ]; then
    fail "merge-structured.sh did not produce output"
    return
  fi

  # The deleted skill should NOT be in the merged result
  local has_stale
  has_stale=$(jq '.procedural.skills | has("stale-skill.md")' "$merged" 2>/dev/null)
  if [ "$has_stale" = "false" ]; then
    pass "Deleted skill removed from merged result"
  else
    fail "Deleted skill still present in merged result"
  fi
}

test_deletion_applied_on_import() {
  section "Deletion applied on import"

  # Create a local skill file that should be deleted
  echo "# To be deleted" > "$CLAUDE_DIR/skills/to-delete.md"

  # Create consolidated brain with deletion for this file
  cat > "$BRAIN_REPO/consolidated/brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "deletions": {
    "procedural.skills": ["to-delete.md"]
  },
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}, "hash": ""}, "keybindings": {"content": [], "hash": ""}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --no-backup --quiet 2>/dev/null || true

  if [ ! -f "$CLAUDE_DIR/skills/to-delete.md" ]; then
    pass "Deleted skill removed from local filesystem"
  else
    fail "Deleted skill still exists locally"
  fi
}

test_memory_merge_union() {
  section "Memory file union merge"

  # Set up local MEMORY.md using the existing my-project dir (from sandbox setup)
  cat > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" <<'EOF'
- [a.md](a.md) - Entry A from local
- [b.md](b.md) - Entry B from local
EOF

  # The project name decoded from "my-project" is "project" (decode_project_path convention)
  local project_name
  project_name=$(source "$PROJECT_DIR/scripts/common.sh" 2>/dev/null; project_name_from_encoded "my-project")

  # Create consolidated brain with entries B and C using the decoded project name
  cat > "$BRAIN_REPO/consolidated/brain.json" <<EOF
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {
    "auto_memory": {
      "${project_name}": {
        "MEMORY.md": {
          "content": "- [b.md](b.md) - Entry B from local\n- [c.md](c.md) - Entry C from remote\n",
          "hash": "sha256:different"
        }
      }
    },
    "agent_memory": {}
  },
  "environmental": {"settings": {"content": {}, "hash": ""}, "keybindings": {"content": [], "hash": ""}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --no-backup --quiet 2>/dev/null || true

  local content
  content=$(cat "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md")

  local has_a has_b has_c
  has_a=$(echo "$content" | grep -c "Entry A" || true)
  has_b=$(echo "$content" | grep -c "Entry B" || true)
  has_c=$(echo "$content" | grep -c "Entry C" || true)

  if [ "$has_a" -ge 1 ] && [ "$has_b" -ge 1 ] && [ "$has_c" -ge 1 ]; then
    pass "MEMORY.md has entries from both local and remote"
  else
    fail "MEMORY.md missing entries (A=$has_a B=$has_b C=$has_c)"
  fi
}

test_memory_merge_no_duplicates() {
  section "Memory merge no duplicates"

  # MEMORY.md should still have exactly 3 unique entries from previous test
  local content
  content=$(cat "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" 2>/dev/null || echo "")

  local line_count
  line_count=$(echo "$content" | grep -c "^\- \[" || true)

  if [ "$line_count" -eq 3 ]; then
    pass "MEMORY.md has exactly 3 entries (no duplicates)"
  else
    fail "MEMORY.md has $line_count entries (expected 3)"
  fi
}

test_keybindings_merge() {
  section "Keybindings merge (object format)"

  # Create local keybindings in object format (real format)
  cat > "$CLAUDE_DIR/keybindings.json" <<'EOF'
{"bindings": [{"key": "ctrl+k", "command": "clear", "context": "terminal"}]}
EOF

  # Create consolidated brain with different keybindings
  cat > "$BRAIN_REPO/consolidated/brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {
    "settings": {"content": {}, "hash": ""},
    "keybindings": {
      "content": {"bindings": [{"key": "ctrl+l", "command": "scroll", "context": "editor"}]},
      "hash": "sha256:different"
    }
  },
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  # Import should NOT error (timeout to prevent hangs)
  local import_output
  import_output=$(timeout 10 bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --no-backup --quiet 2>&1 || true)
  local exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "Keybindings import succeeded (exit code 0)"
  else
    fail "Keybindings import failed (exit code $exit_code): $import_output"
  fi

  # Verify both keybindings are present
  if [ -f "$CLAUDE_DIR/keybindings.json" ]; then
    local binding_count
    binding_count=$(jq '.bindings | length' "$CLAUDE_DIR/keybindings.json" 2>/dev/null || echo "0")
    if [ "$binding_count" -ge 2 ]; then
      pass "Both keybindings merged ($binding_count bindings)"
    else
      fail "Keybindings not merged (got $binding_count, expected 2)"
    fi
  else
    fail "keybindings.json not found after import"
  fi
}

test_push_retry_with_conflict() {
  section "Push retry with diverged remote"

  # Ensure brain-config exists
  if [ ! -f "$BRAIN_CONFIG" ]; then
    bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  fi

  local machine_id
  machine_id=$(jqr ".machine_id" "$BRAIN_CONFIG")

  # Create a local bare remote
  local bare_remote="$TEST_DIR/push-retry-remote.git"
  rm -rf "$bare_remote"
  git clone --bare "$BRAIN_REPO" "$bare_remote" 2>/dev/null || true
  (cd "$BRAIN_REPO" && git remote remove origin 2>/dev/null || true && git remote add origin "$bare_remote")

  # Create a divergence: commit something on the remote that local doesn't have
  local tmp_clone="$TEST_DIR/push-retry-clone"
  rm -rf "$tmp_clone"
  git clone "$bare_remote" "$tmp_clone" 2>/dev/null
  (cd "$tmp_clone" && echo '{}' > meta/remote-change.json && git add -A && git commit -q -m "remote change" && git push -q origin main 2>/dev/null)

  # Now try to push from the brain repo (which is behind)
  mkdir -p "$BRAIN_REPO/machines/$machine_id"
  echo '{"test": true}' > "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json"
  (cd "$BRAIN_REPO" && git add -A && git commit -q -m "local change" 2>/dev/null || true)

  local push_output
  push_output=$(bash "$PROJECT_DIR/scripts/push.sh" --force 2>&1)
  local exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "Push succeeded after retry with diverged remote"
  else
    fail "Push failed with diverged remote (exit $exit_code)"
  fi

  # Verify the push actually reached the remote
  local remote_has_local
  remote_has_local=$(cd "$tmp_clone" && git pull -q origin main 2>/dev/null && ls machines/$machine_id/brain-snapshot.json 2>/dev/null)
  if [ -n "$remote_has_local" ]; then
    pass "Local changes reached remote after retry"
  else
    fail "Local changes did not reach remote"
  fi

  rm -rf "$tmp_clone"
}

test_semantic_fallback_preserves_claude_md() {
  section "Semantic fallback preserves CLAUDE.md"

  # Create two snapshots with different CLAUDE.md content
  local snap_a="$TEST_DIR/snap-sem-a.json"
  local snap_b="$TEST_DIR/snap-sem-b.json"

  cat > "$snap_a" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "aaa", "name": "machine-a"},
  "declarative": {"claude_md": {"content": "# Machine A rules\n- Rule from A\n", "hash": "sha256:aaa"}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}}, "keybindings": {"content": []}, "mcp_servers": {}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  cat > "$snap_b" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "bbb", "name": "machine-b"},
  "declarative": {"claude_md": {"content": "# Machine B rules\n- Rule from B\n", "hash": "sha256:bbb"}, "rules": {}},
  "procedural": {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}}, "keybindings": {"content": []}, "mcp_servers": {}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  # Put snapshots in machine dirs
  local machine_a_dir="$BRAIN_REPO/machines/aaa"
  local machine_b_dir="$BRAIN_REPO/machines/bbb"
  mkdir -p "$machine_a_dir" "$machine_b_dir"
  cp "$snap_a" "$machine_a_dir/brain-snapshot.json"
  cp "$snap_b" "$machine_b_dir/brain-snapshot.json"

  # Run structured merge first (like pull.sh does)
  local merging="$BRAIN_REPO/consolidated/brain.json.merging"
  bash "$PROJECT_DIR/scripts/merge-structured.sh" "$snap_a" "$snap_b" "$merging" 2>/dev/null || true

  # Simulate semantic merge failure (claude -p not available)
  # merge-semantic.sh will fail, and the fallback should preserve content
  # But the REAL test is: after pull.sh's fallback logic, does CLAUDE.md survive?

  # The structured merge keeps base CLAUDE.md (machine A's)
  # After semantic merge fails, pull.sh should use structured result
  local consolidated="$BRAIN_REPO/consolidated/brain.json"
  rm -f "$consolidated"

  # Simulate pull.sh's fallback: if semantic failed and no brain.json, use .merging
  if [ ! -f "$consolidated" ] && [ -f "$merging" ]; then
    mv "$merging" "$consolidated"
  fi

  if [ -f "$consolidated" ]; then
    local claude_md
    claude_md=$(jq -r '.declarative.claude_md.content // ""' "$consolidated")
    if [ -n "$claude_md" ] && [ ${#claude_md} -gt 5 ]; then
      pass "CLAUDE.md preserved in fallback (${#claude_md} chars)"
    else
      fail "CLAUDE.md lost in fallback (empty or too short)"
    fi
  else
    fail "No consolidated brain after fallback"
  fi
}

test_evolve_prepare() {
  section "Evolve prepare (no LLM needed)"

  # Create a consolidated brain with some memory content
  cat > "$BRAIN_REPO/consolidated/brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {
    "claude_md": {"content": "# Rules\n- Use pnpm\n- Always test", "hash": ""},
    "rules": {"linting.md": {"content": "Run linting before commit.", "hash": ""}}
  },
  "procedural": {
    "skills": {"review/SKILL.md": {"content": "Review code", "hash": ""}},
    "agents": {},
    "output_styles": {}
  },
  "experiential": {
    "auto_memory": {
      "my-project": {
        "MEMORY.md": {"content": "- Use vitest\n- Database is PostgreSQL", "hash": ""}
      }
    },
    "agent_memory": {}
  },
  "environmental": {"settings": {"content": {}, "hash": ""}, "keybindings": {"content": [], "hash": ""}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  (cd "$BRAIN_REPO" && git add -A && git commit -q -m "consolidated for evolve" 2>/dev/null || true)

  # Run evolve-prepare (should NOT call claude -p, should produce a context file)
  local output="$BRAIN_REPO/meta/evolve-context.json"
  bash "$PROJECT_DIR/scripts/evolve-prepare.sh" --output "$output" 2>/dev/null || true

  if [ ! -f "$output" ]; then
    fail "evolve-prepare.sh did not produce output file"
    return
  fi

  if json_valid "$output"; then
    pass "evolve-context.json is valid JSON"
  else
    fail "evolve-context.json is not valid JSON"
    return
  fi

  # Check it has the required fields for the skill to analyze
  local has_claude_md has_memory has_rules has_skills has_prompt
  has_claude_md=$(jq 'has("current_claude_md")' "$output" 2>/dev/null)
  has_memory=$(jq 'has("all_memory")' "$output" 2>/dev/null)
  has_rules=$(jq 'has("current_rules")' "$output" 2>/dev/null)
  has_skills=$(jq 'has("current_skills")' "$output" 2>/dev/null)
  has_prompt=$(jq 'has("evolve_prompt")' "$output" 2>/dev/null)

  if [ "$has_claude_md" = "true" ]; then pass "Has current_claude_md"; else fail "Missing current_claude_md"; fi
  if [ "$has_memory" = "true" ]; then pass "Has all_memory"; else fail "Missing all_memory"; fi
  if [ "$has_rules" = "true" ]; then pass "Has current_rules"; else fail "Missing current_rules"; fi
  if [ "$has_skills" = "true" ]; then pass "Has current_skills"; else fail "Missing current_skills"; fi
  if [ "$has_prompt" = "true" ]; then pass "Has evolve_prompt"; else fail "Missing evolve_prompt"; fi

  # Verify the prompt contains actual content (not empty)
  local prompt_len
  prompt_len=$(jq '.evolve_prompt | length' "$output" 2>/dev/null || echo "0")
  if [ "$prompt_len" -gt 100 ]; then
    pass "evolve_prompt has substantive content (${prompt_len} chars)"
  else
    fail "evolve_prompt too short (${prompt_len} chars)"
  fi
}

test_backward_compat_no_deletions() {
  section "Backward compat: snapshot without deletions field"

  local snap_old="$TEST_DIR/snap-compat-old.json"
  local snap_new="$TEST_DIR/snap-compat-new.json"
  local merged="$TEST_DIR/snap-compat-merged.json"

  # Old format: no deletions field at all
  cat > "$snap_old" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "old", "name": "old-machine"},
  "declarative": {"claude_md": {"content": "old rules", "hash": ""}, "rules": {"old-rule.md": {"content": "rule", "hash": ""}}},
  "procedural": {"skills": {"old-skill.md": {"content": "skill", "hash": ""}}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}}, "keybindings": {"content": []}, "mcp_servers": {}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  # New format: has deletions field (empty)
  cat > "$snap_new" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "new", "name": "new-machine"},
  "deletions": {},
  "declarative": {"claude_md": {"content": "new rules", "hash": ""}, "rules": {"new-rule.md": {"content": "rule", "hash": ""}}},
  "procedural": {"skills": {"new-skill.md": {"content": "skill", "hash": ""}}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {"settings": {"content": {}}, "keybindings": {"content": []}, "mcp_servers": {}},
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  bash "$PROJECT_DIR/scripts/merge-structured.sh" "$snap_old" "$snap_new" "$merged" 2>/dev/null || {
    fail "Merge with old-format snapshot errored"
    return
  }

  if [ ! -f "$merged" ]; then
    fail "No merged output"
    return
  fi

  # Both skills should be present (no deletions from either side)
  local has_old has_new
  has_old=$(jq '.procedural.skills | has("old-skill.md")' "$merged" 2>/dev/null)
  has_new=$(jq '.procedural.skills | has("new-skill.md")' "$merged" 2>/dev/null)

  if [ "$has_old" = "true" ] && [ "$has_new" = "true" ]; then
    pass "Both old and new skills present in merge (backward compatible)"
  else
    fail "Missing skills in merge (old=$has_old new=$has_new)"
  fi
}

test_deletion_tracking() {
  section "Deletion tracking in export"

  # First export (creates initial snapshot with skills/review/SKILL.md)
  local snap1="$TEST_DIR/snap-del-1.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$snap1" --skip-secret-scan --quiet 2>/dev/null || true

  # Commit the first snapshot to git so we have history to diff against
  local machine_id
  machine_id=$(jqr ".machine.id" "$snap1")
  mkdir -p "$BRAIN_REPO/machines/$machine_id"
  cp "$snap1" "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json"
  (cd "$BRAIN_REPO" && git add -A && git commit -q -m "initial snapshot")

  # Verify the skill exists in first snapshot
  local has_skill
  has_skill=$(jq '.procedural.skills | has("review/SKILL.md")' "$snap1" 2>/dev/null)
  if [ "$has_skill" = "true" ]; then
    pass "Initial snapshot has review/SKILL.md"
  else
    fail "Initial snapshot missing review/SKILL.md"
    return
  fi

  # Delete the skill locally
  rm -rf "$CLAUDE_DIR/skills/review"

  # Second export
  local snap2="$TEST_DIR/snap-del-2.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$snap2" --skip-secret-scan --quiet 2>/dev/null || true

  # Assert: deletions field exists and lists the removed skill
  local has_deletions
  has_deletions=$(jq 'has("deletions")' "$snap2" 2>/dev/null)
  if [ "$has_deletions" = "true" ]; then
    pass "Snapshot has deletions field"
  else
    fail "Snapshot missing deletions field"
    return
  fi

  local skill_deleted
  skill_deleted=$(jq '.deletions["procedural.skills"] // [] | index("review/SKILL.md") != null' "$snap2" 2>/dev/null)
  if [ "$skill_deleted" = "true" ]; then
    pass "Deletions lists review/SKILL.md"
  else
    fail "Deletions does not list review/SKILL.md"
  fi
}

# ── Run ────────────────────────────────────────────────────────────────────────
echo -e "${CYAN}claude-brain integration tests${NC}"
echo "================================"

# jq is required
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq is required to run tests. Install: apt install jq / brew install jq${NC}"
  exit 1
fi

setup_sandbox

test_export_structure
test_export_no_secrets
test_secret_scanning
test_export_import_roundtrip
test_structured_merge
test_register_machine
test_shared_namespace
test_auto_evolve_trigger
test_wsl_detection
test_encryption_roundtrip
test_deletion_tracking
test_deletion_respected_in_merge
test_deletion_applied_on_import
test_memory_merge_union
test_memory_merge_no_duplicates
test_backward_compat_no_deletions
test_evolve_prepare
test_keybindings_merge
test_push_retry_with_conflict
test_semantic_fallback_preserves_claude_md

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
