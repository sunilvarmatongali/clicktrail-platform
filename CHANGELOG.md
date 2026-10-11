# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com) and the project uses
[Semantic Versioning](https://semver.org).

## [0.2.1] - 2026-10-11

### Added
- Grafana panels "Circuit breaker state" and "Refused calls and retries" for the new gateway resilience metrics.
- Runbook and architecture notes for the circuit breaker (`503` with `Retry-After`).

## [0.2.0] - 2026-10-11

### Added
- Secrets are read from AWS Secrets Manager (`clicktrail/prod`) at every deployment through the instance role (ADR 0006).
  `render-env.sh` validates the secret and builds the `.env`; its rules are covered by automated tests that run in CI.
- `export-secrets-json.sh` helps migrate an existing server without changing any password.

### Changed
- `bootstrap-ec2.sh` no longer generates passwords. It creates `config.env` (non-secret settings) and installs the AWS CLI.
- `deploy.sh` splits settings into `config.env` (non-secret) and the secret, and can log in to the image registry using credentials from the secret.

## [0.1.2] - 2026-10-11

### Changed
- The deploy workflow no longer uses SSH: it authenticates with OIDC and deploys through AWS Systems Manager and S3. No secrets or IP settings are stored in GitHub (see ADR 0005 and `docs/aws-deploy-setup.md`).
- `smoke-test.sh` can run without an admin login (the admin-only checks are skipped).

## [0.1.1] - 2026-10-11

### Changed
- Each service version can be set on its own (`GATEWAY_VERSION` and so on), and `deploy.sh` accepts `service=version` overrides.
- The deploy workflow has an optional, strictly validated `overrides` input.

### Fixed
- The smoke test waits for Prometheus to scrape every target instead of checking once.
- The bootstrap script makes the copied scripts executable.

## [0.1.0] - 2026-10-11

### Added
- Docker Compose stack: gateway, auth, URL and analytics services, MySQL, PostgreSQL, MongoDB, Redis, Kafka (KRaft), Prometheus, Grafana.
- Kubernetes manifests (Kustomize) with probes, resource limits, hardened pods, PodDisruptionBudget and NetworkPolicies, plus a `kind` cluster config.
- Grafana dashboard "ClickTrail Overview" and Prometheus configuration shared by Compose and Kubernetes.
- End-to-end smoke test covering the five user stories and the security checks.
- AWS scripts (EC2 bootstrap, deploy) and GitHub Actions workflows (validation CI, manual deploy).
- Product brief, architecture, runbook, release checklist and decision records.
