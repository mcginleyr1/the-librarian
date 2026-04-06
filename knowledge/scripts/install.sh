#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST_NAME="com.librarian.curate-server"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

echo "=== The Librarian — Curate Server Setup ==="
echo ""

# Check claude is installed and authenticated
if ! command -v claude &>/dev/null; then
  echo "ERROR: claude not found. Install Claude Code first:"
  echo "  npm install -g @anthropic-ai/claude-code"
  exit 1
fi

AUTH=$(claude auth status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('loggedIn',''))" 2>/dev/null || echo "")
if [ "$AUTH" != "True" ]; then
  echo "ERROR: claude not authenticated. Run: claude login"
  exit 1
fi
echo "[ok] claude installed and authenticated"

# Check kubectl can reach the librarian namespace
if ! kubectl get pods -n librarian &>/dev/null; then
  echo "ERROR: cannot reach librarian k8s namespace"
  exit 1
fi
echo "[ok] kubectl can reach librarian namespace"

# Make scripts executable
chmod +x "$SCRIPT_DIR/curate.sh"
chmod +x "$SCRIPT_DIR/curate-server.py"
echo "[ok] scripts are executable"

# Unload existing plist if present
if launchctl list "$PLIST_NAME" &>/dev/null; then
  echo "Stopping existing curate-server..."
  launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

mkdir -p "$HOME/Library/LaunchAgents"

# Generate plist with correct paths for this machine
cat > "$PLIST_DST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_NAME</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$SCRIPT_DIR/curate-server.py</string>
  </array>

  <key>WorkingDirectory</key>
  <string>$REPO_ROOT</string>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$REPO_ROOT/knowledge/curate-server.log</string>

  <key>StandardErrorPath</key>
  <string>$REPO_ROOT/knowledge/curate-server.log</string>
</dict>
</plist>
EOF

launchctl load "$PLIST_DST"
echo "[ok] launchd service installed and started"

# Wait a beat then health check
sleep 1
if curl -sf http://localhost:9723/health &>/dev/null; then
  echo "[ok] curate-server is running on :9723"
else
  echo "WARNING: curate-server not responding yet, check:"
  echo "  tail -f $REPO_ROOT/knowledge/curate-server.log"
  exit 1
fi

echo ""
echo "Done. Oban will POST to host.internal:9723/curate at 5:30am and 5:30pm."
echo "To test manually: curl -X POST http://localhost:9723/curate"
echo "Logs: tail -f $REPO_ROOT/knowledge/curate-server.log"
echo "To uninstall: launchctl unload $PLIST_DST && rm $PLIST_DST"
