# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com) and the project uses
[Semantic Versioning](https://semver.org).

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
