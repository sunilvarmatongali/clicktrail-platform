# Release checklist: from local folders to GitHub to a running stack

## Status (2026-10-11)

| Step | State |
|---|---|
| 0. Decide proto visibility | Done: `clicktrail-proto` is **public**, the other five are **private** |
| 1. Remove local `replace` lines | Done (gateway and analytics use the published `clicktrail-proto v0.1.0`) |
| 2. Create repositories and push | Done: all six repositories, tag `v0.1.0` on each |
| 3. Repository settings | Partly done: Dependabot alerts and security updates are on everywhere; branch protection is on for `clicktrail-proto` only, because GitHub's free plan does not offer it for private repositories (it asks for GitHub Pro, or make the repository public) |
| 4. First green pipelines | Done: `ci` is green on `main` in all six repositories, including the integration tests against real MySQL, PostgreSQL and MongoDB; the `release` workflows published the `0.1.0` images |
| 5. Run it for real | Done on one EC2 VM (2026-10-11): all 12 containers healthy, `scripts/smoke-test.sh` 27 passed / 0 failed, internal ports checked closed from the internet. A gateway patch (`0.1.1`) was then deployed alone with `deploy.sh 0.1.0 gateway=0.1.1`. The GitHub **deploy** workflow has also run successfully (OIDC + SSM + S3, no SSH, no secrets): 27 checks passed on the VM and 36 from the public internet. Not yet run: the Kubernetes path on `kind` |
| 6. Record the results | Done: real EXPLAIN numbers are in `clicktrail-url-service/docs/query-optimization.md` (19.6 ms -> 0.07 ms) |
| Secrets | Done: secrets are read from AWS Secrets Manager (`clicktrail/prod`) at every deployment; verified on the server (27 + 36 checks passed, no secret in any log) |
| 7. Afterwards | Not yet |

Dependabot opened pull requests for newer versions of GitHub Actions and libraries as soon as the repositories were created.
Review them one by one: read what changed, wait for `ci` to pass, then merge or close. Major-version bumps of actions
(for example `actions/checkout`) can need small workflow changes, so a failing pipeline on such a pull request is normal.

---

The steps below are the full procedure (steps 0 to 4 are already done, see the status table above).

## 0. Decide first: should `clicktrail-proto` be public?

The gateway and the analytics service download `clicktrail-proto` as a Go module, in CI and during `docker build`.
A **private** repository needs credentials for that. Two ways:

| Option | What it means |
|---|---|
| **A. Make `clicktrail-proto` public (recommended)** | It only contains the gRPC contract, no secrets and no business logic. Everything just works. |
| B. Keep it private | Every pipeline and Dockerfile needs `GOPRIVATE=github.com/sunilvarmatongali/*` and a token (BuildKit secret + `git config url.insteadOf`). More moving parts. |

The other five repositories can stay private first, as you wished.

## 1. Remove the temporary local `replace` lines

`clicktrail-gateway` and `clicktrail-analytics-service` point to the sibling folder while developing. In both repos:

```bash
go mod edit -dropreplace github.com/sunilvarmatongali/clicktrail-proto
go get github.com/sunilvarmatongali/clicktrail-proto@v0.1.0   # works once the proto repo is pushed and tagged
go mod tidy && make verify
git commit -am "chore: use the published clicktrail-proto module" && git tag -f v0.1.0
```

## 2. Create the repositories and push, in this order

Create each as an **empty** repository (no README, license or .gitignore: they already exist locally).

1. `clicktrail-proto` -> push `main` and the tag: `git push -u origin main && git push origin v0.1.0`
2. `clicktrail-auth-service`, `clicktrail-url-service`, `clicktrail-analytics-service`, `clicktrail-gateway` (same commands).
   Pushing the tag `v0.1.0` starts the **release** workflow, which builds and publishes the image to GitHub Container Registry.
3. `clicktrail-platform`.

Local commit author is `sunilvarmatongali@users.noreply.github.com`. If GitHub does not link your commits to your profile,
change it with `git config user.email` and rewrite the history **before** pushing.

## 3. Repository settings (each repo: Settings)

- [ ] Branch protection on `main`: require a pull request, require the `ci` checks, no force pushes.
- [ ] Code security: enable Dependabot alerts, secret scanning and push protection.
- [ ] Actions -> General -> "Workflow permissions": read-only by default (the workflows request what they need).
- [ ] Packages (after the first release): confirm the image visibility. Private images need a pull token on the VM and in Kubernetes.

## 4. First green pipelines

- [ ] `ci` is green on `main` in all six repositories. This is the first time the integration tests run against real
      MySQL, PostgreSQL and MongoDB and the Docker images are built. **If something fails here, fix it before going on.**
- [ ] The `release` workflow of each service finished and the image `ghcr.io/sunilvarmatongali/clicktrail-<service>:0.1.0` exists.

## 5. Run it for real

- [ ] AWS: follow [runbook.md](runbook.md), section 3 (instance, security group, bootstrap, secrets).
- [ ] Run the **deploy** workflow with version `0.1.0`. The smoke test must end with `0 failed`.
- [ ] Open Grafana through the SSH tunnel and look at **ClickTrail Overview** while you click a link a few times.
- [ ] Optionally also run `scripts/k8s/deploy-kind.sh` on a machine with Docker.

## 6. Record the results (do not invent numbers)

- [ ] Run `scripts/explain-owner-query.sql` (in `clicktrail-url-service`) against the database and paste the real
      `Execution Time` values into `docs/query-optimization.md`.
- [ ] Note anything that failed first time and what fixed it; that is excellent interview material.

## 7. Afterwards

- [ ] Stop or terminate the EC2 instance and release the Elastic IP if you do not need them.
- [ ] Make the repositories public when you are happy with them (check that no secrets are in the history first).
- [ ] Add the repository links to your Naukri profile (Accomplishments -> Work sample) and a project entry.
