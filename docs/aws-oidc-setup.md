# One-time setup: let GitHub deploy to AWS without stored AWS keys

The **deploy** workflow needs to reach the VM over SSH. Your security group allows SSH only from your own address,
which is correct, so the workflow opens it for its own address for the length of the job and closes it again.
To do that it needs permission to edit **one** security group. We give it that with **OIDC** (OpenID Connect):

```
GitHub job  --(short-lived identity token)-->  AWS  --(temporary credentials for ONE role)-->  GitHub job
```

No access key or secret is created or stored anywhere. AWS only trusts tokens that come from this repository's `main` branch.

Replace the placeholders: `<ACCOUNT_ID>` (12-digit AWS account number), `<REGION>` (for example `ap-south-1`),
`<SECURITY_GROUP_ID>` (looks like `sg-0123456789abcdef0`, EC2 -> Security Groups), `<GITHUB_USER>` (your GitHub user name).

## 1. Create the identity provider (once per AWS account)

AWS Console -> **IAM** -> **Identity providers** -> **Add provider**
- Provider type: **OpenID Connect**
- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`
- Click **Add provider**.

## 2. Create the role

IAM -> **Roles** -> **Create role**
- Trusted entity type: **Custom trust policy**. Paste:

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
          "token.actions.githubusercontent.com:sub": "repo:<GITHUB_USER>/clicktrail-platform:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

  The `sub` line is the important lock: only a workflow of **this repository, on the `main` branch** can use the role.
- Skip the managed permission policies. Name the role `clicktrail-github-deploy` and create it.
- Open the role -> **Add permissions** -> **Create inline policy** -> JSON. Paste (one security group only):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress"
      ],
      "Resource": "arn:aws:ec2:<REGION>:<ACCOUNT_ID>:security-group/<SECURITY_GROUP_ID>"
    },
    {
      "Effect": "Allow",
      "Action": "ec2:DescribeSecurityGroups",
      "Resource": "*"
    }
  ]
}
```

  Name it `clicktrail-edit-ssh-rule`.
- Copy the role's **ARN** (`arn:aws:iam::<ACCOUNT_ID>:role/clicktrail-github-deploy`).

> If the console says your IAM user is not allowed to create providers or roles, you need IAM permissions for this one-time
> step: either sign in as the account owner (root) just for it, or temporarily attach `IAMFullAccess` to your user and
> remove it afterwards.

## 3. GitHub repository settings (`clicktrail-platform`)

**Variables** (Settings -> Secrets and variables -> Actions -> Variables). None of these is secret:

| Variable | Value |
|---|---|
| `AWS_REGION` | `<REGION>` |
| `AWS_DEPLOY_ROLE_ARN` | the role ARN from step 2 |
| `EC2_SECURITY_GROUP_ID` | `<SECURITY_GROUP_ID>` |
| `EC2_HOST` | the VM's public address |
| `EC2_USER` | `ubuntu` |
| `EC2_KNOWN_HOSTS` | the VM's SSH host key (pins the server identity): `ssh-keyscan -t ed25519 <vm-address>` |

**Secrets** (same page, Secrets tab):

| Secret | Value |
|---|---|
| `EC2_SSH_KEY` | the private half of a **dedicated deploy key** (not your personal `.pem`): see below |
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | the admin login from `/opt/clicktrail/compose/.env` on the VM (used by the outside smoke test) |

### The dedicated deploy key

Give the workflow its own key, so your personal key never leaves your computer and the workflow's key can be removed alone:

```bash
ssh-keygen -t ed25519 -N "" -C "clicktrail-github-deploy" -f clicktrail-deploy-key
# put the PUBLIC half on the VM:
ssh-copy-id -i clicktrail-deploy-key.pub ubuntu@<vm-address>     # or append it to ~/.ssh/authorized_keys
# store the PRIVATE half (the file without .pub) as the secret EC2_SSH_KEY, then delete the local copy
```

## 4. The registry login on the VM

The images are private, and the VM pulls them with a token you stored once with `docker login ghcr.io` (see the runbook).
The workflow does not handle that token. When it expires, log in again on the VM.

## 5. Run it

Actions -> **deploy** -> **Run workflow** -> version `0.1.0`, overrides `gateway=0.1.1` (or empty).
Afterwards check the security group: **no `github-actions-run-...` rule should remain** (the last step removes it).

## What can go wrong

| Symptom | Cause |
|---|---|
| "Could not assume role" / "Not authorized to perform sts:AssumeRoleWithWebIdentity" | Trust policy `sub` does not match (wrong user name, repository or branch), or the workflow was not started from `main` |
| `AuthorizeSecurityGroupIngress` denied | The inline policy names a different security group or region |
| "Host key verification failed" | `EC2_KNOWN_HOSTS` is wrong, or the VM was recreated (its host key changed) |
| "Permission denied (publickey)" | The public deploy key is not in `~/.ssh/authorized_keys` on the VM |
| "unauthorized" while pulling images | The registry token on the VM expired: run `docker login ghcr.io` on the VM again |
| Smoke test fails at the rate limit | Another run happened within the same minute: wait one minute and run again |
