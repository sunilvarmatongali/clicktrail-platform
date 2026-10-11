# Runbook: how to run and operate ClickTrail

## 1. Run everything on one machine with Docker Compose

Needs Docker with the Compose plugin. The images must exist in the registry (see [release-checklist.md](release-checklist.md)).

```bash
cd compose
cp .env.example .env        # fill in the secrets: use letters and digits only, for example `openssl rand -hex 16`
docker login ghcr.io        # only if the images are private (user + token with read:packages)
docker compose up -d --wait
../scripts/smoke-test.sh http://localhost:8080 "$ADMIN_EMAIL" "$ADMIN_PASSWORD"
```

- API: `http://localhost:8080`
- Grafana: `http://localhost:3000` (user `admin`, password from `GRAFANA_ADMIN_PASSWORD`), dashboard **ClickTrail Overview**
- Prometheus: `http://localhost:9090` (Status -> Targets: every target must be `UP`)
- Stop: `docker compose down` (add `-v` to delete the data too)

First start takes a few minutes (Kafka and the databases initialise). `--wait` returns when everything is healthy.

## 2. Run on Kubernetes (kind) on your machine

Needs Docker, [kind](https://kind.sigs.k8s.io), kubectl, jq, and `compose/.env`.

```bash
export GHCR_USER=<github-user> GHCR_TOKEN=<token with read:packages>   # only for private images
scripts/k8s/deploy-kind.sh
```

The script creates the cluster, creates the secrets from `compose/.env`, applies the manifests, waits for readiness
and runs the smoke test against `http://localhost:8080`.

## 3. Deploying to AWS (one EC2 VM)

### One-time setup

1. **Launch an instance**: Ubuntu 24.04 LTS, **t3.medium (4 GB RAM)**, 20 GB gp3 disk.
   Why not smaller? The stack runs Kafka, MySQL, PostgreSQL, MongoDB, Redis, Prometheus and Grafana, which need about
   2.5 GB. A free-tier t3.micro (1 GB) cannot run it. Check the current price of the instance type before you start.
2. **Security group** (inbound rules): `22` from **your IP only**, `8080` from anywhere. Nothing else.
3. **Elastic IP** (optional but handy): keeps the address stable across stop/start.
4. Copy this repository to the VM and run the bootstrap (it installs Docker and the AWS CLI, creates `/opt/clicktrail` and the
   non-secret `config.env`; it creates **no** passwords):
   ```bash
   scp -r clicktrail-platform ubuntu@<vm-address>:~/
   ssh ubuntu@<vm-address> 'bash ~/clicktrail-platform/scripts/aws/bootstrap-ec2.sh <vm-address>'
   ```
5. **Secrets**: create the secret `clicktrail/prod` in AWS Secrets Manager and allow the instance role to read it
   ([aws-deploy-setup.md](aws-deploy-setup.md), section 6). Deployments read it themselves, including the image-registry token if you store it there.
6. **GitHub deployment access** (one time): follow [aws-deploy-setup.md](aws-deploy-setup.md). It creates a static address
   (Elastic IP), a small S3 bucket, an instance role for AWS Systems Manager and a key-less, short-lived AWS role for GitHub (OIDC).
   The result: **no SSH, no keys and no secrets in GitHub**, only four non-secret repository variables.

### Every deployment

Run the **deploy** workflow (Actions tab -> deploy -> Run workflow) and enter the version, for example `0.1.0`.
It gets temporary AWS permissions, uploads the stack files to S3, tells the instance (by its ID, through AWS Systems Manager) to download them and run `scripts/aws/deploy.sh` (pull, start, wait for health, smoke test), and finally runs the smoke test **from the runner against the public address**, which also proves that the internal ports are closed.

Manual alternative on the VM: `bash /opt/clicktrail/scripts/aws/deploy.sh 0.1.0`

### Look at the dashboards

Grafana and Prometheus listen on the VM's `localhost` only. Use an SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ubuntu@<vm-address>
# then open http://localhost:3000 and http://localhost:9090 on your own machine
```

### Stop paying when you are done

Stop (or terminate) the instance after testing. A stopped instance does not charge for compute but still charges for its
disk and for an unattached Elastic IP. Remove what you do not need.

## 4. Everyday operations

| Task | Command (in `compose/`) |
|---|---|
| See container health | `docker compose ps` |
| Follow the logs of a service | `docker compose logs -f gateway` |
| Find one request across all services | `docker compose logs \| grep <traceId>` (the `traceId` is in every error response) |
| Restart one service | `docker compose restart url-service` |
| Upgrade one service | `bash /opt/clicktrail/scripts/aws/deploy.sh 0.1.0 gateway=0.1.1` (everything at 0.1.0, the gateway at 0.1.1) |
| Upgrade everything | `bash /opt/clicktrail/scripts/aws/deploy.sh 0.2.0` |
| Roll back | deploy the previous version numbers again |

## 5. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `docker compose pull` says "unauthorized" | Not logged in to `ghcr.io`, or the token lacks `read:packages` |
| Service keeps restarting | `docker compose logs <service>`: the first lines show which setting is wrong |
| `/r/<code>` returns 502 | url-service is down; `docker compose ps` and check its logs |
| Clicks do not appear in statistics | `docker compose logs analytics-service`; check the Kafka lag panel in Grafana |
| Everything gets `429` | The client address sent too many requests; wait one minute |
| Login works but admin gets `403` | You are logged in as a normal user; the admin account is the one in `ADMIN_EMAIL` |
| Smoke test fails at step 0 | Stack not ready yet; wait and run it again |
| Short links show `localhost` | `PUBLIC_BASE_URL` in `config.env` is wrong; set it to the public address and deploy again (or restart url-service) |
| Deployment fails: "AccessDenied" reading the secret | The instance role lacks the `clicktrail-read-secret` policy, or the secret name or region differs |
| Deployment fails: "the secret has no value for ..." or "characters that are not allowed" | The secret is incomplete or contains a character outside the allowed set (see section 6.1 of the setup guide) |

## 6. Security housekeeping

- On AWS the secrets live in **AWS Secrets Manager** (`clicktrail/prod`). Never edit `/opt/clicktrail/compose/.env` by hand: it is rebuilt at every
  deployment. To change a secret, change it in Secrets Manager and run the deploy workflow again (see [aws-deploy-setup.md](aws-deploy-setup.md), section 6.4).
  Changing `JWT_SECRET` logs everyone out; it is identical for the auth service and the gateway because both read the same secret.
- Non-secret settings (versions, public address) are in `/opt/clicktrail/compose/config.env`.
- For local use outside AWS you still write a `.env` by hand from `.env.example` (never commit it).
- The databases keep their original passwords in their volumes. To change those, change them inside the database first.
- Keep the instance patched: `sudo apt-get update && sudo apt-get upgrade`.
