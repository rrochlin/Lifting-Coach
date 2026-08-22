# Terraform spec — phase 2.1

What `server/infra/` has to create for the phone to back its database up and
restore it. Written to be implemented by someone who has not read the app, and
to be **validated before** it is, which is why every non-obvious resource
carries the reason it's shaped that way.

Scope is phase 2.1 only: identity, one object per user, and a record of what
that object turned out to contain. The chat (2.2) and the query tools (2.3) get
their own resources later; §9 sketches them so the module layout doesn't have
to be reorganized to accept them.

Read alongside:
- `notes/Workout App/Backend/Overview.md` — why the design is snapshot-and-draft.
- `terraform-infrastructure/ONBOARDING.md` — the subtree link, the placeholder
  Lambda pattern, the CI matrix. All three rules are load-bearing here.

> **Decisions are settled.** §10 records the six that were open, what was chosen
> and why, including two where the reasoning behind the question turned out to
> rest on a wrong fact. An earlier draft of this spec put a presigning API in
> front of S3 — API Gateway, five routes, six Lambdas, a device lease. §8
> accounts for what that bought and what dropping it cost.

---

## 1. The shape

```
  phone ── Cognito user pool ──────────► id token
        │    (email/password, or Sign in with Apple)
        │
        └─ Cognito identity pool ──────► temporary AWS credentials,
                                          tagged with the user pool `sub`
        │
        │  PUT/GET, signed by the phone itself, conditional on the last etag
        ▼
  s3://lift-coach-prod-snapshots/users/{sub}/snapshot.sqlite.gz
        │
        │  ObjectCreated
        ▼
  index-snapshot Lambda ── opens the file, reads what's in it ──► snapshotMeta
```

**The phone talks to S3 directly.** An IAM role, assumed through the identity
pool, is scoped by a principal tag carrying the user's `sub` so the credentials
can only reach that one prefix. There is no API in front of it and nothing to
mint a URL.

**The index is derived from the object, never from the uploader's word.** The
Lambda downloads the snapshot, opens it, and records the schema version and row
counts it actually finds. That's the same discipline `ExerciseStatsStore`
already follows on the device — `rebuild(for:)` is the only writer, so the table
can be stale but cannot disagree with the log — applied to the bucket instead of
the log.

---

## 2. Placement and conventions

| | |
| --- | --- |
| Directory in `terraform-infrastructure` | `lift-coach/` |
| Backend state key | `lift-coach/terraform.tfstate` (same bucket `roberts-personal-tf-bucket`, same lock table `terraform-state-locking`) |
| Region | `us-west-2`, matching `amazing-adventure`. Bedrock serves Claude models there, which matters for 2.2. |
| Provider | `hashicorp/aws ~> 5.0`, `required_version >= 1.5.0` |
| Prefix | `local.prefix = "${var.app_name}-${var.environment}"` → `lift-coach-prod` |
| Tags | `local.common_tags = { App, Environment, ManagedBy = "terraform" }` |
| Subtree prefix in this repo | `server/infra` |

Note the GitHub repo is `Lifting-Coach` while the app name here is
`lift-coach` — so §7's OIDC subject pattern says `repo:rrochlin/Lifting-Coach`
and everything else says `lift-coach`. That's the one place the two spellings
meet, and it's deliberate rather than a typo to tidy.

Mirror `amazing-adventure/`'s layout: root `main.tf` / `variables.tf` /
`outputs.tf`, plus `modules/{s3,dynamodb,cognito,lambdas}/`. Not because
uniformity is a virtue in itself, but because the next person to read either
directory shouldn't have to learn a second set of habits, and because
`ONBOARDING.md` names those modules as the reference patterns. **No
`api-gateway` module** — see §8.

**The CI matrix entry ships in the same PR.** Add `lift-coach` to `matrix.app`
in `.github/workflows/terraform.yml`. Nothing plans or applies without it, and a
directory that validates locally is not "live."

**No `config/` directory.** `terraform-infrastructure/README.md` and its
`CLAUDE.md` both still describe a `config/main.tf` that no longer exists — they
predate the per-app split `ONBOARDING.md` documents. Follow `ONBOARDING.md`;
those two files are stale and worth a one-line fix in the same PR.

---

## 3. Cognito — identity, and the authority that comes with it

This is the section where a mistake is a breach rather than a bug. Everything
else here can be wrong and cost an afternoon.

### 3.1 User pool

**`aws_cognito_user_pool`** — `${local.prefix}`.
- `username_attributes = ["email"]`, `auto_verified_attributes = ["email"]`,
  `username_configuration { case_sensitive = false }`.
