# The Librarian — task runner
# Usage: just <recipe>

REGISTRY := "registry.tailf742b.ts.net:5000"
IMAGE := "the-librarian"
NAMESPACE := "librarian"

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

# Build Docker image
docker-build:
    docker build -t {{REGISTRY}}/{{IMAGE}}:latest .

# Push to local Tailscale registry
docker-push: docker-build
    docker push {{REGISTRY}}/{{IMAGE}}:latest

# ── K8s ───────────────────────────────────────────────────────────────────────

# Apply namespace only (needed before k-create-secrets on first deploy)
k-namespace:
    kubectl apply -f k8s/namespace.yaml

# Apply all k8s manifests via kustomize (does not apply secrets.yaml — use k-create-secrets)
k-apply:
    kubectl apply -k k8s/

# Create secrets — run after k-namespace, before k-apply
k-create-secrets db-password: k-namespace
    kubectl create secret generic librarian-secrets -n {{NAMESPACE}} \
        --from-literal=db-user=librarian \
        --from-literal=db-password={{db-password}} \
        --from-literal=secret-key-base=$(mix phx.gen.secret) \
        --from-literal=database-url=ecto://librarian:{{db-password}}@postgres:5432/librarian_prod \
        --save-config --dry-run=client -o yaml | kubectl apply -f -

# Run Ecto migrations in cluster
k-migrate:
    kubectl exec -n {{NAMESPACE}} deploy/librarian -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.migrate()"

# Tail app logs
k-logs:
    kubectl logs -n {{NAMESPACE}} -f deploy/librarian

# Show pod/pvc/ingress status
k-status:
    kubectl get pods,pvc,ingress -n {{NAMESPACE}}

# Rolling restart (picks up new image)
k-restart:
    kubectl rollout restart -n {{NAMESPACE}} deploy/librarian

# Open remote IEx shell
k-shell:
    kubectl exec -n {{NAMESPACE}} -it deploy/librarian -- \
        /app/bin/librarian remote

# Full deploy: build, push, restart
deploy: docker-push k-restart

# Delete all resources (destructive!)
k-teardown:
    kubectl delete namespace {{NAMESPACE}}

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
    POD=$(kubectl get pod -n {{NAMESPACE}} -l app=librarian -o jsonpath='{.items[0].metadata.name}')
    kubectl cp "{{FILE}}" "{{NAMESPACE}}/$POD:/tmp/opml_import.opml"
    kubectl exec -n {{NAMESPACE}} "$POD" -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.import_opml(\"/tmp/opml_import.opml\")"

# Import a single .enex file into k8s
k-import-evernote FILE NOTEBOOK="":
    #!/usr/bin/env bash
    POD=$(kubectl get pod -n {{NAMESPACE}} -l app=librarian -o jsonpath='{.items[0].metadata.name}')
    BASENAME=$(basename "{{FILE}}")
    SAFE=$(echo "$BASENAME" | tr ' ' '_')
    kubectl cp "{{FILE}}" "{{NAMESPACE}}/$POD:/tmp/$SAFE"
    NB="${NOTEBOOK:-${BASENAME%.enex}}"
    kubectl exec -n {{NAMESPACE}} "$POD" -- \
        env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.import_evernote(\"/tmp/$SAFE\", \"$NB\")"

# Import all .enex files from a directory into k8s
k-import-evernote-dir DIR="enex":
    #!/usr/bin/env bash
    POD=$(kubectl get pod -n {{NAMESPACE}} -l app=librarian -o jsonpath='{.items[0].metadata.name}')
    for f in {{DIR}}/*.enex; do
        BASENAME=$(basename "$f")
        NOTEBOOK="${BASENAME%.enex}"
        SAFE=$(echo "$BASENAME" | tr ' ' '_')
        echo "Importing $BASENAME as notebook '$NOTEBOOK'..."
        kubectl cp "$f" "{{NAMESPACE}}/$POD:/tmp/$SAFE"
        kubectl exec -n {{NAMESPACE}} "$POD" -- \
            env -u PHX_SERVER /app/bin/librarian eval "Librarian.Release.import_evernote(\"/tmp/$SAFE\", \"$NOTEBOOK\")"
    done

# ── Misc ──────────────────────────────────────────────────────────────────────

# Generate a new SECRET_KEY_BASE
gen-secret:
    mix phx.gen.secret
