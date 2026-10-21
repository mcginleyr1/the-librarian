# The Librarian — task runner
# Usage: just <recipe>

IMAGE := "the-librarian"
NAMESPACE := "librarian"
# Internal registry (exposed via the Tailscale operator): images are built and
# pushed under this name. Override with LIBRARIAN_REGISTRY for your own tailnet.
TS_REGISTRY := env_var_or_default("LIBRARIAN_REGISTRY", "registry.<your-tailnet>.ts.net:5000")
# The same registry as the cluster node pulls the app from (k8s/app.yaml)
CLUSTER_REGISTRY := "localhost:31500"
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

# Needs SECRET_KEY_BASE and ALLOWED_EMAILS exported, e.g.
# `export SECRET_KEY_BASE=$(mix phx.gen.secret) ALLOWED_EMAILS=you@example.com`
# Start full stack in docker (postgres + built app image) — for local image testing only
up:
    @: "${SECRET_KEY_BASE:?export SECRET_KEY_BASE first (generate with: mix phx.gen.secret)}"
    @: "${ALLOWED_EMAILS:?export ALLOWED_EMAILS first (comma-separated sign-in allowlist)}"
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

# Immutable image tag: the jj working-copy commit id (it changes whenever the
# source does), else git HEAD on a clean tree, else a UTC timestamp
_image-tag:
    @jj log -r @ --no-graph -T 'commit_id.short(12)' 2>/dev/null || (git diff --quiet HEAD 2>/dev/null && git rev-parse --short=12 HEAD) || date -u +%Y%m%d%H%M%S

# Tag of the app image currently deployed; the current source tag only when
# nothing is deployed yet (any other kubectl error aborts)
_deployed-tag:
    #!/usr/bin/env bash
    set -euo pipefail
    image=$({{KUBECTL}} get deploy/librarian -n {{NAMESPACE}} --ignore-not-found -o jsonpath='{.spec.template.spec.containers[0].image}')
    if [ -n "$image" ]; then echo "${image##*:}"; else just _image-tag; fi

# Build the app image for the cluster (arm64 node), tagged for the internal registry
docker-build TAG=`just _image-tag`:
    docker build --platform linux/arm64 -t {{TS_REGISTRY}}/{{IMAGE}}:{{TAG}} .

# Build and push the app image to the INTERNAL registry the cluster pulls from.
# Uses registry-push (port-forward) because the Tailscale LB mangles large pushes.
docker-push TAG=`just _image-tag`: (docker-build TAG)
    just registry-push {{IMAGE}}:{{TAG}}

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

# Pins the app image (both containers) to TAG: by default the tag already
# running, so applying config changes never swaps the image — `just deploy` does.
# Apply all k8s manifests via kustomize (does not apply secrets.yaml — use k-create-secrets)
k-apply TAG=`just _deployed-tag`:
    {{KUBECTL}} kustomize k8s/ | sed 's|image: {{CLUSTER_REGISTRY}}/{{IMAGE}}$|&:{{TAG}}|' | {{KUBECTL}} apply -f -

# Reads LIBRARIAN_DB_PASSWORD, GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET from
# the environment, prompting for any that are unset (never CLI args: those end
# up in shell history and `ps`). Re-running keeps the existing secret-key-base,
# so live sessions survive.
# Create/update secrets — run after k-namespace, before k-apply
k-create-secrets: k-namespace
    #!/usr/bin/env bash
    set -euo pipefail
    ask() {
        [ -n "${!1:-}" ] || { read -rsp "$1: " "$1"; echo >&2; }
        [ -n "${!1}" ] || { echo "$1 is required" >&2; exit 1; }
    }
    ask LIBRARIAN_DB_PASSWORD; ask GOOGLE_CLIENT_ID; ask GOOGLE_CLIENT_SECRET
    secret_key_base=$({{KUBECTL}} get secret librarian-secrets -n {{NAMESPACE}} -o jsonpath='{.data.secret-key-base}' 2>/dev/null | base64 -d || true)
    [ -n "$secret_key_base" ] || secret_key_base=$(mix phx.gen.secret)
    {{KUBECTL}} create secret generic librarian-secrets -n {{NAMESPACE}} \
        --from-literal=db-user=librarian \
        --from-file=db-password=<(printf %s "$LIBRARIAN_DB_PASSWORD") \
        --from-file=secret-key-base=<(printf %s "$secret_key_base") \
        --from-file=database-url=<(printf 'ecto://librarian:%s@postgres:5432/librarian_prod' "$LIBRARIAN_DB_PASSWORD") \
        --from-file=google-client-id=<(printf %s "$GOOGLE_CLIENT_ID") \
        --from-file=google-client-secret=<(printf %s "$GOOGLE_CLIENT_SECRET") \
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
    @echo "     - Add your Google account as a test user (Audience page)"
    @echo "       (or hit 'Publish app' so the token doesn't expire after 7 days)"
    @echo ""
    @echo "2. Create the client:"
    @echo "     https://console.cloud.google.com/auth/clients/create"
    @echo "     - Application type: Web application   - Name: librarian"
    @echo "     - Authorized redirect URIs:"
    @echo "         http://localhost:4000/auth/google/callback"
    @echo "         https://{{env_var_or_default("PHX_HOST", "<your-host>")}}/auth/google/callback"
    @echo ""
    @echo "3. Store the credentials (both recipes prompt for unset values; or set"
    @echo "   GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET in the environment):"
    @echo "     just k-set-google-oauth   # existing cluster"
    @echo "     just k-create-secrets     # first deploy (also asks for LIBRARIAN_DB_PASSWORD)"
    @echo "   Local dev reads GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET from the environment."
    open "https://console.cloud.google.com/auth/clients/create"

