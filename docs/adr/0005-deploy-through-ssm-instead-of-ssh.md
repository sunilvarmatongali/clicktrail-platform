# ADR 0005: Deploy through AWS Systems Manager instead of SSH

- Status: Accepted
- Date: 2026-10-11

## Context

The deployment pipeline must reach the VM. Our first design used SSH from a GitHub runner. That needs a long-lived private key
stored in GitHub, the VM's host key and address kept as settings, and a firewall rule opened for the runner (GitHub runners have
no fixed address) and closed again. Every one of those is something that can leak, expire or go stale, and the address changes
when the instance restarts.

## Decision

Authenticate to AWS with OIDC (short-lived credentials, no stored keys) and use SSM Run Command to start the deployment
on the instance, addressed by its instance ID. The stack files travel through a private S3 bucket and reach the VM through a
10-minute download link whose checksum is verified. The role can only write one S3 folder, send a command to one instance,
read the result and look up the instance's address. The deployment script runs as the normal user, never as root.

## Consequences

- Positive: no secrets or SSH keys in GitHub; no inbound port required for deployments; no firewall changes; the pipeline survives
  IP changes; every deployment is recorded by AWS (CloudTrail and SSM command history).
- Positive: a leaked workflow cannot do more than the role allows, and it only works from this repository's `main` branch.
- Negative: more one-time AWS setup (bucket, instance role, deploy role) and an AWS-specific design.
- Negative: SSM and the download link carry the command text, so no secret may be placed in it (none is).
- Alternative considered: SSH with a dedicated key and a temporary firewall rule. Simpler to set up, but it keeps a long-lived key in GitHub.
