# Postgres 16 + pgvector on the SAME base image the data was created with
# (glibc 2.41), so there is no collation-version mismatch and no REINDEX needed.
# Built and pushed to the local Tailscale registry; referenced by k8s/postgres.yaml.
FROM postgres:16

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-16-pgvector \
    && rm -rf /var/lib/apt/lists/*