- `password_policy` — 8 minimum, upper + lower + numbers, no symbol
  requirement. Matching `amazing-adventure`; a symbol rule mostly buys a
  password-manager entry with a `!` on the end.
- `account_recovery_setting` — verified email, priority 1.
- `schema` — `email`, required, mutable, 5–254.
- **`deletion_protection = "ACTIVE"` — the strongest recommendation in this
  document.** The `sub` is the key the S3 prefix, every DynamoDB item, and the
  phone's own `v14_cognitoSub` binding are filed under. Destroying the pool
  doesn't lose a login; it orphans the data permanently and silently, because a
  re-created pool issues a different `sub` for the same email address.
- No Lambda triggers. `amazing-adventure` has a post-confirmation hook to seed a
  user row; there's nothing to seed here — the phone is the system of record and
  the first upload creates everything server-side.

**`aws_cognito_user_pool_client`** — `${local.prefix}-ios`.
- `generate_secret = false`. A native app can't keep a secret, and Amplify's
  iOS SRP flow assumes a public client.
- `explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]`.
  **No `ALLOW_USER_PASSWORD_AUTH`** — that flow puts the password in the request
  rather than proving knowledge of it, and nothing here needs it.
- `prevent_user_existence_errors = "ENABLED"`.
- `enable_token_revocation = true`, so signing out on a lost phone can be made
  to mean something.
- Token validity: access 1 hour, id 1 hour, **refresh 30 days** — Cognito's own
  default. See **D3**, and note what it does and doesn't mean: refresh tokens
  don't slide, so this is 30 days from *sign-in*, not 30 days idle.
- OAuth settings for Sign in with Apple — §3.2.

**`aws_ssm_parameter`** for the user pool id, the client id, the identity pool
id and the hosted-UI domain under `/${local.prefix}/cognito/…`, mirroring
`amazing-adventure`. The iOS build reads them at configure time rather than
having them pasted into a checked-in `amplifyconfiguration.json`.

**No user pool groups.** `amazing-adventure` has admin/user/restricted because
it gates AI access by role. There is one lifter.

### 3.2 Sign in with Apple

**Prerequisites, none of which Terraform can create** — do these first or the
apply fails at the identity provider:

1. An **App ID** with the Sign in with Apple capability enabled
   (`com.rrochlin.LiftingCoach`).
2. A **Services ID**, e.g. `com.rrochlin.LiftingCoach.signin`. This is the
   `client_id` Cognito uses — *not* the bundle id. Its Return URL must be
   `https://${domain}.auth.${region}.amazoncognito.com/oauth2/idpresponse`,
   which means the Cognito domain has to be decided before the Services ID can
   be finished. Pick `lift-coach-prod` and use it in both places.
3. A **Sign in with Apple key**, downloaded once as a `.p8`. Yields a Key ID;
   the Team ID is `33G44VZ97Z`, the same one `Tools/testflight.sh` signs with.

**`aws_cognito_user_pool_domain`** — `domain = "lift-coach-prod"`, prefix domain
rather than custom. A custom domain needs an ACM certificate in us-east-1 and a
Route53 record for a page the lifter sees for about two seconds.

**`aws_cognito_identity_provider`** — `provider_name = "SignInWithApple"`,
`provider_type = "SignInWithApple"`, with `provider_details` carrying
`client_id` (the Services ID), `team_id`, `key_id`, `private_key`, and
`authorize_scopes = "email name"`. `attribute_mapping = { email = "email" }`.

**On the client**, alongside the SRP flows above:
`supported_identity_providers = ["COGNITO", "SignInWithApple"]`,
`allowed_oauth_flows_user_pool_client = true`, `allowed_oauth_flows = ["code"]`,
`allowed_oauth_scopes = ["openid", "email", "profile"]`,
`callback_urls = ["liftcoach://callback"]`,
`logout_urls = ["liftcoach://signout"]`. The custom scheme needs a matching
`CFBundleURLSchemes` entry in `project.yml`.

Adding OAuth config does **not** remove SRP. Both coexist on one client, which
is the point: Amplify's `signIn` and `signInWithRedirect(.apple)` both work.

**The private key ends up in Terraform state, and there's no way around it.**
Terraform has to hand the key to the Cognito API, so whatever route it takes —
SSM SecureString read through a data source, a `sensitive` variable, Secrets
Manager — the value is in state. The honest mitigation is the one already in
place: the backend has `encrypt = true` on a private bucket. Recommended route
is an SSM SecureString created out of band, so the key is never in a shell
history or a `.tfvars` file:

```sh
aws ssm put-parameter --name /lift-coach-prod/apple/signin-key \
  --type SecureString --value file://AuthKey_XXXXXXXX.p8
```

