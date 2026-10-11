# One-time setup: deploy from GitHub to AWS with no SSH, no keys and no secrets

The **deploy** workflow never connects to the server over SSH. Instead:

```
GitHub job --(short-lived identity token, OIDC)--> AWS --(temporary credentials for ONE role)--> GitHub job
GitHub job --> uploads the stack files to a private S3 bucket
GitHub job --> tells the instance, by its ID, to deploy (AWS Systems Manager "Run Command")
Instance   --> downloads the files through a 10-minute link, checks the checksum, runs deploy.sh
```

Consequences worth knowing:
- No AWS access key, SSH key or password is stored in GitHub. **There are no repository secrets at all.**
- Port 22 is not needed by the pipeline. You may keep it for your own admin access, or close it.
- The server's IP address does not matter to the pipeline: it uses the **instance ID** and looks up the current address itself.

Replace the placeholders: `<ACCOUNT_ID>` (12-digit AWS account number), `<REGION>` (for example `ap-south-1`),
`<INSTANCE_ID>` (EC2 -> Instances, looks like `i-0123456789abcdef0`), `<BUCKET>` (a globally unique name, for example
`clicktrail-deploy-<ACCOUNT_ID>-<REGION>`), `<GITHUB_USER>` (your GitHub user name), `<USER_ID>` and `<REPO_ID>` (the numeric IDs of your GitHub account and of the repository, see step 4).

## 1. A static public address (Elastic IP)

EC2 -> **Elastic IPs** -> **Allocate Elastic IP address** -> Allocate. Then select it -> **Actions** -> **Associate Elastic IP
address** -> choose your instance. The address no longer changes when you stop and start the instance, so short links keep working.
Afterwards set `PUBLIC_BASE_URL` in `/opt/clicktrail/compose/.env` on the VM to `http://<elastic-ip>:8080` and restart
the URL service (`docker compose up -d url-service`).

Cost note: AWS charges a small hourly fee for public IPv4 addresses in general. An Elastic IP costs that fee also while the
instance is **stopped** (an automatic address is released for free then). **Release** the Elastic IP when you no longer need it.

## 2. The S3 bucket for deploy bundles

S3 -> **Create bucket**: name `<BUCKET>` (AWS may append a suffix such as `-an` for account-scoped buckets: use the **final name shown in the bucket list**, everywhere), region `<REGION>`, keep **Block all public access ON** and default encryption ON.
After creating it: **Management** -> **Create lifecycle rule** -> name `expire-old-bundles`, limit to prefix `deploy/`,
action **Expire current versions of objects** after **7** days.

## 3. Let the instance receive commands (SSM)

1. IAM -> Roles -> **Create role** -> trusted entity **AWS service**, use case **EC2**.
2. Attach the AWS managed policy **`AmazonSSMManagedInstanceCore`** (nothing else). Name the role `clicktrail-ec2-ssm`.
3. EC2 -> Instances -> select your instance -> **Actions -> Security -> Modify IAM role** -> choose `clicktrail-ec2-ssm`.
4. Same menu: **Actions -> Instance settings -> Modify instance metadata options** -> set **Metadata response hop limit = 1**.
   (An instance role is now reachable through the metadata service. With hop limit 1 containers cannot read it.)
5. After about two minutes the instance appears under **Systems Manager -> Fleet Manager** as "Online". If it does not,
   run `sudo snap restart amazon-ssm-agent` on the VM.

## 4. The identity provider and the deploy role (GitHub -> AWS)

IAM -> **Identity providers** -> **Add provider** -> OpenID Connect:
- Provider URL: `https://token.actions.githubusercontent.com`, Audience: `sts.amazonaws.com`.

IAM -> **Roles** -> **Create role** -> **Custom trust policy**. Paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_USER>@<USER_ID>/clicktrail-platform@<REPO_ID>:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

The `sub` line is the lock: only a workflow of **this repository, on the `main` branch** can use the role.
**Which `sub` format does your account use?** GitHub signs tokens with either the classic name-only form
(`repo:<user>/<repo>:ref:refs/heads/main`) or the newer one that also contains the numeric IDs
(`repo:<user>@<USER_ID>/<repo>@<REPO_ID>:ref:refs/heads/main`). The ID form is safer because the IDs never change, and
a new repository that reuses an old name gets different IDs. Find your IDs with:

```bash
gh api users/<GITHUB_USER> --jq .id                        # USER_ID
gh api repos/<GITHUB_USER>/clicktrail-platform --jq .id    # REPO_ID
```

To see exactly what GitHub sends (the claims are public metadata, not secrets), run a workflow with `id-token: write` that decodes
the middle part of the token requested from `ACTIONS_ID_TOKEN_REQUEST_URL`, and copy its `sub` value.
Skip the managed policies, name the role `clicktrail-github-deploy`, create it, then open it -> **Add permissions** ->
**Create inline policy** -> JSON, named `clicktrail-deploy`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UploadAndDownloadBundles",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::<BUCKET>/deploy/*"
    },
    {
      "Sid": "RunCommandOnTheOneInstance",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ssm:<REGION>::document/AWS-RunShellScript",
        "arn:aws:ec2:<REGION>:<ACCOUNT_ID>:instance/<INSTANCE_ID>"
      ]
    },
    {
      "Sid": "ReadTheResult",
      "Effect": "Allow",
      "Action": ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"],
      "Resource": "*"
    },
    {
      "Sid": "FindThePublicAddress",
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    }
  ]
}
```

> If the console says your IAM user may not create roles or providers, use the account owner (root) for these IAM steps only,
> or temporarily attach `IAMFullAccess` to your user and remove it afterwards.

## 5. GitHub repository variables (none of them is secret)

Settings -> Secrets and variables -> Actions -> **Variables**:

| Variable | Value |
|---|---|
| `AWS_REGION` | `<REGION>` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/clicktrail-github-deploy` |
| `EC2_INSTANCE_ID` | `<INSTANCE_ID>` |
| `DEPLOY_BUCKET` | `<BUCKET>` |

