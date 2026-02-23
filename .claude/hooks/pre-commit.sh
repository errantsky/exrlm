#!/bin/bash
# Pre-commit hook: runs compile, test, and format checks before allowing git commit.
# Triggered by PreToolUse on Bash when the command contains "git commit".

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only intercept git commit commands
if ! echo "$COMMAND" | grep -q 'git commit'; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0

echo "Running pre-commit checks..." >&2

if ! mix compile --warnings-as-errors 2>&1; then
  echo '{"decision":"block","reason":"mix compile --warnings-as-errors failed. Fix compilation warnings before committing."}'
  exit 2
fi

if ! mix test 2>&1; then
  echo '{"decision":"block","reason":"mix test failed. Fix failing tests before committing."}'
  exit 2
fi

if ! mix format --check-formatted 2>&1; then
  echo '{"decision":"block","reason":"mix format --check-formatted failed. Run mix format before committing."}'
  exit 2
fi

echo "All pre-commit checks passed." >&2
exit 0