read back with `data "aws_ssm_parameter"` (`with_decryption = true`). CI's
credentials need `ssm:GetParameter` and `kms:Decrypt` on the SSM default key for
the plan to work.

> ### One account per person, and the app enforces it
>
> A Sign in with Apple sign-in creates a **separate user pool user**
> (`SignInWithApple_…`) with its own `sub`. Signing up with email and later
> signing in with Apple therefore produces two identities, two S3 prefixes and
> two snapshots.
>
> That interacts with something already built: `UserStore.bind` **refuses to
> bind a second account** to a database that already carries one, because
> adopting one person's log under another identity would upload their sessions
> into somebody else's snapshot. So switching sign-in method on an existing
> install doesn't quietly fork the data — it throws `AccountBindingError`, which
> is the app protecting itself correctly and will look exactly like a bug if
> nobody expects it.
>
> Pick one sign-in method and stay on it. Joining two after the fact is one
> `cognito-idp:AdminLinkProviderForUser` call, and it has to happen before the
> second identity has ever uploaded anything.

Apple also returns the user's name only on the *first* authorization, and the
email may be a `@privaterelay.appleid.com` forwarder. Neither matters here —
nothing keys on either, and `sub` is the only claim any of this reads — but
`AuthSession.email` will show the relay address if that's what the lifter chose.

### 3.3 Identity pool

**`aws_cognito_identity_pool`** — `${local.prefix}`.
- `allow_unauthenticated_identities = false`. There is nothing here for an
  anonymous caller to do.
- `allow_classic_flow = false`. The enhanced flow is what applies the role
  mapping and the principal tags; the classic flow lets a caller name the role
  it wants, which is precisely the decision that must not be the caller's.
- One `cognito_identity_providers` block: the client id, provider name
  `cognito-idp.${region}.amazonaws.com/${user_pool_id}`, and
  **`server_side_token_check = true`**. That last one makes Cognito confirm the
  user still exists and the token hasn't been revoked at the moment credentials
  are issued — it's what makes deleting a user actually cut off their access
  rather than leaving valid credentials in the field until the token expires.

**`aws_cognito_identity_pool_provider_principal_tag`** — this is the mechanism
the whole design rests on.

```hcl
resource "aws_cognito_identity_pool_provider_principal_tag" "sub" {
  identity_pool_id       = aws_cognito_identity_pool.main.id
  identity_provider_name = "cognito-idp.${data.aws_region.current.name}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  use_defaults           = false
  principal_tags         = { sub = "sub" }
}
```

**`use_defaults = false` is not optional.** The defaults map `aud` and `sub` to
tags named `aud` and `sub` — which sounds like what we want, but the default
`sub` is populated from the *identity pool* identity id, not the user pool
claim. See the box below; this is the single easiest thing to get wrong here.

> ### The identifier trap, stated plainly
>
> There are two different "subs" in play and they are not interchangeable:
>
> - **`${cognito-identity.amazonaws.com:sub}`** — the identity pool's own
>   identity id, shaped `us-west-2:8f3c…`. This is the variable most examples
>   of this pattern use.
> - **The user pool `sub`** — a bare UUID, and the thing this entire codebase
>   already keys on: `v14_cognitoSub` on the `user` row, `object_key(subject)`,
>   `subject_from_key`, `USER#{sub}` in DynamoDB, and `AuthSession.subject`.
>
> Key the S3 prefix on the identity id and you have two identifiers for one
> lifter and a mapping table to keep them married. Mapping the user pool claim
> to a principal tag and writing `${aws:PrincipalTag/sub}` in the policy is what
> keeps it at one. Get this wrong on the first apply and fixing it means copying
> every object.

**`aws_iam_role`** — `${local.prefix}-authenticated`. Trust policy:

```hcl
data "aws_iam_policy_document" "authenticated_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
    principals {
      type        = "Federated"
      identifiers = ["cognito-identity.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "cognito-identity.amazonaws.com:aud"
      values   = [aws_cognito_identity_pool.main.id]
    }
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "cognito-identity.amazonaws.com:amr"
      values   = ["authenticated"]
    }
  }
}
```

**`sts:TagSession` is required** and is easy to leave out, because the role
works without it right up until the moment a policy reads a principal tag —
whereupon every request 403s with a message about the resource, not the tag.
The `aud` condition is what stops a different identity pool in the same account
from assuming this role; the `amr` condition is what stops an unauthenticated
identity from doing so.

**`aws_cognito_identity_pool_roles_attachment`** — `authenticated` → that role.
No role mappings; there is one kind of user.

### 3.4 The permissions the phone actually gets

