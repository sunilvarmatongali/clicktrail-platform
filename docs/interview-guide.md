# Explaining ClickTrail in an interview

Use this to rehearse. Everything here is true of the project as built. The last sections list what you must NOT claim and
how to answer honestly when you are asked about gaps. Honesty about trade-offs impresses interviewers more than inflated claims.

---

## 1. The 30-second pitch

"ClickTrail is a URL shortener with click analytics, built as four Go microservices behind an API gateway. Users register,
create short links and see how often each link was opened. The services talk synchronously over REST and gRPC for requests,
and asynchronously through Kafka for click events, so redirects stay fast even when analytics is slow. It has JWT security with
role-based access, Redis caching and rate limiting, three different databases, Prometheus and Grafana, CI/CD with GitHub
Actions, and it runs on AWS EC2 with Docker Compose. Kubernetes manifests are included as the scalable path."

## 2. The 2-minute walkthrough (say it in this order)

1. **Problem and use.** Shorten a long URL, redirect visitors, tell the owner how many clicks it got. Small domain, chosen so
   every microservice concept has a natural job.
2. **Architecture.** One public door, the **gateway**. Behind it: **auth-service** (users, passwords, tokens),
   **url-service** (links and redirects), **analytics-service** (click counting). Each service owns its own database.
3. **Communication.** Synchronous for things the user waits for (login, create link, redirect, statistics). Asynchronous for
   the click: the redirect drops an event on Kafka and returns; analytics consumes it later. A new link is announced through a
   **transactional outbox**, so the event is never lost even if Kafka is down at that moment.
4. **Resilience.** Cache, queue and rate limiter failures never break a redirect. A failing service gives a clean `502` with a
   trace ID. Click events are acknowledged only after they are stored, and duplicates are ignored.
5. **Security.** Only the gateway is public. It verifies the JWT, enforces roles, rate-limits, and deletes any identity headers a
   client sends. Containers are non-root with read-only filesystems.
6. **Delivery.** Six repositories, each with its own pipeline (lint, tests against real databases, vulnerability scan, image build).
   A tag publishes a versioned image. Deployment is a manual GitHub workflow that uses short-lived AWS credentials (OIDC) and
   AWS Systems Manager: no SSH, no stored keys.
7. **Proof.** An end-to-end smoke test (27 checks on the server, 36 from the internet) and measured results, for example a
   database query that went from 19.6 ms to 0.07 ms after adding an index.

---

## 3. Architecture and technology, with the reason for each choice

```
Browser --> gateway (:8080, the ONLY public port)
              |-- HTTP --> auth-service ----> MySQL
              |-- HTTP --> url-service  ----> PostgreSQL, Redis (cache)
              |                  |
              |                  '-- publishes click event --> Kafka --> analytics-service --> MongoDB
              '-- gRPC --> analytics-service (click counts)
Prometheus scrapes all of them; Grafana draws the dashboard. Redis also holds the gateway's rate-limit counters.
```

| Technology | Where | Why this choice |
|---|---|---|
| Go | all services | Small static binaries, fast start-up, simple concurrency, strong standard library |
| Gin | HTTP APIs | Fast, minimal router with validation; middleware chain for logging, metrics, auth |
| GORM + SQL migrations | auth, url | GORM for queries; plain versioned SQL files (golang-migrate) so every schema change is reviewable |
| MySQL | auth-service | Users and credentials: relational, unique email constraint |
| PostgreSQL | url-service | Links: relational, unique short code, composite index for the "my links" query |
| MongoDB | analytics-service | Click events: append-heavy, document per event, counted by index |
| Redis | url-service, gateway | Cache-aside for redirects; shared counters for rate limiting |
| Kafka (KRaft, 1 node) | url -> analytics | Decouples the redirect from click counting; durable buffer; replayable |
| gRPC + protobuf | gateway -> analytics | Strict, versioned contract in its own repo; efficient internal calls |
| JWT (HS256) | auth -> gateway | Stateless identity and role, checked without calling auth again |
| Docker, Compose | runtime | Same image everywhere; Compose runs the whole stack on one VM |
| Kubernetes (Kustomize) | manifests | The scalable path: probes, limits, hardened pods, network policies |
| AWS EC2, SSM, S3, IAM OIDC | production | One VM; keyless deployment with an audit trail |
| AWS Secrets Manager | secrets | One JSON secret read at deploy time through the instance role; central, audited, rotatable |
| GitHub Actions | CI/CD | Per-repository pipelines and a manual deploy workflow |
| Prometheus + Grafana | observability | Standard metrics pipeline and dashboard |

