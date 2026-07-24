# The Librarian — task runner
# Usage: just <recipe>

IMAGE := "the-librarian"
NAMESPACE := "librarian"
# Internal registry the cluster pulls from (exposed via the Tailscale operator)
TS_REGISTRY := "registry.<your-tailnet>.ts.net:5000"
# kubectl context hosting the librarian cluster — pinned so `just deploy` works
# from any machine on the tailnet, not just one whose current context happens to
# be right. Override per-machine with LIBRARIAN_KUBE_CONTEXT if needed.
KUBE_CONTEXT := env_var_or_default("LIBRARIAN_KUBE_CONTEXT", "tailscale-operator.<your-tailnet>.ts.net")
KUBECTL := "kubectl --context " + KUBE_CONTEXT

# ── Dev ──────────────────────────────────────────────────────────────────────

# Start dev server with IEx (starts postgres via docker compose first)
dev: db-up
    iex -S mix phx.server

# Start postgres only (for native dev + tests)
db-up:
    docker compose up -d postgres
    docker compose exec postgres sh -c 'until pg_isready -U postgres; do sleep 1; done'

# Start full stack in docker (postgres + built app image) — for local image testing only
up:
    docker compose --profile full up --build

# Stop everything
db-down:
    docker compose --profile full down

# ── Test & Quality ────────────────────────────────────────────────────────────

# Run tests (starts postgres first)
test: db-up
    mix test

# Run tests with coverage
test-cover: db-up
    mix test --cover

# Compile with warnings as errors
check:
    mix compile --warnings-as-errors

# Format code
fmt:
    mix format

# Full pre-commit suite
precommit:
    mix precommit

# ── Database (local dev) ──────────────────────────────────────────────────────

# Create and migrate local dev database
db-setup: db-up
    mix ecto.setup

# Reset local dev database
db-reset: db-up
    mix ecto.reset

# ── Build & Push ──────────────────────────────────────────────────────────────

# Build the app image for the cluster (arm64 node), tagged for the internal registry
docker-build:
    docker build --platform linux/arm64 -t {{TS_REGISTRY}}/{{IMAGE}}:latest .

# Build and push the app image to the INTERNAL registry the cluster pulls from.
# Uses registry-push (port-forward) because the Tailscale LB mangles large pushes.
docker-push: docker-build
    just registry-push {{IMAGE}}:latest

# Push an already-built image to the INTERNAL registry, bypassing the Tailscale
# LoadBalancer proxy (it mangles large layer uploads; GET/pull works, push doesn't).
# Port-forwards straight to the registry pod and pushes to localhost instead.
# Usage: just registry-push postgres-pgvector:16   (image must be tagged {{TS_REGISTRY}}/<that>)
registry-push IMG:
    #!/usr/bin/env bash
    set -euo pipefail
    port=5000
    curl -sf "http://localhost:$port/v2/" >/dev/null 2>&1 && port=5055
    {{KUBECTL}} port-forward -n registry svc/registry "$port:5000" >/tmp/reg-pf.log 2>&1 &
    pf=$!; trap 'kill $pf 2>/dev/null' EXIT
    for _ in $(seq 1 30); do curl -sf "http://localhost:$port/v2/" >/dev/null 2>&1 && break; sleep 1; done
    curl -sf "http://localhost:$port/v2/" >/dev/null 2>&1 || { echo "registry port-forward failed:"; cat /tmp/reg-pf.log; exit 1; }
    docker tag "{{TS_REGISTRY}}/{{IMG}}" "localhost:$port/{{IMG}}"
    docker push "localhost:$port/{{IMG}}"
    echo "pushed {{IMG}} -> {{TS_REGISTRY}} (via port-forward)"

# ── K8s ───────────────────────────────────────────────────────────────────────

# Apply namespace only (needed before k-create-secrets on first deploy)
k-namespace:
    {{KUBECTL}} apply -f k8s/namespace.yaml

# Apply all k8s manifests via kustomize (does not apply secrets.yaml — use k-create-secrets)
k-apply:
    {{KUBECTL}} apply -k k8s/

# Create secrets — run after k-namespace, before k-apply
k-create-secrets db-password google-client-id google-client-secret: k-namespace
    {{KUBECTL}} create secret generic librarian-secrets -n {{NAMESPACE}} \
        --from-literal=db-user=librarian \
        --from-literal=db-password={{db-password}} \
        --from-literal=secret-key-base=$(mix phx.gen.secret) \
        --from-literal=database-url=ecto://librarian:{{db-password}}@postgres:5432/librarian_prod \
        --from-literal=google-client-id={{google-client-id}} \
        --from-literal=google-client-secret={{google-client-secret}} \
        --save-config --dry-run=client -o yaml | {{KUBECTL}} apply -f -

# Google has no API/gcloud command for standard OAuth 2.0 web clients (the IAP
# OAuth Admin API was shut down 2026-03), so the console click-through is
# unavoidable — this walks it: prints the exact values and opens the console.
oauth-setup:
    @echo "Google OAuth clients for web sign-in can only be created in the console."
    @echo ""
    @echo "1. Consent screen (once per project):"
    @echo "     https://console.cloud.google.com/auth/branding"
    @echo "     - User type: External   - App name: The Librarian"
    @echo "     - Add yourself as a test user (Audience page): owner@example.com"
    @echo "       (or hit 'Publish app' so the token doesn't expire after 7 days)"
    @echo ""
    @echo "2. Create the client:"
    @echo "     https://console.cloud.google.com/auth/clients/create"
    @echo "     - Application type: Web application   - Name: librarian"
    @echo "     - Authorized redirect URIs:"
    @echo "         http://localhost:4000/auth/google/callback"
    @echo "         https://librarian.<your-tailnet>.ts.net/auth/google/callback"
    @echo ""
    @echo "3. Store the credentials:"
    @echo "     just k-set-google-oauth <client-id> <client-secret>   # existing cluster"
    @echo "     just k-create-secrets <db-pw> <client-id> <client-secret>   # first deploy"
    @echo "     export GOOGLE_CLIENT_ID=... GOOGLE_CLIENT_SECRET=...   # local dev"
    open "https://console.cloud.google.com/auth/clients/create"