```hcl
{
  Sid      = "OwnSnapshotOnly"
  Effect   = "Allow"
  Action   = ["s3:PutObject", "s3:GetObject"]
  Resource = "${bucket_arn}/users/$${aws:PrincipalTag/sub}/*"
},
{
  Sid      = "SnapshotEncryption"
  Effect   = "Allow"
  Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
  Resource = kms_key_arn
}
```

(Escaped as `$${…}` inside a Terraform `jsonencode`/template so Terraform passes
the variable through to IAM rather than trying to interpolate it itself. A plain
`${aws:PrincipalTag/sub}` is a plan-time error, which at least fails loudly.)

What is **absent**, and should stay absent:

- **No `s3:DeleteObject`.** The phone never deletes its snapshot; replacing one
  is a PUT. A backup the device can erase is a backup a bug can erase.
- **No `s3:ListBucket`.** There is exactly one key and the phone knows its name.
  Listing would also leak the existence of other prefixes, which is worth not
  doing even in an account with one user.
- **No `s3:GetObjectVersion`.** Restore means "the current snapshot." Reading an
  arbitrary older version is a recovery operation, and the moment it's needed it
  should be a deliberate act with a terminal, not an ambient capability the app
  carries.
- **No DynamoDB.** The phone never reads the index; §6 explains what it reads
  instead.

The KMS grants belong here rather than anywhere else, and they're the most
likely source of a confusing failure: without them the phone gets a 403 from S3
on a request that looked perfectly well-formed, and the error names the bucket.

---

## 4. S3 — the snapshot bucket

One object per user: `users/{sub}/snapshot.sqlite.gz`. ~2–3 MB per upload,
roughly 26 uploads a month at six sessions a week.

**`aws_s3_bucket`** — `${local.prefix}-snapshots`. No `force_destroy`.

**`aws_s3_bucket_versioning`** — Enabled. This is what makes point-in-time
restore free: a bad snapshot is recovered by reading a noncurrent version, with
no backup system to build.

**`aws_s3_bucket_lifecycle_configuration`** — **ships with the bucket, not after
the bill.** Versioning retains every upload forever otherwise.
- `noncurrent_version_expiration { noncurrent_days = 30 }` — enough history to
  notice and undo a bad restore, and it caps steady state at ~80 MB per user
  instead of unbounded growth.
- `abort_incomplete_multipart_upload { days_after_initiation = 7 }` — a phone
  that dies mid-upload on a cellular link otherwise leaves parts that are billed
  and invisible.

**`aws_kms_key` + `aws_kms_alias`** — alias `alias/${local.prefix}-snapshots`,
`deletion_window_in_days = 30`, and **`enable_key_rotation = false`** — see
**D2**, where the reason is a billing one and worth reading before flipping it.

**`aws_s3_bucket_server_side_encryption_configuration`** — SSE-KMS against that
key, with **`bucket_key_enabled = true`**. Not a micro-optimization: without it
S3 makes a KMS call per object operation, and with it one data key covers a
bucket-key period. It's the difference between KMS request charges being a
rounding error and being the larger half of the bill.

**`aws_s3_bucket_public_access_block`** — all four `true`.

**`aws_s3_bucket_policy`** — one statement: `Deny` on `s3:*` when
`aws:SecureTransport` is `false`. A bucket holding five years of one person's
training and bodyweight shouldn't be reachable over plaintext even in principle.

**No CORS** — nothing browser-based calls this, and an unnecessary CORS block
reads as permission granted for a reason nobody remembers.

**No Object Lock, and this is a decision rather than an omission** — see **D5**.
Enabling it is irreversible without recreating the bucket, so it's worth being
sure: it would not provide the single-writer guarantee it looks like it might,
and it would break the lifecycle rule above.

### The event notification

**`aws_s3_bucket_notification`** with one `lambda_function` block:
`events = ["s3:ObjectCreated:*"]`, `filter_prefix = "users/"`,
`filter_suffix = "snapshot.sqlite.gz"`.

Three things to get right:

- **It belongs in root `main.tf`, not in the `s3` module.** The bucket comes
  from `module.s3` and the target from `module.lambdas`; wiring them from root
  is the same move `amazing-adventure` makes with
  `aws_s3_bucket_policy.app_cf_read`, and for the same reason.
- **`depends_on` the `aws_lambda_permission`.** S3 validates that it may invoke
  the function at the moment the notification is created; without the ordering
  the first apply fails with a permissions error that looks like an IAM bug.
- **It is authoritative for the whole bucket** — a second
  `aws_s3_bucket_notification` silently replaces the first. When 2.2 wants
  another trigger it goes in this same resource as an extra block.

