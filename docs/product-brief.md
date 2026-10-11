# ClickTrail product brief

## Problem

People share long, ugly web addresses. ClickTrail turns one into a short link and tells its owner how many times
it was opened.

## Users

| User | Needs |
|---|---|
| Visitor | Opens a short link and lands on the right page, fast |
| Registered user | Creates short links and sees how often each one was clicked |
| Admin | Sees the total number of clicks on the whole platform |
| Operator | Knows whether the platform is healthy, fast and keeping up |

## User stories and acceptance criteria

Each story is checked automatically by [`scripts/smoke-test.sh`](../scripts/smoke-test.sh) against a running stack.

### 1. Register and log in
As a user I can register and log in and receive a short-lived token.
- Registering a new email returns `201`; registering it again returns `409`.
- Logging in with a wrong password returns `401`; with the right password returns `200` and an access token.
- The token expires (15 minutes by default).

### 2. Create a short link and open it
As a user I can create a short link for a long URL, and anyone who opens it is redirected.
- Creating a link needs a valid token (`401` without one).
- Only `http` and `https` addresses are accepted (`400` for `javascript:` and similar).
- Opening `/r/{code}` answers `302` with the original address; an unknown code answers `404`.

### 3. See click statistics
As a user I can see how many times my link was clicked.
- After three visits the statistics of my link show three clicks (clicks travel through Kafka, so they arrive within seconds).
- Another user asking for my link's statistics gets `404`, as does anyone for an unknown link.
- Asking without a token gets `401`.

### 4. Admin totals
As an admin I can see the platform-wide click total; a normal user gets `403 Forbidden`.
- A normal user gets `403`, an anonymous caller gets `401`, the admin gets `200` with the total.

### 5. Operate the platform
As an operator I can see health, latency and consumer lag on a dashboard.
- Prometheus reports every service as up.
- The Grafana dashboard "ClickTrail Overview" shows traffic, latency (95th percentile), server errors, rate-limited
  requests, Kafka consumer lag, click events by result, cache hit ratio and gRPC traffic.

## Non-functional requirements

| Area | Requirement |
|---|---|
| Security | Only the gateway is public; identity cannot be forged by clients; passwords are hashed; rate limits protect login |
| Reliability | A failing cache or message queue must not break redirects; no click is lost when the database has a short outage |
| Operability | Every service has health probes, structured logs with a request ID, and metrics |
| Maintainability | Small services, clear layers, tests, decision records (ADRs), one pipeline per repository |

## Out of scope for this version

Link editing or deletion, custom short codes, link expiry, password reset, email verification, refresh tokens,
multi-region deployment, managed databases. See the "Known limitations" section of [architecture.md](architecture.md).
