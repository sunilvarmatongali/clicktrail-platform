# ClickTrail

A small, production-style **URL shortener with click analytics**, built as five Go microservices.
This repository is the home of the platform: how the pieces run together, how they are deployed and how they are observed.

> Short links in, click statistics out. Built to demonstrate Go microservices end to end: REST and gRPC APIs,
> JWT and role-based security, MySQL, PostgreSQL, MongoDB, Redis, Kafka, Docker, Kubernetes, AWS, CI/CD, Prometheus and Grafana.

## The repositories

| Repository | What it is |
|---|---|
| [`clicktrail-gateway`](https://github.com/sunilvarmatongali/clicktrail-gateway) | The only public entry point: authentication, RBAC, rate limiting, forwarding |
| [`clicktrail-auth-service`](https://github.com/sunilvarmatongali/clicktrail-auth-service) | Register, log in, issue tokens (Gin, GORM, MySQL) |
| [`clicktrail-url-service`](https://github.com/sunilvarmatongali/clicktrail-url-service) | Create and open short links (Gin, GORM, PostgreSQL, Redis, Kafka producer) |
| [`clicktrail-analytics-service`](https://github.com/sunilvarmatongali/clicktrail-analytics-service) | Count clicks (Kafka consumer, MongoDB, gRPC) |
| [`clicktrail-proto`](https://github.com/sunilvarmatongali/clicktrail-proto) | The shared gRPC contract |
| **`clicktrail-platform`** (this repo) | Docker Compose, Kubernetes, Prometheus, Grafana, AWS scripts, smoke test, documentation |

## Start here

| I want to... | Read |
|---|---|
| understand what the product does | [docs/product-brief.md](docs/product-brief.md) |
| see how the pieces fit together | [docs/architecture.md](docs/architecture.md) |
| run it (Docker, Kubernetes, AWS) | [docs/runbook.md](docs/runbook.md) |
| publish the code and go live | [docs/release-checklist.md](docs/release-checklist.md) |
| understand why a decision was made | [docs/adr/](docs/adr/) |

## Quick start (needs Docker)

```bash
cd compose
cp .env.example .env      # fill in the secrets (letters and digits only)
docker compose up -d --wait
../scripts/smoke-test.sh http://localhost:8080 admin@example.com '<your ADMIN_PASSWORD>'
```

Then open Grafana at http://localhost:3000 and look at the **ClickTrail Overview** dashboard.

## What is in this repository

```
compose/            Docker Compose stack (all services, data stores, Prometheus, Grafana)
k8s/                Kubernetes manifests (Kustomize) and a kind cluster config
observability/      Prometheus config and the Grafana dashboard (shared by Compose and Kubernetes)
scripts/            smoke-test.sh (end-to-end checks), aws/ (EC2 setup and deploy), k8s/ (kind deploy)
docs/               product brief, architecture, runbook, release checklist, decision records (ADRs)
.github/workflows/  ci.yml (validates everything), deploy.yml (manual deployment to AWS)
```

## How it is checked

- Every service repository has its own pipeline: format, lint, unit tests, integration tests against the real database,
  vulnerability scan and a Docker build.
- This repository's `ci.yml` validates the Compose file, the Kubernetes manifests, the Prometheus config, the dashboard and
  the shell scripts, and scans for committed secrets.
- `scripts/smoke-test.sh` proves the user stories and the security rules against a running stack, including that internal
  ports are not reachable from outside.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [CHANGELOG.md](CHANGELOG.md) for releases.