# Patch Google OAuth creds into the existing secret (does NOT touch db password
# or secret-key-base — unlike k-create-secrets, which regenerates the key base
# and would invalidate live sessions), then restart the app to pick them up.
k-set-google-oauth google-client-id google-client-secret:
    {{KUBECTL}} patch secret librarian-secrets -n {{NAMESPACE}} --type merge \
        -p '{"stringData":{"google-client-id":"{{google-client-id}}","google-client-secret":"{{google-client-secret}}"}}'
    {{KUBECTL}} rollout restart deployment/librarian -n {{NAMESPACE}}
    {{KUBECTL}} rollout status deployment/librarian -n {{NAMESPACE}}

# Remove duplicate vault notes in cluster (keeps oldest copy, moves annotations)
k-dedupe-notes:
    {{KUBECTL}} exec -n {{NAMESPACE}} deploy/librarian -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.dedupe_notes()"

# Run Ecto migrations in cluster
k-migrate:
    {{KUBECTL}} exec -n {{NAMESPACE}} deploy/librarian -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.migrate()"

# Tail app logs
k-logs:
    {{KUBECTL}} logs -n {{NAMESPACE}} -f deploy/librarian

# Show pod/pvc/ingress status
k-status:
    {{KUBECTL}} get pods,pvc,ingress -n {{NAMESPACE}}

# Rolling restart (picks up new image)
k-restart:
    {{KUBECTL}} rollout restart -n {{NAMESPACE}} deploy/librarian

# Open remote IEx shell
k-shell:
    {{KUBECTL}} exec -n {{NAMESPACE}} -it deploy/librarian -- \
        /app/bin/librarian remote

# Full deploy: build, push, restart
deploy: docker-push k-restart

# Delete all resources (destructive!)
k-teardown:
    {{KUBECTL}} delete namespace {{NAMESPACE}}

# ── Data (local dev) ─────────────────────────────────────────────────────────

# Import feeds from OPML file into local dev database
import-opml FILE="feedly.opml":
    mix librarian.import_opml {{FILE}}

# Import a single Evernote ENEX file into local dev database
import-evernote FILE:
    mix librarian.import_evernote {{FILE}}

# Import all .enex files from a directory into local dev database
import-evernote-dir DIR="enex":
    #!/usr/bin/env bash
    for f in {{DIR}}/*.enex; do
        echo "Importing $f..."
        mix librarian.import_evernote "$f"
    done

# ── Data (k8s) ────────────────────────────────────────────────────────────────

# Import OPML into k8s (copies file to pod, runs release eval)
k-import-opml FILE="feedly.opml":
    #!/usr/bin/env bash
    POD=$({{KUBECTL}} get pod -n {{NAMESPACE}} -l app=librarian -o jsonpath='{.items[0].metadata.name}')
    {{KUBECTL}} cp "{{FILE}}" "{{NAMESPACE}}/$POD:/tmp/opml_import.opml"
    {{KUBECTL}} exec -n {{NAMESPACE}} "$POD" -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.import_opml(\"/tmp/opml_import.opml\")"

# Import a single .enex file into k8s
k-import-evernote FILE NOTEBOOK="":
    #!/usr/bin/env bash
    POD=$({{KUBECTL}} get pod -n {{NAMESPACE}} -l app=librarian -o jsonpath='{.items[0].metadata.name}')
    BASENAME=$(basename "{{FILE}}")
    SAFE=$(echo "$BASENAME" | tr ' ' '_')
    {{KUBECTL}} cp "{{FILE}}" "{{NAMESPACE}}/$POD:/tmp/$SAFE"
    NB="${NOTEBOOK:-${BASENAME%.enex}}"
    {{KUBECTL}} exec -n {{NAMESPACE}} "$POD" -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.import_evernote(\"/tmp/$SAFE\", \"$NB\")"

# Import all .enex files from a directory into k8s
k-import-evernote-dir DIR="enex":
    #!/usr/bin/env bash
    POD=$({{KUBECTL}} get pod -n {{NAMESPACE}} -l app=librarian -o jsonpath='{.items[0].metadata.name}')
    for f in {{DIR}}/*.enex; do
        BASENAME=$(basename "$f")
        NOTEBOOK="${BASENAME%.enex}"
        SAFE=$(echo "$BASENAME" | tr ' ' '_')
        echo "Importing $BASENAME as notebook '$NOTEBOOK'..."
        {{KUBECTL}} cp "$f" "{{NAMESPACE}}/$POD:/tmp/$SAFE"
        {{KUBECTL}} exec -n {{NAMESPACE}} "$POD" -- \
            env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.import_evernote(\"/tmp/$SAFE\", \"$NOTEBOOK\")"
    done

# ── Misc ──────────────────────────────────────────────────────────────────────

# Generate a new SECRET_KEY_BASE
gen-secret:
    mix phx.gen.secret