**`aws_lambda_permission`** for it: `principal = "s3.amazonaws.com"`,
`source_arn` = the bucket ARN, **and `source_account` = the account id**. The
account condition is what stops a bucket in somebody else's account from
invoking this function; an ARN alone is guessable.

---

## 5. Lambda — one function, and it verifies

**`${local.prefix}-index-snapshot`**, `python3.12`, `arm64`, handler
`liftcoach_server.handlers.index_snapshot`, timeout **60s**, memory **512 MB**,
`reserved_concurrent_executions = 2`.

Following `ONBOARDING.md`'s placeholder pattern **from the start**:

```hcl
filename         = data.archive_file.placeholder.output_path
source_code_hash = data.archive_file.placeholder.output_base64sha256
lifecycle {
  ignore_changes = [filename, source_code_hash]
}
```

The placeholder's inner filename should be `index.py`, not `bootstrap` —
`amazing-adventure`'s Lambdas are Go binaries on `provided.al2023`; this is
Python.

An `aws_cloudwatch_log_group` at `/aws/lambda/${name}`, `retention_in_days = 14`,
with the function `depends_on` it — otherwise Lambda creates the group
implicitly with **never-expire** retention and Terraform doesn't own it.

Environment: `SNAPSHOT_BUCKET`, `SNAPSHOT_META_TABLE`.

**No layer, no container.** The package is standard library plus boto3, and
every Lambda runtime ships boto3. Deploying a second copy of what the platform
provides is a copy to keep updated. `sqlite3` and `gzip` are both stdlib, which
is the reason this can read the snapshot at all without a build step.

### What it does, and why that's the interesting part

It downloads the object **at the `versionId` the event names**, gunzips it into
`/tmp`, opens it read-only, and records what it finds:

- **Schema version**, read from `grdb_migrations`. That table is an *unordered
  set* of identifiers — `SnapshotExporter.describe` says so in a comment and
  orders them against the migrator's registration order. Python does the same
  thing, and `schema.KNOWN_MIGRATIONS` is already that list in that order. This
  is what turns the `Migrations.swift` pin from documentation into a
  load-bearing dependency: an identifier absent from `KNOWN_MIGRATIONS` is a
  migration newer than this deploy, which is exactly the `newerThanServer`
  marker 2.3's query tools consult before answering.
- **Row counts**, per user table, using the exporter's own query
  (`sqlite_master`, excluding `sqlite_%` and `grdb_%`).
- **Etag, size and versionId** from the event record.

The version pin matters and is not fussiness: on a versioned bucket a bare
`head`/`get` returns the *current* version. Two uploads inside the same minute —
a finished workout and a plan save, which is ordinary — would otherwise have the
first event read the second object's contents and file them against the first
event's etag and size, producing a row that is internally inconsistent with no
trace that anything went wrong.

**A file it cannot read is recorded, not retried** (**D6**). `readable = false`
plus the reason, and return normally. A corrupt or truncated snapshot will still
be corrupt on the retry, so raising would burn the retry budget and land it in a
dead-letter queue nobody is watching, with the index still saying nothing.
Transient failures (throttling, a timeout talking to S3) **do** raise, so S3
retries them.

### IAM

Standard `lambda_assume` document and a CloudWatch Logs policy, exactly as in
`amazing-adventure/modules/lambdas/main.tf`. Beyond that:

| grant | on |
| --- | --- |
| `s3:GetObject`, `s3:GetObjectVersion` | `${bucket_arn}/users/*` |
| `kms:Decrypt` | the key |
| `dynamodb:PutItem` | the meta table |

`GetObjectVersion` is needed because of the version pin above. Note there's no
separate head permission in S3 — `head_object` is authorized as `s3:GetObject`,
which surprises people.

Nothing here can write to the bucket, and nothing that isn't this function can
write the index. That's the property worth preserving as 2.2 adds functions:
**the index is a consequence of an object existing**, so no other caller can
make it claim something the bucket doesn't hold.

---

## 6. DynamoDB — one table, holding a derived record

**`${local.prefix}-snapshot-meta`**, `PAY_PER_REQUEST`, hash key only on a
**String** attribute named exactly `pk`, holding `USER#{sub}`.

Items: `key`, `versionId`, `etag`, `schemaVersion`, `newerThanServer` (BOOL),
`unrecognizedMigrations` (L), `byteCount` (N), `uploadedAt`, `rowCounts` (M of
N), `readable` (BOOL), `problem` (S), `deviceId` (S, self-reported, for
debugging only).

The attribute name `pk` and the type `S` are read directly by
`aws.py::_partition_key` — not free choices. `amazing-adventure` keys UUIDs as
Binary to match Go's UUID storage; that reasoning explicitly doesn't carry here,
because the key is a Cognito `sub`, which is a string.

