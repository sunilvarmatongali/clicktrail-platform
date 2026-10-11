# ADR 0001: One repository per service, plus a platform repository

- Status: Accepted
- Date: 2026-10-11

## Context

ClickTrail is built from independent microservices. We want each to be built, tested, versioned and released on its own,
the way separate teams would work in a larger company.

## Decision

Every service and the shared gRPC contract have their own repository and pipeline. Everything that is not service code
(deployment, observability, end-to-end tests, product and architecture documents) lives in `clicktrail-platform`.
Services publish container images with semantic versions; the platform repository chooses which versions run together.

## Consequences

- Positive: independent releases, clear ownership, small repositories, per-service access control.
- Positive: deployment concerns are separate from application code.
- Negative: cross-service changes need several pull requests and a version bump of the shared contract.
- Negative: some small helper code is duplicated between services. A shared library would remove that in a bigger organisation.
- Alternative considered: one monorepo with path-filtered pipelines. Easier day to day, but it hides the independent-deployment story.
