# ADR 0004: Deploy immutable, semantically versioned image tags

- Status: Accepted
- Date: 2026-10-11

## Context

We must always know exactly what is running, be able to roll back, and avoid "it changed by itself".

## Decision

Each service image is published as `ghcr.io/sunilvarmatongali/clicktrail-<service>:<MAJOR.MINOR.PATCH>` when a `vX.Y.Z` tag is pushed.
The deployment files pin exact versions and never use `latest`. Deploying means choosing versions; rolling back means
choosing the previous versions.

## Consequences

- Positive: reproducible deployments, an audit trail (the version is in git), simple rollback.
- Negative: a release needs a tag per service.
- A shared `CLICKTRAIL_VERSION` selects the whole system, and each service can be overridden on its own
  (`GATEWAY_VERSION`, `AUTH_SERVICE_VERSION`, ...). This was added after the first patch release (gateway `0.1.1`)
  showed that one number for all services is not enough. `deploy.sh 0.1.0 gateway=0.1.1` sets it.
