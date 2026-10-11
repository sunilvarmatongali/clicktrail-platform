# Changelog

All notable changes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com) and the project uses
[Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-10-11

### Added
- Docker Compose stack: gateway, auth, URL and analytics services, MySQL, PostgreSQL, MongoDB, Redis, Kafka (KRaft), Prometheus, Grafana.
- Kubernetes manifests (Kustomize) with probes, resource limits, hardened pods, PodDisruptionBudget and NetworkPolicies, plus a `kind` cluster config.
- Grafana dashboard "ClickTrail Overview" and Prometheus configuration shared by Compose and Kubernetes.
- End-to-end smoke test covering the five user stories and the security checks.
- AWS scripts (EC2 bootstrap, deploy) and GitHub Actions workflows (validation CI, manual deploy).
- Product brief, architecture, runbook, release checklist and decision records.