Only `pk` is declared in an `attribute` block. Everything else is non-key and
DynamoDB is schemaless about it — declaring an attribute that indexes nothing is
a `terraform plan` error, not documentation.

**No GSIs.** Every access is a `get_item` by subject; there is no query here
that doesn't already know whose account it's about.

**No point-in-time recovery**, deliberately: the table is derived. It can be
rebuilt by re-reading the bucket, which is the same argument
`ExerciseStatsStore` makes for its own table on the device. Paying for PITR on
derived data is paying to protect a cache.

**`deletion_protection_enabled = true`.** Cheap, and a `terraform destroy` aimed
at the wrong directory is the failure mode it exists for.

**No lease table** — see §8.

### What the phone reads instead

Nothing. `BackendClient.latestSnapshot()` becomes a `HeadObject` the phone makes
with its own credentials: etag, size, last-modified and the self-reported user
metadata come back in one call, which is everything a "last backed up 3 hours
ago, 2.4 MB" line needs. `snapshotMeta` exists for the *server* side — it's
where 2.2 and 2.3 learn whether the file is readable and whether its schema is
newer than they understand, without downloading 3 MB on every chat turn.

That does mean the descriptor the phone builds carries the phone's own
self-reported row counts rather than the verified ones. Fine for a display
string; it is not fine for anything that decides something, and nothing on the
device does.

---

## 7. GitHub OIDC deploy role

Per `ONBOARDING.md`, using the shared `../modules/github-oidc` module.

```hcl
module "github_oidc_deploy" {
  source                   = "../modules/github-oidc"
  role_name                = "github-actions-lift-coach"
  allowed_subject_patterns = ["repo:rrochlin/Lifting-Coach:ref:refs/heads/main"]
  common_tags              = local.common_tags
  policy_json              = jsonencode({ /* below */ })
}
```

Restricted to `refs/heads/main` rather than `amazing-adventure`'s `:*`. That
repo's pattern is documented as an exact match for a role adopted by
`terraform import`; this one is new, so it starts at the tighter setting — a PR
branch shouldn't be able to deploy code.

Permissions: `lambda:UpdateFunctionCode`, `lambda:GetFunction`,
`lambda:GetFunctionConfiguration` on
`arn:aws:lambda:${region}:${account}:function:${local.prefix}-*`, plus
`ssm:GetParameter(s)` on `/${local.prefix}/*`. No S3 and no CloudFront — there's
no web client to sync and no distribution to invalidate.

Output `github_actions_deploy_role_arn` and set it as a repo secret in
`Lifting-Coach`, for a `deploy-server.yml` that zips
`server/src/liftcoach_server/` and calls `aws lambda update-function-code`. That
workflow is app-repo work, not Terraform, but it's what makes the placeholder
pattern true rather than aspirational — **until it exists the function is a stub
that indexes nothing.**

---

## 8. What the presigning API was doing, and what replaced it

An earlier draft put an HTTP API in front of S3: five routes, six Lambdas, a
DynamoDB device lease, and presigned PUTs carrying **signed** `x-amz-meta-*`
headers so the phone couldn't misreport its schema version. Direct-to-S3 deletes
all of that. Three claims that machinery made are worth accounting for.

**"The schema stamp is a fact about the object, not the uploader's word for
it."** IAM has no condition key for `x-amz-meta-*` on a PUT — you can condition
on tags, ACL, SSE and storage class, but not metadata — so under direct
credentials the stamp is self-reported. This looks like a loss and isn't,
because the replacement is stronger: **the indexer opens the file and reads
`grdb_migrations` itself.** A signature proved the phone said something
consistently; reading the file proves what's in it. The old design could be
defeated by a phone that computed its own stamp wrongly, which is the only
failure mode that was ever realistic here — there is one user and no adversary.

**"Neither refusal ever costs an upload."** The schema gate refused below a
floor of `v14_cognitoSub`. By the argument recorded in `schema.py` itself, that
floor is unreachable: a build without that migration has no column to record an
account, so it can't sign in. The gate's entire runtime behaviour was to record
a version — which is now done by reading it.

**"One device at a time."** A *lease* is genuinely gone: with standing
credentials there's no chokepoint at which one can be enforced, and no amount of
cleverness recovers it (a pre-token-generation trigger could bake lease state
into a claim, but credentials live an hour, so enforcement would lag by up to an
hour). **But the thing the lease was for is recoverable, and cheaper** — see
below.