# Reads GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET from the environment, prompting
# for any that are unset (never CLI args: those end up in shell history and `ps`).
# Patch Google OAuth creds into the secret (keeps db password + secret-key-base), restart app
k-set-google-oauth:
    #!/usr/bin/env bash
    set -euo pipefail
    ask() {
        [ -n "${!1:-}" ] || { read -rsp "$1: " "$1"; echo >&2; }
        [ -n "${!1}" ] || { echo "$1 is required" >&2; exit 1; }
    }
    ask GOOGLE_CLIENT_ID; ask GOOGLE_CLIENT_SECRET
    b64() { printf %s "$1" | base64 | tr -d '\n'; }
    {{KUBECTL}} patch secret librarian-secrets -n {{NAMESPACE}} --type merge --patch-file <(
        printf '{"data":{"google-client-id":"%s","google-client-secret":"%s"}}' \
            "$(b64 "$GOOGLE_CLIENT_ID")" "$(b64 "$GOOGLE_CLIENT_SECRET")")
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

# Restart the app pod on its current image (`just deploy` ships a new one)
k-restart:
    {{KUBECTL}} rollout restart -n {{NAMESPACE}} deploy/librarian

# Open remote IEx shell
k-shell:
    {{KUBECTL}} exec -n {{NAMESPACE}} -it deploy/librarian -- \
        /app/bin/librarian remote

# First deploy: run `just docker-push` then `just k-apply` instead (creates
# everything on that tag); `deploy` needs the Deployment to exist.
# Full deploy: build, push, pin app + migrate init container to the new tag (rolls the pod)
deploy TAG=`just _image-tag`: (docker-push TAG)
    {{KUBECTL}} set image -n {{NAMESPACE}} deploy/librarian \
        migrate={{CLUSTER_REGISTRY}}/{{IMAGE}}:{{TAG}} librarian={{CLUSTER_REGISTRY}}/{{IMAGE}}:{{TAG}}
    {{KUBECTL}} rollout status -n {{NAMESPACE}} deploy/librarian --timeout=10m

# Delete all resources, including the Postgres and data PVCs (destructive!)
[confirm("Delete the librarian namespace and ALL its data (Postgres + vault volumes)? [y/N]")]
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

# Build the Safari clipper (Release, dev-signed) into /Applications so Safari
# treats it as a real app instead of purging it as a weekly "dev thing".
# After it launches once: Safari -> Settings -> Extensions -> enable, then
# paste the API token (app Settings -> AI -> API Access) into the popup.
clipper:
    #!/usr/bin/env bash
    set -euo pipefail
    cd safari-extension/TheLibrarian
    xcodebuild -project TheLibrarian.xcodeproj -scheme "TheLibrarian (macOS)" \
        -configuration Release -derivedDataPath build build
    rm -rf /Applications/TheLibrarian.app
    cp -R "build/Build/Products/Release/TheLibrarian.app" /Applications/
    # xcodebuild registers the build-dir copy with LaunchServices, which shows
    # up as a duplicate extension in Safari — unregister it and delete the dir.
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
        -u "$PWD/build/Build/Products/Release/TheLibrarian.app" || true
    rm -rf build
    open /Applications/TheLibrarian.app
    echo "Installed /Applications/TheLibrarian.app — now enable it in Safari Settings -> Extensions"
