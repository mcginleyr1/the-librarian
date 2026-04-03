#!/usr/bin/env python3
"""Tiny HTTP server that triggers feed curation via Claude Code.

Listens on 0.0.0.0:9723 so OrbStack k8s pods can reach it via host.internal.
Only accepts POST /curate. Runs curate.sh and returns the result.
"""

import subprocess
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from datetime import datetime

SCRIPT_DIR = Path(__file__).parent
CURATE_SCRIPT = SCRIPT_DIR / "curate.sh"
REPO_ROOT = SCRIPT_DIR.parent.parent


class CurateHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/curate":
            self.send_error(404)
            return

        self.send_response(202)
        self.send_header("Content-Type", "application/json")
        self.end_headers()

        now = datetime.now().isoformat()
        self.wfile.write(json.dumps({"status": "started", "time": now}).encode())
        self.wfile.flush()

        # Run curate.sh in background so we don't block the response
        subprocess.Popen(
            [str(CURATE_SCRIPT)],
            cwd=str(REPO_ROOT),
            stdout=open(REPO_ROOT / "knowledge" / "curate-latest.log", "w"),
            stderr=subprocess.STDOUT,
        )

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return
        self.send_error(404)

    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {format % args}")


if __name__ == "__main__":
    port = 9723
    server = HTTPServer(("0.0.0.0", port), CurateHandler)
    print(f"Curate server listening on :{port}")
    server.serve_forever()
