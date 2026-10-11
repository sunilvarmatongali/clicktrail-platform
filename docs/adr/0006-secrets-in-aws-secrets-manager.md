# ADR 0006: Keep secrets in AWS Secrets Manager

- Status: Accepted
- Date: 2026-10-11

## Context

The first version generated random passwords into a `.env` file on the VM when it was bootstrapped. That file had restrictive
permissions and was never committed, but the passwords existed only on that one machine: no central record, no access control
or audit trail, and a rebuilt VM meant new passwords (and unusable database volumes). The image-registry token was typed into
a `docker login` by hand and silently expired.

## Decision

Store all secrets in one AWS Secrets Manager secret (`clicktrail/prod`, a JSON object). The instance role may read exactly that secret.
`deploy.sh` reads it at every deployment, **validates every key and value** (`render-env.sh`: required keys present, only a safe set of
characters, a minimum JWT secret length) and renders the `.env` for Docker Compose into an owner-only temporary file before moving it into place.
Non-secret settings (versions, public address) live in `config.env`. If the secret holds registry credentials, `deploy.sh` also logs in to the registry.
The GitHub deploy role has no access to the secret, so GitHub never sees a secret value.

## Consequences

- Positive: one source of truth; access is controlled per secret and audited by CloudTrail; a rebuilt VM gets the same secrets;
  the registry token is rotated in one place.
- Positive: the validation logic is covered by automated tests in the platform pipeline.
- Negative: a small recurring cost per secret, and one more AWS dependency at deploy time (a deployment fails if the secret cannot be read, which is the safe failure).
- Negative: the rendered `.env` is still a file on the VM (owner-only). Services still read environment variables. Reading directly from
  Secrets Manager inside each service, or using a Kubernetes secrets operator, would remove the file.
- Limitation: our databases are containers, so password rotation is manual. With managed RDS, rotation can be automatic.
- Alternative considered: SSM Parameter Store (free for standard parameters). Simpler and cheaper, but without built-in rotation.
