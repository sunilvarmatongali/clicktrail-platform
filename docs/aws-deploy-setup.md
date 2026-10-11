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

S3 -> **Create bucket**: name `<BUCKET>`, region `<REGION>`, keep **Block all public access ON** and default encryption ON.
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

## 6. The registry login on the VM

The images are private. The VM pulls them with a token you stored once with `docker login ghcr.io` (see the runbook). The
workflow never touches that token. When it expires, log in again on the VM.

## 7. Run it

Actions -> **deploy** -> **Run workflow** -> version `0.1.0`, overrides `gateway=0.1.1` (or empty).
The log shows the output of the deployment on the VM and the outside smoke test.

## What can go wrong

| Symptom | Cause |
|---|---|
| "Could not assume role" / "Not authorized to perform sts:AssumeRoleWithWebIdentity" | Trust policy `sub` does not match. The most common reason is the **format** (name-only versus the ID form, see step 4), then a wrong user name or repository, or a workflow not started from `main` |
| `AccessDenied` on S3 or `ssm:SendCommand` | The inline policy names a different bucket, instance, region or account |
| `InvalidInstanceId` / the command never starts | The instance is not "Online" in Fleet Manager: check the instance role (step 3) and the SSM agent |
| Command status `Failed`, output says "unauthorized" | The registry token on the VM expired: `docker login ghcr.io` on the VM |
| The outside smoke test cannot connect | The instance is stopped, or the security group no longer allows port 8080 |
| Smoke test fails at the rate limit | Another run happened within the same minute: wait one minute and run again |