Honest note: three different databases is a deliberate **learning and demonstration choice**. In a real product with this tiny domain
you would likely use one PostgreSQL plus Redis. Say so if asked; it shows judgement.

## 4. What each service does

**gateway** (public, port 8080; operations port 8090)
- Verifies the JWT (HS256 only, issuer and expiry required, known role), then forwards the caller's identity to services as `X-User-Id` / `X-User-Role`.
- Deletes those headers if a client sent them, so identity cannot be forged.
- RBAC: `/api/v1/admin/*` only for role `admin` (otherwise 403).
- Redis rate limiting per client address: 120 requests/minute, and 10/minute for register and login.
- Reverse-proxies to auth and url services; answers statistics itself with one gRPC call to analytics, which also checks that the caller owns the link.
- Creates the request ID that all services log (follow one request through all logs).

**auth-service** (MySQL)
- Register (bcrypt-hashed password, role `user`) and login (JWT, 15 minutes). Same error for unknown email and wrong password, and a dummy hash comparison so timing does not reveal which emails exist.
- Creates the first admin from environment variables on start-up.

**url-service** (PostgreSQL, Redis, Kafka producer)
- Create a link (random 7-character code, retry on the rare collision thanks to the unique index), list my links, owner-only get. Creating a link saves the link **and** a `LinkCreated` row in the outbox table in one transaction; a background relay sends the row to Kafka.
- Redirect `GET /r/{code}`: Redis first, PostgreSQL on a miss, answer **302** (not 301, or browsers would cache it and clicks would never be counted), then publish a `LinkClicked` event.
- Only `http`/`https` URLs are accepted (blocks `javascript:` and `file:`).

**analytics-service** (Kafka consumer, MongoDB, gRPC)
- Reads click events, stores each as a document whose `_id` is the event ID, and serves counts over gRPC.
- Reads `LinkCreated` events and keeps a small copy "short code -> owner" (a **read model**), so it can answer "how many clicks does *my* link have?" on its own.
- Exposes consumer lag as a metric.

**clicktrail-proto**: the gRPC contract, versioned and shared by gateway and analytics. **clicktrail-platform**: deployment, observability, smoke test, docs.

---

## 5. The three main flows

**A. Register and log in.** Client -> gateway (rate limit, no token needed) -> auth-service -> MySQL. Login returns a JWT with user ID, email and role.

**B. Create and open a link.**
1. `POST /api/v1/links` with the token. Gateway verifies it, sets `X-User-Id`, forwards to url-service.
2. url-service validates the URL, generates a code, and in **one transaction** inserts the link and an outbox row. Returns the short URL. A relay then publishes `LinkCreated` to Kafka and analytics stores the owner.
3. Anyone opens `/r/{code}`: gateway (rate limit) -> url-service -> Redis hit or PostgreSQL -> **302** to the original URL.
4. In the same request url-service publishes the click event to Kafka **asynchronously** and does not wait.

**C. See statistics.** `GET /api/v1/links/{code}/stats` -> gateway verifies the token -> one gRPC call to analytics-service with the code and the user ID from the token ->
analytics checks its own copy of the owners and returns the count. Another user's link gives `404` (same answer as "does not exist", so codes cannot be probed).
A link created a second ago may give `404` for a moment (eventual consistency).

---

