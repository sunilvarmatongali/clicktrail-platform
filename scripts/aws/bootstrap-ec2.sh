#!/usr/bin/env bash
#
# Prepares a fresh Ubuntu 24.04 EC2 instance to run ClickTrail. Safe to run again (idempotent).
#
# Run it ON the VM as the normal user (ubuntu), after copying this repository there:
#   bash scripts/aws/bootstrap-ec2.sh <public-address-of-the-vm>
#
# It does four things:
#   1. installs Docker, the Compose plugin, jq and curl,
#   2. adds a small swap file (a safety net on small machines),
#   3. creates /opt/clicktrail with the stack files,
#   4. creates compose/.env with RANDOM secrets (only if it does not exist yet).

set -euo pipefail

PUBLIC_ADDRESS="${1:-}"
INSTALL_DIR="/opt/clicktrail"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -z "$PUBLIC_ADDRESS" ]]; then
  echo "usage: $0 <public-address-of-the-vm>   (for example 203.0.113.10 or clicktrail.example.com)" >&2
  exit 2
fi
if [[ "$(id -u)" -eq 0 ]]; then
  echo "run this as a normal user (it uses sudo where needed), not as root" >&2
  exit 2
fi

echo "==> Installing Docker and tools"
if ! command -v docker > /dev/null; then
  sudo apt-get update -y
  sudo apt-get install -y docker.io docker-compose-v2 jq curl
  sudo systemctl enable --now docker
fi
sudo usermod -aG docker "$USER"

echo "==> Making sure there is some swap"
if ! swapon --show | grep -q .; then
  sudo fallocate -l 1G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile > /dev/null
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
fi

echo "==> Copying the stack files to ${INSTALL_DIR}"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER":"$USER" "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/compose" "$INSTALL_DIR/observability" "$INSTALL_DIR/scripts"
cp -r "$REPO_ROOT/compose/docker-compose.yml" "$REPO_ROOT/compose/.env.example" "$INSTALL_DIR/compose/"
cp -r "$REPO_ROOT/observability/." "$INSTALL_DIR/observability/"
cp -r "$REPO_ROOT/scripts/." "$INSTALL_DIR/scripts/"

ENV_FILE="$INSTALL_DIR/compose/.env"
if [[ -f "$ENV_FILE" ]]; then
  echo "==> ${ENV_FILE} already exists, keeping it (delete it to generate new secrets)"
else
  echo "==> Creating ${ENV_FILE} with random secrets"
  random() { openssl rand -hex "$1"; }
  umask 077
  cat > "$ENV_FILE" << EOF
GITHUB_OWNER=sunilvarmatongali
CLICKTRAIL_VERSION=0.1.0
PUBLIC_BASE_URL=http://${PUBLIC_ADDRESS}:8080
MYSQL_ROOT_PASSWORD=$(random 16)
MYSQL_PASSWORD=$(random 16)
POSTGRES_PASSWORD=$(random 16)
JWT_SECRET=$(random 32)
GRAFANA_ADMIN_PASSWORD=$(random 12)
ADMIN_EMAIL=admin@clicktrail.example.com
ADMIN_PASSWORD=$(random 12)
EOF
  echo "    The generated admin login and Grafana password are inside ${ENV_FILE}"
fi

echo
echo "Done. Next steps:"
echo "  1. Log out and back in once, so your user may run docker without sudo."
echo "  2. Log in to the image registry (the images are private):"
echo "       echo <github-token-with-read:packages> | docker login ghcr.io -u <github-user> --password-stdin"
echo "  3. Start the stack:   bash ${INSTALL_DIR}/scripts/aws/deploy.sh 0.1.0"
