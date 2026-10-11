#!/usr/bin/env bash
#
# Creates a local Kubernetes cluster (kind) and deploys ClickTrail into it.
#
#   scripts/k8s/deploy-kind.sh
#
# Needs: docker, kind, kubectl, jq, curl, and compose/.env (copy compose/.env.example and fill it in).
# For private images also export GHCR_USER and GHCR_TOKEN (a GitHub token with the read:packages permission).
#
# Re-running is safe: the cluster is reused, secrets and manifests are re-applied.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="${REPO_ROOT}/compose/.env"
NAMESPACE="clicktrail"
CLUSTER_NAME="clicktrail"

for tool in docker kind kubectl jq curl; do
  command -v "$tool" > /dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
[[ -f "$ENV_FILE" ]] || { echo "${ENV_FILE} not found: copy compose/.env.example and fill it in" >&2; exit 1; }

# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a

echo "==> Cluster"
if ! kind get clusters | grep -qx "$CLUSTER_NAME"; then
  kind create cluster --config "${REPO_ROOT}/k8s/kind-cluster.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" > /dev/null

echo "==> Namespace and secrets"
kubectl apply -f "${REPO_ROOT}/k8s/namespace.yaml"

# All secrets are created from compose/.env, so there is a single place to change them.
kubectl -n "$NAMESPACE" create secret generic clicktrail-secrets \
  --from-literal=auth-database-dsn="clicktrail:${MYSQL_PASSWORD}@tcp(mysql:3306)/auth?charset=utf8mb4&parseTime=True&loc=UTC" \
  --from-literal=url-database-dsn="host=postgres user=clicktrail password=${POSTGRES_PASSWORD} dbname=links port=5432 sslmode=disable TimeZone=UTC" \
  --from-literal=jwt-secret="${JWT_SECRET}" \
  --from-literal=admin-email="${ADMIN_EMAIL}" \
  --from-literal=admin-password="${ADMIN_PASSWORD}" \
  --from-literal=mysql-password="${MYSQL_PASSWORD}" \
  --from-literal=mysql-root-password="${MYSQL_ROOT_PASSWORD}" \
  --from-literal=postgres-password="${POSTGRES_PASSWORD}" \
  --from-literal=grafana-admin-password="${GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${GHCR_USER:-}" && -n "${GHCR_TOKEN:-}" ]]; then
  kubectl -n "$NAMESPACE" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  # The pods reference a pull secret; an empty one keeps them valid when the images are public.
  kubectl -n "$NAMESPACE" create secret generic ghcr-pull --dry-run=client -o yaml | kubectl apply -f -
fi

echo "==> Applying manifests"
kubectl kustomize "${REPO_ROOT}/k8s" --load-restrictor LoadRestrictionsNone | kubectl apply -f -

echo "==> Waiting for everything to become ready (the first start can take a few minutes)"
for workload in mysql postgres mongo redis kafka auth-service url-service analytics-service gateway prometheus grafana; do
  kubectl -n "$NAMESPACE" rollout status "deployment/${workload}" --timeout=300s
done
kubectl -n "$NAMESPACE" wait --for=condition=complete job/kafka-init --timeout=300s

echo "==> Smoke test through http://localhost:8080"
"${REPO_ROOT}/scripts/smoke-test.sh" "http://localhost:8080" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"

echo "==> Done. Useful commands:"
echo "    kubectl -n ${NAMESPACE} get pods"
echo "    kubectl -n ${NAMESPACE} port-forward svc/grafana 3000:3000   # then open http://localhost:3000"
echo "    kind delete cluster --name ${CLUSTER_NAME}                    # remove everything"