**It would be an acceptable loss even without that**, because the phone is the
system of record. The snapshot is a backup. Two phones alternating uploads means
the last one wins and *nothing is destroyed* — the losing phone still holds its
own log in full. The one genuinely destructive operation is restore, and that
decision already lives on the device in `SnapshotImporter`, which refuses a
snapshot missing local workouts.

### Conditional writes: the single-writer property, enforced by S3

S3 supports conditional writes on `PutObject`: `If-None-Match: *` succeeds only
if the object doesn't exist, and `If-Match: <etag>` succeeds only if the current
object's etag matches. That is optimistic concurrency, and it delivers what the
lease was actually for **with no Terraform, no Lambda and no table** — the
permission is already `s3:PutObject`.

The phone is most of the way there already. `SnapshotWatermarkStore` keeps a
per-account watermark of the last snapshot it uploaded — today a bare sha256
(`watermark(for:)` / `setWatermark(_:for:)`), so it needs a second value beside
it holding the etag S3 returned. Same key, same lifetime, one more string.

- First upload ever: `If-None-Match: *`.
- Every upload after: `If-Match: <the etag from my last upload>`.
- **412 Precondition Failed means another device wrote since I last did.** That
  is the "signed in elsewhere" signal, enforced by S3 rather than believed on
  trust, obtained at the exact moment it matters.

Be precise about what this is: **detection of a lost update, not mutual
exclusion.** It doesn't stop the second phone; it tells it. The lifter then
decides whether to overwrite — which is Core Tenet 1 in the place it belongs,
rather than the app silently picking a winner. It also catches the same phone
running on a stale watermark, which a lease never would have.

Not in this spec's scope because it's app-side code, and flagged for whoever
writes it: **check that the iOS layer can send the header.** Amplify's Storage
plugin may not surface conditional headers, in which case the PUT wants the AWS
SDK for Swift's `PutObjectInput.ifMatch` directly. Worth confirming before
building the flow around it.

---

## 9. Deliberately not in this pass

Named so the module layout anticipates them, not built:

- **2.2 — chat.** A WebSocket `aws_apigatewayv2_api`
  (`$connect`/`$disconnect`/`$default`) with a Cognito JWT authorizer, a
  `${prefix}-connections` table **with** TTL, a `${prefix}-conversations` table,
  and `bedrock:InvokeModelWithResponseStream` on the chat function's role. Note
  the WS API needs its own named stage, unlike an HTTP API's `$default`. This is
  where API Gateway enters the design — for streaming, which is a thing it's
  actually needed for.
- **2.3 — the coach's output.** A `${prefix}-draft-plans` table, and `/tmp`
  snapshot caching keyed by ETag, which is a memory and timeout change on the
  chat function rather than a new resource.
- **Account deletion.** App Review requires an in-app path once accounts exist.
  Small — `cognito-idp:AdminDeleteUser`, a `DeleteItem`, and an S3 delete — but
  there's a real trap: **on a versioned bucket, deleting an object leaves every
  noncurrent version in place.** A deletion path that means what it says has to
  enumerate and delete versions, or §4's 30 days has to be accepted as the
  actual deletion window and stated honestly in the privacy manifest. Decide it
  when it's built, not during review.
- **Budget alarm.** An `aws_budgets_budget` at ~$25/month with an email
  notification. Not phase-specific, but the first thing in this design that can
  run away is Bedrock in 2.2, and it's easier to add now than to wish for later.

---

## 10. Decisions, settled

**D1 — `lift-coach`.** Directory, prefix, state key and CI matrix entry. Note
this is a third spelling alongside the `Lifting-Coach` repo and the
`com.rrochlin.LiftingCoach` bundle id; §2 says where the two meet. `Overview.md`
said `workout-app` from the design vault's working title and has been corrected.

**D2 — SSE-KMS with a customer-managed key, and it holds at $1/month.** The key
is $1. Requests are the other half of KMS billing, and with `bucket_key_enabled`
a month of uploads is on the order of tens of KMS calls against a $0.03/10,000
rate — a rounding error, and inside the free tier's 20,000/month for the first
year regardless.

**Automatic rotation is off, and that's what keeps it at exactly $1.** AWS bills
rotated keys per key *version* beyond the first couple, so a key rotating
annually creeps upward over the years. I'm not certain of the exact threshold,
and since the constraint here is precisely $1 the safe reading is to leave
rotation off rather than discover it on a bill. It buys very little here anyway:
the key material never leaves KMS, so there's no exposure for a rotation to
remediate. Turning it on later is a one-line change and old objects stay
readable under their original version.

