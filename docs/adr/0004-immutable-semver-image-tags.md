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
- Negative: a release needs a tag per service. In this first version all services share `0.1.0`, so one number selects the whole system.
