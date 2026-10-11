# ADR 0007: Transactional outbox and a link-owner read model

- Status: Accepted
- Date: 2026-10-12

## Context

Two problems showed up in the first version:

1. **The dual-write problem.** If url-service saved a link and then failed to publish an event (Kafka down, crash in between), other services would never learn about it.
   The click events accept this (a lost click is cheap), but ownership data must not be lost.
2. **Chained synchronous calls.** To show statistics the gateway asked url-service "who owns this link?" and then analytics for the number. Statistics stopped when url-service stopped.

## Decision

- url-service uses a **transactional outbox**: the link and a `LinkCreated` row (table `outbox_events`) are saved in one database transaction; a background relay publishes the rows
  to the topic `clicktrail.link-created.v1`, and marks them as sent only after Kafka confirmed them. Details: URL service ADR 0005.
- analytics-service consumes the topic idempotently and keeps a **read model** "short code -> owner" in MongoDB (collection `links`), with a new gRPC call
  `GetOwnedLinkClickCount` (contract `clicktrail-proto` v0.2.0, backwards compatible). Details: analytics ADR 0005.
- The gateway uses this call and no longer calls url-service for statistics. Details: gateway ADR 0006.
- A migration in url-service (000004) creates an event for every link that existed before the outbox, so old links work too.
- Clicks stay on the simple fire-and-forget path (URL service ADR 0003).

Alternatives considered: publishing inside the same function without an outbox (loses events), a two-phase commit between PostgreSQL and Kafka (not supported in practice),
change-data-capture with Debezium (more infrastructure; the relay can be replaced by it later), and keeping the synchronous ownership call (statistics depend on url-service).

## Consequences

- Positive: no lost link events; link creation works while Kafka is down; statistics work while url-service is down.
- Negative: eventual consistency (a new link's statistics may answer `404` for a moment), duplicates are possible (consumers are idempotent), one more table to monitor
  (`outbox_pending_events`) and clean up (not automated yet), and a second copy of the owner data.
- Deployment: release proto first, then analytics, url-service and gateway together. The Compose file creates the second topic (`kafka-init`).

## How we proved it

On the AWS server: stop Kafka, create a link (still `201`), see `outbox_pending_events` rise to 1, start Kafka, see it fall to 0 and the statistics of the new link answer `200`.