**D3 — refresh token 30 days, Cognito's default.** The question was posed on a
wrong premise, which is worth recording so it isn't re-litigated: **Cognito
refresh tokens do not slide.** `REFRESH_TOKEN_AUTH` returns new access and id
tokens but not a new refresh token, so validity runs 30 days from *sign-in*
regardless of activity — an inactivity timeout is not something this setting can
express. Given that, the deciding argument is that block lengths vary and there
is no natural period to tune to, so the platform default is the honest choice.
Consequence to expect rather than debug: a monthly re-auth, including while
training six days a week. Uploads pause until then; logging doesn't, because the
app is local-first.

**D4 — Sign in with Apple ships in this pass.** §3.2. Worth being explicit that
the question conflated two things: deferring SIWA would never have deferred
Cognito — the user pool, the `sub` and `v14_cognitoSub` are built either way,
and SIWA is one federated provider attached to a pool that already exists. What
doing it now genuinely buys is avoiding the account-linking problem: an
email-then-Apple switch creates two identities, and `UserStore.bind` refuses the
second, so it's cheaper never to have two.

**D5 — no Object Lock, and it wouldn't have done this.** The instinct is right
and the mechanism doesn't match it. Object Lock is WORM *retention*: it stops a
specific object **version** from being deleted or overwritten for a retention
period, for compliance regimes. Four reasons it doesn't apply:

- **It wouldn't stop the second phone.** Object Lock requires versioning, and on
  a versioned bucket a PUT to an existing key creates a *new version* — the lock
  protects the old one from deletion and the new upload succeeds anyway. It
  guarantees you can still read what was there, which is what versioning already
  gives you.
- **It has no notion of who.** No identity, no ownership, no holder. It can't
  express "this device and not that one," which is the whole content of a lease.
- **It would break §4's lifecycle rule.** Lifecycle can't expire a locked
  noncurrent version until its retention lapses, so the 30-day cleanup silently
  stops working and storage grows without bound.
- **It's irreversible.** Object Lock must be enabled at bucket creation and
  can't be turned off; undoing the choice means making a new bucket and copying
  everything.

The thing that *does* deliver the instinct is a conditional `PutObject` —
`If-Match` on the etag the phone last uploaded, so a 412 means another device
wrote since. Enforced by S3, costs nothing, and reuses a watermark the app
already keeps. §8 has the mechanism and its one honest limitation.

**D6 — the indexer records an unreadable file rather than retrying.** §5 has the
reasoning. The alternative is a dead-letter queue, which is a second thing to
watch that would be empty except when it matters and nobody is looking.

---

## 11. Verification, in order

1. `terraform fmt -check -recursive` and `terraform validate` in `lift-coach/` —
   the CI's first two steps, so failing them locally is free.
2. **Confirm the plan reaches CI.** Open the PR and check the plan comment is
   headed ``#### App: `lift-coach` `` — a directory absent from `matrix.app`
   produces no comment at all, which reads as a passing build.
3. After apply: create a user in the pool, sign in, exchange for credentials,
   and **print the caller identity** (`sts:GetCallerIdentity`). Confirm the
   assumed role is `${prefix}-authenticated`. Cheapest possible check that the
   identity pool and the role attachment are wired.
4. **The test that matters most:** with those credentials, attempt a PUT to
   `users/<some-other-uuid>/snapshot.sqlite.gz`. It must 403. Then PUT to the
   caller's own `sub` prefix — it must succeed. One passing and one failing, in
   that order, is what proves the principal tag is populated and the policy
   variable resolved; a policy where the tag came out empty tends to deny
   *everything*, which looks identical to a working deny if you only test the
   negative case.
5. PUT a real gzipped snapshot exported from the app, with
   `x-amz-checksum-sha256` set. S3 verifies the body against it — that property
   survives the redesign intact, and it's what makes a corrupted upload
   impossible rather than detectable afterwards. A 403 here rather than at step
   4 means the §3.4 KMS grants.
6. Read the `snapshotMeta` item and confirm `schemaVersion` and `rowCounts`
   match what `SnapshotExporter` reported for that same file — **and that they
   were derived, not copied.** Prove it by uploading again with a deliberately
   wrong `x-amz-meta-schema-version`: the index must still record the true
   version out of `grdb_migrations`. That single check is the design's central
   claim, and it's the one that replaced a signature.
7. Upload a file that isn't a SQLite database at all. The index must record
   `readable = false` with a reason, and the function must not retry.
8. **Sign in with Apple end to end on the phone**, and confirm the `sub` it
   yields is what the S3 prefix uses. This is the step that catches a Services
   ID whose Return URL doesn't match the Cognito domain, which fails at Apple's
   end with an error that says nothing useful about why.
9. Re-upload twice with `If-Match` set to a stale etag. The second must 412.
   That's §8's single-writer signal, and it's worth confirming against real S3
   once before any app code is built on it.