## 6. Synchronous versus asynchronous communication

| Call | Style | Why |
|---|---|---|
| client -> gateway -> auth / url | synchronous HTTP | The user waits for the answer |
| gateway -> analytics (counts) | synchronous gRPC | The user waits for the number; strict typed contract |
| url-service -> analytics (click) | **asynchronous via Kafka** | The redirect must not wait for, or depend on, analytics |
| url-service -> analytics (new link, owner) | **asynchronous via Kafka + transactional outbox** | Statistics must not depend on url-service being up; the event must not be lost |

Why Kafka for the click: it **decouples** the services in time and availability. url-service does not know analytics exists. If analytics is
down or slow, redirects are unaffected and the events wait in Kafka (retention) until it is back. The cost is **eventual consistency**: a click
appears in the statistics after a short delay (seconds).

**Delivery guarantees (be able to explain this):**
- Producer side, clicks: asynchronous and best effort (a failed publish is logged, the redirect still succeeds).
- Producer side, new links: **transactional outbox**. The link and the event row are saved in one database transaction; a relay sends the row, waits for Kafka's confirmation and only then marks it sent. At-least-once, never lost.
- Consumer side: **at-least-once**. Process, store, then commit the offset. A crash between store and commit means Kafka resends.
- **Idempotent consumer**: the event ID is the MongoDB `_id`, so a resent event is ignored. Net effect: each click counted once.
- Messages that can never be parsed are counted and skipped so they cannot block the topic (a dead-letter topic is the next step).

## 7. What happens when something is down

| Failure | What the user sees | What happens inside |
|---|---|---|
| **Redis down** | Everything works | url-service falls back to PostgreSQL; the gateway's rate limiter **fails open** (logs a warning) |
| **Kafka down** | Redirects and **link creation** work | Clicks during the outage are not counted (best effort). New-link events wait in the outbox table and are sent when Kafka is back |
| **analytics-service down** | Statistics return `502` | Redirects work; click events pile up in Kafka and are processed after recovery, nothing lost |
| **MongoDB down** | Statistics fail | Consumer retries with exponential backoff (0.5 s up to 30 s) and does **not** commit, so no click is lost; lag grows and is visible in Grafana |
| **PostgreSQL down** | Create/list fail; **cached links still redirect** | Redis answers cache hits without touching the database |
| **MySQL down** | Login/register fail | Existing tokens keep working until they expire (stateless JWT) |
| **url-service down** | Link APIs and redirects return `502` | The gateway answers with the standard error body and a trace ID; auth and statistics keep working |
| **gateway instance down** | Outage on a single VM | On Kubernetes there are 2 replicas and a disruption budget |

Mechanisms to name: **retries with jitter and a circuit breaker per downstream service** (see below), timeouts on every call (3 s for gRPC, 3 s connect and 10 s response for proxying), health and
readiness probes (`/healthz` restarts, `/readyz` removes from traffic), graceful shutdown (finish running requests on SIGTERM), startup
retries for databases, and structured logs with a request ID.

**Retries and the circuit breaker (built into the gateway, one per downstream service):**
- Reads are retried **once** after a temporary failure (network error, 502/503/504, gRPC Unavailable), after a random "jitter" pause so many gateways do not retry together.
  **Writes are never retried** (register, login, create link), because repeating them could do them twice.
- **Circuit breaker**, like a fuse: after 5 failures in a row the circuit **opens** for 10 seconds. Calls are refused at once with `503` and a `Retry-After` header, the failing service
  is left alone to recover, and users do not wait for timeouts. Then one **trial** call is let through (half-open): success closes the circuit, failure reopens it.
- A normal "no" (404, 400, InvalidArgument) is a healthy answer and never opens the circuit.
- One circuit per service means **isolation**: when auth is cut off, redirects and statistics keep working.
- Metrics: `circuit_breaker_state`, `circuit_breaker_rejected_total`, `upstream_retries_total`, shown on the Grafana dashboard.

