#!/bin/bash
# Post-edit hook: runs mix format on any .ex/.exs file after an Edit tool call.
# Triggered by PostToolUse on Edit.

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only format Elixir files
if [[ "$FILE" != *.ex && "$FILE" != *.exs ]]; then
  exit 0
fi

# Only format files inside this project
if [[ "$FILE" != "$CLAUDE_PROJECT_DIR"* ]]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR" || exit 0
mix format "$FILE" 2>/dev/null
exit 0
