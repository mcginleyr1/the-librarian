#!/usr/bin/env bash
set -euo pipefail

# Feed Curation Agent
# Runs Claude Code against today's feed articles using interest profiles.
# Schedule: daily, after the 2h feed fetch cycle (e.g., 5am via launchd)

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KNOWLEDGE_DIR="$REPO_ROOT/knowledge"
DATE=$(date +%Y-%m-%d)
CURATED_DIR="$KNOWLEDGE_DIR/curated/$DATE"

mkdir -p "$CURATED_DIR"

# Skip if already ran today (index.md exists)
if [ -f "$CURATED_DIR/index.md" ]; then
  echo "Already curated for $DATE, skipping."
  exit 0
fi

echo "[$DATE] Starting feed curation..."

claude --dangerously-skip-permissions \
  -p "Read all profiles in knowledge/profiles/, then follow the curation workflow in knowledge/CLAUDE.md to process today's feed articles. Write curated .md files to knowledge/curated/$DATE/. Be selective — aim for 5-15 high-signal articles." \
  --cwd "$REPO_ROOT" \
  --model sonnet \
  --max-turns 30 \
  2>&1 | tee "$CURATED_DIR/agent.log"

echo "[$DATE] Curation complete. Results in $CURATED_DIR/"
