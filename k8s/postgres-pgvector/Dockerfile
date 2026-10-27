# Postgres 16 + pgvector on the SAME base image the data was created with
# (glibc 2.41), so there is no collation-version mismatch and no REINDEX needed.
# Build + push to the internal registry, then the postgres StatefulSet pulls it.
#
#   docker build --platform linux/arm64 \
#     -t "$LIBRARIAN_REGISTRY/postgres-pgvector:16" k8s/postgres-pgvector/
#   just registry-push postgres-pgvector:16
FROM postgres:16

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-pgvector \
    && rm -rf /var/lib/apt/lists/*
