# ADR 0003: Single-node data stores in the demo

- Status: Accepted for the demo, not for production
- Date: 2026-10-11

## Context

The platform needs MySQL, PostgreSQL, MongoDB, Redis and Kafka. Running each in a highly available way is a project of its own.

## Decision

Run one container of each. In Docker Compose they use named volumes (data survives restarts). On Kubernetes they use
temporary `emptyDir` storage (data is lost when the pod is replaced). Memory is capped so the whole stack fits in 4 GB.
Redis has no persistence because it holds only a cache and rate-limit counters.

## Consequences

- Positive: simple, cheap, quick to start.
- Negative: no replication, no backups, no failover. Do not store real user data here.
- Production path: managed services (Amazon RDS for MySQL/PostgreSQL, MongoDB Atlas or DocumentDB, ElastiCache, Amazon MSK) with backups and multiple availability zones.
