# ADR 0002: Docker Compose on one VM for AWS, Kubernetes manifests for kind

- Status: Accepted
- Date: 2026-10-11

## Context

We want to show real cloud deployment (AWS, a Linux virtual machine) and Kubernetes skills, on a small budget.
A managed Kubernetes service (Amazon EKS) and managed databases cost real money every hour and are far more setup than a
"very minor project" needs.

## Decision

- **AWS:** one Ubuntu EC2 instance runs the whole stack with Docker Compose. A manual GitHub Actions workflow deploys a chosen version over SSH.
- **Kubernetes:** the same system is described as Kubernetes manifests (assembled with Kustomize) and tested on a local `kind` cluster.
  The manifests follow production habits: probes, resource requests and limits, non-root read-only containers, a PodDisruptionBudget,
  least-privilege NetworkPolicies, standard labels.
- Prometheus and Grafana configuration is written once and used by both.

## Consequences

- Positive: cheap, simple, and easy to understand end to end.
- Positive: the manifests can later move to EKS with only the data stores and the Service type replaced.
- Negative: a single VM is a single point of failure, with no scaling or rolling updates for the whole stack.
- Negative: the Kubernetes path is verified on `kind`, not on a managed cloud cluster.
