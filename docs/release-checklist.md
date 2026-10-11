# Release checklist: from local folders to GitHub to a running stack

Nothing has been pushed yet. Work through this list top to bottom. Every step is small and reversible until you push.

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