## 6. Secrets (AWS Secrets Manager)

All passwords and keys live in **one secret**, `clicktrail/prod`. Nothing secret is in git, in GitHub, or generated by hand on
the server. At every deployment `deploy.sh` reads the secret with the **instance role** and builds the `.env` for Docker Compose.

**What you gain:** one central place, an access rule per secret, an audit trail (CloudTrail shows who read it and when),
and a single place to change or rotate a value.

### 6.1 The content of the secret

A JSON object with these keys. The values may use only letters, digits and `@ . _ : + = / -`
(the deployment script rejects anything else, because the values end up in a file that Docker Compose interprets).

| Key | Meaning |
|---|---|
| `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`, `POSTGRES_PASSWORD` | database passwords |
| `JWT_SECRET` | at least 32 characters; shared by the auth service and the gateway |
| `GRAFANA_ADMIN_PASSWORD` | Grafana login |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | the first admin account |
| `GHCR_PULL_USER`, `GHCR_PULL_TOKEN` | optional: GitHub user and a token with only `read:packages`, so each deployment logs in to the image registry itself |

### 6.2 Create it

**Migrating the running server (reuse the current values).** The databases already exist with their current passwords, so the
secret must contain the same values. On the VM, run the helper and copy its output straight into the console:

```bash
bash /opt/clicktrail/scripts/aws/export-secrets-json.sh
```

**A brand-new server.** Generate fresh random values (for example `openssl rand -hex 16` for each password and `openssl rand -hex 32` for `JWT_SECRET`).

Console: **Secrets Manager** -> **Store a new secret** -> type **Other type of secret** -> **Plaintext** tab -> paste the JSON -> encryption key
**aws/secretsmanager** (default) -> name **`clicktrail/prod`** -> **Disable rotation for now** -> Store.
Add `GHCR_PULL_USER` and `GHCR_PULL_TOKEN` through **Retrieve secret value -> Edit**.

### 6.3 Allow the instance to read it (and nothing else)

IAM -> Roles -> `clicktrail-ec2-ssm` -> **Add permissions -> Create inline policy** -> JSON, named `clicktrail-read-secret`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:<REGION>:<ACCOUNT_ID>:secret:clicktrail/prod-*"
    }
  ]
}
```

The `-*` at the end is needed because AWS appends six random characters to the secret's ARN. The GitHub deploy role needs **no** access to the
secret: GitHub never sees any secret value.

### 6.4 Changing or rotating a value

1. Change it in Secrets Manager (Retrieve secret value -> Edit).
2. Run the **deploy** workflow again (same version). The new `.env` is rendered and the services restart with the new values.
3. Special cases: a **database password** must also be changed inside the database first (the password in the volume is the one from the first start);
   changing `JWT_SECRET` logs everybody out.

Automatic rotation (a Lambda function that changes a password and the secret together) exists for RDS databases. Our databases
are containers, so rotation here is a manual, documented procedure. With managed RDS it would be automatic.

### 6.5 What the images need at runtime

The services still receive their secrets as environment variables, as Twelve-Factor recommends. The difference is where the values come from.
A further step would be for each service to read the secret from Secrets Manager itself at start-up (no `.env` file at all). On Kubernetes
the equivalent is the External Secrets Operator or the Secrets Store CSI driver.

## 7. Run it

Actions -> **deploy** -> **Run workflow** -> version `0.1.0`, overrides `gateway=0.1.1` (or empty).
The log shows the output of the deployment on the VM and the outside smoke test.

## What can go wrong

| Symptom | Cause |
|---|---|
| "Could not assume role" / "Not authorized to perform sts:AssumeRoleWithWebIdentity" | Trust policy `sub` does not match. The most common reason is the **format** (name-only versus the ID form, see step 4), then a wrong user name or repository, or a workflow not started from `main` |
| `AccessDenied` on S3 or `ssm:SendCommand` | The inline policy names a different bucket, instance, region or account |
| `InvalidInstanceId` / the command never starts | The instance is not "Online" in Fleet Manager: check the instance role (step 3) and the SSM agent |
| `NoSuchBucket` in the upload step | The `DEPLOY_BUCKET` variable differs from the real bucket name (check for a suffix such as `-an`) |
| Command status `Failed`, output says "unauthorized" | The registry token on the VM expired: `docker login ghcr.io` on the VM |
| The outside smoke test cannot connect | The instance is stopped, or the security group no longer allows port 8080 |
| Smoke test fails at the rate limit | Another run happened within the same minute: wait one minute and run again |
