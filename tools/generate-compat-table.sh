#!/bin/bash
# Generate a compatibility table from git test allowlist and compat spec
# Usage: bash tools/generate-compat-table.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="$SCRIPT_DIR/git-test-allowlist.txt"
SPEC_FILE="$SCRIPT_DIR/compat-spec.txt"

# Count tests from allowlist
total_tests=0
if [[ -f "$ALLOWLIST" ]]; then
  total_tests=$(grep -v '^[[:space:]]*#' "$ALLOWLIST" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
fi

echo "# Git Compatibility Table"
echo ""
echo "moongit compatibility with git commands. **$total_tests upstream tests** passing."
echo ""

# Command compatibility from spec
echo "## Command Support"
echo ""
echo "| Command | Status | Supported Options | Unsupported Options | Notes |"
echo "|---------|--------|-------------------|---------------------|-------|"

current_section=""
while IFS='|' read -r cmd status supported unsupported notes; do
  # Skip empty lines
  [[ -z "$cmd" ]] && continue
  # Handle section comments
  if [[ "$cmd" =~ ^#[[:space:]]*(.+)$ ]]; then
    section="${BASH_REMATCH[1]}"
    if [[ "$section" != "$current_section" ]]; then
      current_section="$section"
    fi
    continue
  fi
  # Skip other comments
  [[ "$cmd" =~ ^# ]] && continue

  # Format status with emoji
  case "$status" in
    full) status_fmt="✅ Full" ;;
    partial) status_fmt="🔶 Partial" ;;
    none) status_fmt="❌ None" ;;
    *) status_fmt="$status" ;;
  esac

  # Format options (truncate if too long)
  if [[ ${#supported} -gt 40 ]]; then
    supported="${supported:0:37}..."
  fi
  if [[ ${#unsupported} -gt 40 ]]; then
    unsupported="${unsupported:0:37}..."
  fi

  # Escape pipe characters
  supported="${supported//|/\\|}"
  unsupported="${unsupported//|/\\|}"
  notes="${notes//|/\\|}"

  echo "| \`$cmd\` | $status_fmt | $supported | $unsupported | $notes |"
done < "$SPEC_FILE"

echo ""

# Test categories from allowlist
echo "## Upstream Test Coverage"
echo ""

declare -A categories
current_category=""

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ "$line" =~ ^#[[:space:]]*(.+)$ ]]; then
    current_category="${BASH_REMATCH[1]}"
    continue
  fi
  [[ "$line" =~ ^# ]] && continue
  if [[ -n "$current_category" ]]; then
    categories["$current_category"]+="$line "
  fi
done < "$ALLOWLIST"

echo "| Category | Tests |"
echo "|----------|-------|"

for category in "${!categories[@]}"; do
  tests="${categories[$category]}"
  test_count=$(echo "$tests" | wc -w | tr -d ' ')
  echo "| $category | $test_count |"
done
echo "| **Total** | **$total_tests** |"

echo ""
echo "---"
echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