**A true story to tell:** I stopped the auth service on the real server on purpose. The first 5 logins returned 502, the 6th and 7th returned `503` with `Retry-After: 11`
in about 50 ms, redirects kept working, and after I restarted auth the first trial call closed the circuit. The metrics showed it.

**What is still not there:** a bulkhead (a hard limit on concurrent calls per service), a fallback answer (for example cached statistics while analytics is down),
a retry budget, and the circuit state is per gateway instance (not shared between copies).

---

## 8. Security

- **One public port.** Everything else is closed (verified from the internet by the smoke test).
- **Authentication and RBAC at the gateway**: JWT HS256, 15-minute lifetime, role in the token, admin routes return 403 to users.
- **Identity-header stripping**: services trust `X-User-Id` only because the gateway deletes client-sent copies first.
- **Passwords**: bcrypt; the same error for unknown email and wrong password; rate limit of 10 per minute on login and register.
- **Input validation**: JSON validation, URL scheme allow-list, parameterised queries.
- **Containers**: non-root, read-only filesystem, no Linux capabilities, resource limits.
- **Supply chain**: vulnerability scan (`govulncheck`) in every pipeline, Dependabot, secret scanning in the platform pipeline.
- **Delivery security**: GitHub reaches AWS with OIDC (no stored keys); the role can only upload to one S3 folder and send a command to one instance.
- **Secrets**: kept in **AWS Secrets Manager** (clicktrail/prod). Each deployment reads them with the instance role (a policy for that one secret only), validates them (required keys, safe characters, minimum JWT length; covered by automated tests) and renders an owner-only .env. Nothing secret is in git or in GitHub, and GitHub's deploy role cannot read the secret. Access is audited by CloudTrail.

## 9. Data and consistency

- Each service owns its data; none reads another's database (they use APIs or events).
- Writes are strongly consistent inside a service. Across services the click statistics are **eventually consistent**.
- Query optimisation: a composite index `(owner_id, created_at DESC)` turned a parallel sequential scan plus sort into an index scan:
  **19.6 ms -> 0.07 ms, about 270 times faster** on 300,000 rows (measured with `EXPLAIN ANALYZE` on the real database).

---

## 10. CI/CD and how it is deployed

**Build and test (per repository).** Format check, `golangci-lint`, unit tests (about 70 to 75 percent coverage), integration tests against **real**
MySQL, PostgreSQL and MongoDB containers, vulnerability scan, Docker build. A tag `vX.Y.Z` builds and publishes
`ghcr.io/sunilvarmatongali/clicktrail-<service>:X.Y.Z` (immutable, semantic versions, never `latest`).

**Deploy to production (platform repository).** A manual GitHub workflow with the version as input:
1. GitHub proves its identity to AWS with **OIDC** and receives short-lived credentials for one role (restricted to this repository's `main` branch).
2. It uploads the stack files to a private S3 bucket and creates a 10-minute download link.
3. It tells the EC2 instance, **by instance ID**, through **AWS Systems Manager**, to download the files, verify the checksum and run `deploy.sh`.
4. `deploy.sh` pulls the images, runs `docker compose up` with health waits, and runs the smoke test on the server.
5. The workflow finally tests the public address from outside, including that all internal ports are closed.
- No SSH, no stored keys or secrets in GitHub, nothing to update when the IP changes (an Elastic IP also keeps the public address stable).

**Where it runs.** One EC2 instance (Ubuntu, 2 vCPU, 4 GB) running 12 containers with Docker Compose: the four services plus MySQL, PostgreSQL, MongoDB, Redis, Kafka,
Prometheus and Grafana. **Only the gateway port is open.**

**Versioning and rollback.** Each service has its own version; `deploy.sh 0.1.0 gateway=0.1.1` runs everything at 0.1.0 except the gateway at 0.1.1.
Only the changed container is replaced. Rollback means deploying the previous versions.

**Kubernetes.** The same system exists as Kustomize manifests (36 resources: probes, requests/limits, hardened pods, a PodDisruptionBudget,
network policies, 2 gateway replicas). They are validated against the Kubernetes schemas in CI. They have **not** been run on a real cluster.

## 11. Observability

Prometheus scrapes `/metrics` from every service (request rate, latency histograms, errors, cache hit ratio, gRPC calls, Kafka consumer lag, events processed
by result). The Grafana dashboard "ClickTrail Overview" shows them. Every request has a trace ID (the gateway creates it, all services log it, errors return it).
This is correlation by ID, **not** full distributed tracing (OpenTelemetry would be the next step).

## 12. Trade-offs and what I would improve (say this proactively)

1. **Remove the .env file entirely.** Secrets come from Secrets Manager already, but services still receive them as environment variables from a rendered file. Next: each service reads its secret at start-up (or, on Kubernetes, the External Secrets Operator), and automatic rotation with managed RDS.
2. **TLS and a domain.** Put an HTTPS load balancer (ACM certificate) or a reverse proxy in front of the gateway; add TLS or mTLS between services.
3. **Managed data stores with backups.** RDS (MySQL/PostgreSQL), DocumentDB or Atlas, ElastiCache, MSK, multi-AZ.
4. **More resilience patterns.** Circuit breakers and jittered retries exist; add bulkheads, fallbacks and a shared retry budget.
5. **Outbox for click events too** (they are best effort today), a cleanup job for sent outbox rows, change-data-capture (Debezium) instead of polling, and a dead-letter topic.
6. **Asymmetric JWT (RS256)** so only the auth service holds the signing key; refresh tokens and revocation.
7. **Run Kubernetes for real** (EKS or a managed cluster) with an ingress, autoscaling and GitOps.
8. **A staging environment** and automated promotion; currently there is one environment.
9. **Distributed tracing** with OpenTelemetry; alert rules in Prometheus.
10. **Shared library** for the small pieces duplicated across services (middleware, config helpers).

---

## 13. Likely questions and good answers

**Why microservices for such a small product?** To demonstrate the practices (independent deployability, data ownership, async messaging). For a real product this size a modular monolith would be the right call; I would say that.

**Why polyrepo?** Independent pipelines, versions and ownership, like separate teams. The cost is cross-service changes and some duplicated code, which I documented in an ADR.

**Why Kafka and not a REST call to analytics?** So redirects never depend on analytics, and so clicks are buffered and replayable during an outage.

**How do you avoid counting a click twice?** At-least-once delivery plus an idempotent consumer: the event ID is the MongoDB `_id`, a duplicate insert is ignored.

**What if Kafka is down when someone clicks?** The redirect still works; that click event is lost (best effort), because a click is cheap to lose. For data that must not be lost (a new link and its owner) I used a transactional outbox.

**What is the dual-write problem and how did you solve it?** Saving to the database and publishing to Kafka are two systems with no shared transaction. If the second step fails, the other service never learns what happened. I save the event in an outbox table in the *same* database transaction as the link, and a relay publishes it afterwards and retries until Kafka confirms. Delivery becomes at-least-once, so the consumer is idempotent (the short code is the document ID). I proved it on the server by stopping Kafka, creating a link (it worked), starting Kafka, and watching the event arrive.

**Why polling and not Debezium (CDC)?** Polling a small partial index every 500 ms needs no extra infrastructure and is simple to explain and test. CDC has less delay and no polling, but needs Kafka Connect and database log settings. The relay is small, so it can be swapped later.

**What is a read model and what does it cost?** A copy of another service's data, shaped for my questions. Analytics keeps "short code -> owner", so statistics do not depend on url-service. The cost is eventual consistency (a brand-new link may give `404` for a moment) and a second copy of the data that must be kept in step by events.

**How do two copies of url-service not send the same event twice?** The relay locks rows with `SELECT ... FOR UPDATE SKIP LOCKED`, so a second copy skips rows the first one holds. A crash after Kafka confirmed but before the commit can still cause a duplicate, which the idempotent consumer ignores.

**What is a circuit breaker and why did you use one?** It stops calling a service that keeps failing, so users get an immediate `503` instead of waiting for a timeout, and the service can recover. It has three states: closed (normal), open (calls refused for 10 s) and half-open (one trial call). I used `sony/gobreaker` behind a small wrapper in the gateway, one per downstream service, and I proved it by stopping a service on the real server.

**Why do you not retry every call?** Retrying a write (create link, login) could do it twice. Only reads are retried, once, with a random pause (jitter) so that many gateways do not retry at the same time.

**What if analytics is down?** Statistics return 502. Clicks keep accumulating in Kafka and are counted when it returns.

**How do services trust each other?** Services are reachable only inside the private network. The gateway verifies the JWT and sets identity headers after deleting client-sent ones. Hardening: mTLS and network policies.

**How is authentication different from authorisation here?** Authentication is the JWT check (who are you). Authorisation is RBAC on the role (admin routes) plus ownership checks (your links only).

**How do you handle a leaked JWT?** Tokens live 15 minutes. There is no revocation list yet; I would add refresh tokens, short lifetimes and a deny list.

**How do you manage secrets?** In AWS Secrets Manager, one JSON secret. The EC2 instance role may read only that secret. The deploy script fetches it, validates every value, and renders an owner-only .env; GitHub never sees any secret and its deploy role has no access to it. Changing a secret means editing it in Secrets Manager and redeploying. Limitations I would mention: password rotation is manual because the databases are containers (with managed RDS it is automatic), and the services still read environment variables.

**How do you roll back?** Deploy the previous version numbers; images are immutable.

**Zero-downtime deployment?** Not on the single VM: recreating the gateway container causes a short interruption. On Kubernetes, rolling updates with 2 replicas and a disruption budget give zero downtime. I would say it plainly.

**How does the pipeline deploy without SSH keys?** OIDC gives GitHub short-lived AWS credentials; Systems Manager runs the command on the instance by ID; the files travel through S3.

**How would you scale it?** Stateless services scale horizontally (gateway, url, auth). Analytics scales with the Kafka partitions (3) by adding consumers in the same group. Databases need replicas or managed services.

**How do you know it works?** Unit and integration tests against real databases, and an end-to-end smoke test run by the pipeline after every deployment.

**What was the hardest bug?** Good true stories: Gin's `CloseNotify` panicking behind the reverse proxy; the gateway exposing `/metrics` publicly (found in review and fixed); AWS's ID-based OIDC subject claim breaking the first role trust policy; SSM running scripts with `sh` instead of bash.

---

## 14. Numbers to remember

- 6 repositories: 4 services + shared proto + platform. 12 containers in production.
- 5 user stories; smoke test: **27 checks on the server, 36 from the internet**, 0 failures.
- Index result: **19.6 ms -> 0.07 ms** (about 270x) on 300,000 rows.
- JWT lifetime 15 min; rate limits 120/min general and 10/min for login and register.
- Kafka topics `clicktrail.link-clicked.v1` and `clicktrail.link-created.v1`, 3 partitions each; consumer retry backoff 0.5 s to 30 s; outbox relay polls every 500 ms (pauses double up to 30 s while Kafka is down).
- 7 decision records (ADRs) in the platform repo, 4 to 6 in each service.

## 15. Do NOT claim

- That it ran on Kubernetes in production (it ran on EC2 with Docker Compose; the manifests are validated, not run on a cluster).
- Multi-region, high availability, backups or managed databases (single node, demo setup).
- Zero-downtime deploys, distributed tracing, bulkheads or fallbacks (not built). Circuit breakers and retries with jitter **are** built into the gateway. The outbox covers new-link events only, not clicks.
- "Exactly-once" anything (it is at-least-once with idempotency).
- Real users or traffic (it is a portfolio project; the numbers come from tests and a 300,000-row benchmark).
