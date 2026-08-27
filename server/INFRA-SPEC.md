# Terraform spec — phase 2.1

What `server/infra/` has to create for the phone to back its database up and
restore it. Written to be implemented by someone who has not read the app, and
to be **validated before** it is, which is why every non-obvious resource
carries the reason it's shaped that way.

Scope is phase 2.1 only: identity, one object per user, and a record of what
that object turned out to contain. The chat (2.2) and the query tools (2.3) get
their own resources later; §9.1 sketches them so the module layout doesn't have
to be reorganized to accept them. **§9.2–9.5 are not sketches** — they are the
App Store compliance work that the first cloud build cannot ship without, and
they are specified here because every one of them is a consequence of a
resource in this document.

Read alongside:
- `notes/Workout App/Backend/Overview.md` — why the design is snapshot-and-draft.
- `terraform-infrastructure/ONBOARDING.md` — the placeholder Lambda pattern and
  the CI matrix, both load-bearing here. Its subtree step is deliberately not
  followed; §2 says why.

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

**There is no subtree link, and that's a decision.** An earlier draft mirrored
`terraform-infrastructure` into `server/infra/` per `ONBOARDING.md`'s pattern.
Dropped on the owner's call, in favour of a clean ownership split:

- **`terraform-infrastructure` owns every resource definition** — the function's
  runtime, memory, timeout, architecture, handler, environment and its S3
  trigger, along with Cognito, the bucket, the key and the table.
- **This repo owns the function's code**, and ships it with
  `.github/workflows/deploy-server.yml`.

The seam is `update-function-code`, which by construction can only replace code
— so the boundary is enforced by the API rather than by remembering it. The
Terraform side carries `ignore_changes = [filename, source_code_hash]` (§5) so a
deploy from here never reads as drift there, and the workflow calls
`update-function-code` with no configuration flags at all, so a field with one
owner never acquires a second.

A subtree would have put a copy of the Terraform here that nothing in this repo
plans or applies, which is a copy that can only go stale.

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
4. **Two SSM parameters**, put by hand — the `.p8` as a SecureString and the Key
   ID beside it. Commands and reasoning below.

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

read back with `data "aws_ssm_parameter"` (`with_decryption = true`).

**Which credentials need what, precisely**, because there are two principals and
only one of them matters here. The `terraform-infrastructure` workflow runs
`plan` and `apply` as a **static IAM user** held in repo secrets — not §7's
OIDC role, which belongs to the app repo and only pushes Lambda code. That IAM
user is the one needing `ssm:GetParameter` on both parameters and `kms:Decrypt`
on the SSM default key, and `plan` reads the data source, so a missing grant
fails before anything is applied.

**That list is the minimum for `plan`, and it is not enough for the first
`apply`** — confirmed the hard way. §4 creates a customer-managed key, so the
same user also needs `kms:CreateKey`, `kms:CreateAlias`, `kms:TagResource` and
the ability to write the key policy. Missing those fails **midway through an
apply** rather than at plan: the KMS-dependent resources — the key, the alias,
the bucket's SSE configuration and both IAM role policies interpolating the key
ARN — are left uncreated while everything else is already live. Grant the whole
set before the first apply rather than discovering it against a half-built
stack.

It is managed outside the Terraform, so **this cannot be granted by the code in
this spec** — it's a console check, listed in §11. Expect it to be the first
failure: the plan stops at the data source with an `AccessDenied` naming the
parameter, which reads like a parameter that was never created rather than one
that can't be decrypted.

Grant `kms:Decrypt` with a `kms:ViaService` condition pinned to
`ssm.${region}.amazonaws.com` rather than bare. Decryption is only ever wanted
as part of an SSM read here, and the condition means a leak of those static keys
doesn't also hand over the ability to decrypt arbitrary ciphertext by other
routes.

**The Key ID goes into SSM too, beside it** — `/lift-coach-prod/apple/key-id`,
a plain `String` rather than a SecureString, since a Key ID isn't secret:

```sh
aws ssm put-parameter --name /lift-coach-prod/apple/key-id \
  --type String --value XXXXXXXXXX
```

Not because it needs protecting, but because **`key_id` and `private_key` are
one credential pair**: Apple issues them together and they rotate together. A
Key ID committed as a variable default while the key lives in SSM lets the two
drift, and the failure mode is Sign in with Apple rejecting every
authentication with an error that names neither half. Keeping them in one place
makes the pair atomic and gives the owner one prerequisite step instead of two.

It also fails better. A data source pointed at a parameter that doesn't exist
yet stops the plan naming the missing parameter; a required variable with no
default stops it saying "No value for required variable", which is true and
tells you nothing about Apple. And nothing has to be threaded through CI —
`.github/workflows/terraform.yml` passes no `-var` and the matrix has no tfvars
mechanism, so a variable without a default would break `plan` for this
directory permanently.

Team ID and Services ID stay as variables **with defaults**, and the asymmetry
is deliberate: both are public constants that already exist and are written in
this document. The Key ID does not exist until the owner creates the key.

**`ignore_changes` on the identity provider, and `private_key` is not the only
key that needs it.** Cognito does not return the private key on read, so
without it every plan shows a diff forever and an auto-apply re-sends the key on
every run.

**Confirmed at apply time, and the first list was too short.** Cognito populates
further `provider_details` after creation and reports them back: `authorize_url`,
`token_url`, `oidc_issuer`, `token_request_method` and
`attributes_url_add_attributes`. None are in config, so Terraform plans to
delete them and Cognito re-adds them, forever — the first apply came out
"5 added, 1 changed" where nothing should have changed at all. Name the
server-populated keys **individually** rather than ignoring `provider_details`
wholesale, so `client_id`, `team_id`, `key_id` and `authorize_scopes` still
apply when they change.

> **Ignore only what cannot be stated; state everything that can.** Those keys
> and the private key qualify because none of them can be written truthfully in
> config — the key is never readable back and the URLs are Cognito's to derive.
> `attribute_mapping` is the opposite case: Cognito adds `username = "sub"` on
> its own, and that is a stable, meaningful value, so it should be **declared**
> next to `email = "email"` rather than ignored. `ignore_changes` buys a clean
> plan by making the config silent about a real value, and it hides future drift
> in that value along with the noise. Declare it, then confirm the following
> plan is clean; if Cognito reports it back in some other form, ignoring is the
> fallback rather than the first move.

That perpetual diff is the worse outcome, and not merely because it's noisy: it
would mean "empty plan" stops being a usable signal **in the one directory that
holds the identity pool and the IAM role granting access to every lifter's
data**. A directory whose plan is never clean is a directory where a real
unintended change hides in the noise.

The cost is that rotating the Apple key by updating SSM will not apply on its
own — it needs `terraform apply -replace=module.cognito.aws_cognito_identity_provider.apple`
— module-qualified, since Terraform runs from `lift-coach/` and the resource is
inside the module. The bare address errors with "no matching resources" at
precisely the moment someone is mid-rotation.
Rare, survivable, and worth a comment on the resource itself rather than only
here, because the person who needs it will be reading the Terraform.

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
  allowed_subject_patterns = [
    # Not `repo:rrochlin/Lifting-Coach:...` — see below. The numbers are the
    # owner and repository database ids, and they are the point.
    "repo:rrochlin@43162265/Lifting-Coach@1312491618:ref:refs/heads/main",
  ]
  common_tags = local.common_tags
  policy_json = jsonencode({ /* below */ })
}
```

Restricted to `refs/heads/main` rather than `amazing-adventure`'s `:*`. That
repo's pattern is documented as an exact match for a role adopted by
`terraform import`; this one is new, so it starts at the tighter setting — a PR
branch shouldn't be able to deploy code.

> ### The subject claim carries database ids, and this repo is not like the other one
>
> **This cost a deploy and an hour, so it is written down rather than
> remembered.** The first deploy failed with `Not authorized to perform
> sts:AssumeRoleWithWebIdentity` while every piece of configuration was
> provably correct — audience right, `id-token: write` set, the applied trust
> policy read back from AWS and matching the HCL character for character, the
> account's OIDC provider listing `sts.amazonaws.com`, and the push genuinely on
> `refs/heads/main`.
>
> The token GitHub actually sent carried:
>
> ```
> sub  repo:rrochlin@43162265/Lifting-Coach@1312491618:ref:refs/heads/main
> ```
>
> GitHub now issues **immutable subject claims** — owner and repository
> *database ids* embedded in the subject — so that a repository deleted and
> recreated under the same name cannot inherit a trust relationship. The old
> `repo:owner/name:...` form is a name, and names can be reused.
>
> **It is not account-wide, and that is the part that misleads.** Queried
> directly, the two repos disagree:
>
> ```
> Lifting-Coach             repo:rrochlin@43162265/Lifting-Coach@1312491618
> An-Amazing-Adventure      repo:rrochlin/An-Amazing-Adventure
> terraform-infrastructure  repo:rrochlin/terraform-infrastructure
> ```
>
> All three report `use_default: true` and `use_immutable_subject: false`, so nobody
> configured this — the *default* differs, evidently by repository age. So
> `amazing-adventure` keeps working, its pattern in this same Terraform stays
> correct, and copying that working pattern into a new app's directory produces
> a role that cannot be assumed. Check the prefix rather than copying:
>
> ```sh
> gh api /repos/<owner>/<repo>/actions/oidc/customization/sub
> ```
>
> Matching the id form is also the better security posture, not a workaround —
> it is exactly the repo-recreation attack the immutable format exists to close,
> so pinning the ids is stricter than the name ever was. The alternative, forcing
> the legacy format back with `PUT …/oidc/customization/sub`, opts out of that
> for cosmetic consistency and is the wrong trade.
>
> `.github/workflows/deploy-server.yml` prints this claim on any future
> assume-role failure, which is how it was found.
>
> **No resolver, and that's decided.** The tempting fix is a module helper that
> queries the prefix at plan time. It trades a loud failure for a quiet one: an
> external data source errors on a machine without `gh`, or worse resolves
> differently in CI than locally, and it puts a value in a *trust policy* that
> can't be read off the diff. The ids stay literal and commented. If this
> recurs, the thing to build is a **check** — CI asserting each app's configured
> pattern still matches what GitHub reports — which catches drift both ways,
> can't fail an apply, and stays outside the state file.

Permissions: `lambda:UpdateFunctionCode`, `lambda:GetFunction`,
`lambda:GetFunctionConfiguration` on
`arn:aws:lambda:${region}:${account}:function:${local.prefix}-*`. No S3 and no
CloudFront — there's no web client to sync and no distribution to invalidate.

**No SSM.** An earlier draft granted this role `ssm:GetParameter(s)` on
`/${local.prefix}/*` for no stated reason, and §3.2 then put Apple's signing key
under exactly that path. This role's entire job is pushing a zip at a Lambda
from the app repo; giving a code-deploy credential read over the path holding
the authentication credential is a grant nobody asked for and nobody would have
noticed. It can only fetch the key as ciphertext — it has no `kms:Decrypt` — but
"only ciphertext" is a mitigation, not a reason to hold it.

Dropped rather than narrowed. If the deploy workflow later needs configuration
out of SSM, add it back scoped to the subpath it actually reads.

> **This role is not what runs Terraform.** It is assumed by a workflow in the
> **`Lifting-Coach`** repo to deploy Lambda code. `terraform plan` and `apply`
> for this directory run in **`terraform-infrastructure`**, whose workflow
> authenticates with static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` repo
> secrets belonging to an IAM user that predates the per-app split and is
> managed outside that repo. Two different principals, and §3.2's SSM
> requirement lands on the second one.
>
> **That split is intended, not drift**, and it was checked rather than assumed:
> `terraform-infrastructure`'s workflow declares neither `id-token: write` nor
> `aws-actions/configure-aws-credentials`, so it is structurally incapable of
> assuming an OIDC role — the federation was never wired, which is different
> from a role sitting unused. `An-Amazing-Adventure`'s own deploy workflows do
> use exactly that pattern, and `ONBOARDING.md` is scoped correctly throughout
> ("**your app's** deploy CI"). So there is nothing to reconcile here; the only
> live item is the static user's grant, which is §11 step 2.

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

## 9. Not in this pass — and what has to be true before it ships

### 9.1 Later phases

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
- **Account deletion.** Specified in §9.4 below — it is a compliance
  requirement rather than a nice-to-have, so it has its own section.
- **Budget alarm.** An `aws_budgets_budget` at ~$25/month with an email
  notification. Not phase-specific, but the first thing in this design that can
  run away is Bedrock in 2.2, and it's easier to add now than to wish for later.

### 9.2 The privacy manifest

`Sources/App/Resources/PrivacyInfo.xcprivacy` currently declares an empty
`NSPrivacyCollectedDataTypes`, and **that is correct today and stays correct
until the first real upload.** Apple's definition of *collect* is transmitting
data off the device in a way that lets **us** or our partners access it beyond
servicing the request — it turns on who receives the data, not on whether bytes
leave the phone. Profile's data export hands a file to the share sheet, the
system delivers it wherever the lifter chose, and we never see it. Cognito and
this bucket are the first thing in the app's history that changes the answer.

**Do not pre-declare.** A manifest listing health data in a build that uploads
nothing produces a nutrition label that misdescribes the app. These entries land
in the same commit as the upload path, not before it:

```xml
<key>NSPrivacyCollectedDataTypes</key>
<array>
    <dict>
        <key>NSPrivacyCollectedDataType</key>
        <string>NSPrivacyCollectedDataTypeFitness</string>
        <key>NSPrivacyCollectedDataTypeLinked</key><true/>
        <key>NSPrivacyCollectedDataTypeTracking</key><false/>
        <key>NSPrivacyCollectedDataTypePurposes</key>
        <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
    </dict>
    <!-- …the same dict shape for: NSPrivacyCollectedDataTypeHealth (bodyweight),
         NSPrivacyCollectedDataTypeEmailAddress and
         NSPrivacyCollectedDataTypeUserID (both from Cognito). -->
</array>
```

Four types, and each one is `Linked = true` because **every one of them is keyed
by `sub`** — that is the design, not an accident to be minimised. Workouts and
loads are Fitness; bodyweight is Health, which covers user-provided health data.
Tracking is `false` throughout: nothing here is joined to third-party data or
used for advertising.

Verify the key spellings against Apple's current documentation before shipping.
They are exact-match strings and a typo fails validation rather than degrading
quietly.

**`ITSAppUsesNonExemptEncryption` does *not* change.** It means *no non-exempt*
encryption, and standard HTTPS/TLS is exempt; SSE-KMS (§4) is server-side and
never enters the binary. `project.yml`'s `false` stays right unless the app adds
crypto of its own on top of TLS. Recorded here because `CLAUDE.md` claimed
otherwise for a while, and re-deriving a corrected fact is how it gets
un-corrected.

### 9.3 The two forms outside the repo

Neither is a code change, and both block the first cloud build:

- **The App Store Connect App Privacy questionnaire** is separate from the
  manifest and must agree with it. The manifest is the code-level declaration;
  the questionnaire generates the nutrition label.
- **A privacy policy URL.** Already required for any app, but it currently has
  nothing true to say. Once §9.2 is non-empty it has to state what is collected,
  why, how long it is kept, and how to delete it — and the retention answer has
  to match §4's lifecycle and §9.4's behaviour rather than be written
  aspirationally.

### 9.4 Account deletion

App Review requires an in-app path once accounts exist (Guideline 5.1.1(v)), and
it must *delete* rather than deactivate. Mechanically small — `AdminDeleteUser`,
a `DeleteItem`, and an S3 delete — with one trap underneath it.

**On a versioned bucket, deleting an object deletes nothing.** It writes a
delete marker; every prior version stays readable, and §4's lifecycle then holds
them for 30 more days. A deletion path built the obvious way would report
success while a complete copy of the lifter's training remained recoverable.

**Decided: enumerate and delete versions.** `ListObjectVersions` over
`users/{sub}/`, then `DeleteObjects` on every version id including the delete
markers. The alternative — accepting §4's 30 days as the real window and saying
so in the policy — is defensible and is the wrong trade here: "deleted" that
means "in 30 days" is the kind of true-on-a-technicality that this project keeps
refusing elsewhere, and the honest version costs one extra API call.

This needs `s3:ListBucketVersions` on the bucket and `s3:DeleteObjectVersion` on
the prefix, on the **deletion function's** role — deliberately not on the
phone's role (§3.4), which still has no delete permission of any kind. Deletion
is an account operation, not something a device credential should be able to do.

Everything the account touches has to be in the list, which is why this is
specified now rather than during review: the S3 prefix and all its versions, the
`snapshotMeta` item, the Cognito user, and — once 2.2 and 2.3 exist —
`conversations` and `draft-plans`.

### 9.5 Health data has extra rules

Guideline 5.1.3 forbids using health and fitness data for advertising or
use-based data mining. Nothing in this design does, and nothing here should
start.

The place it becomes a live question is **2.2**, where a training log goes into
a Bedrock prompt. In our own AWS account, with a model that does not train on
inputs, that is processing rather than disclosure — but it is worth being
deliberate about, and it gets sharper if HealthKit integration ever lands, since
HealthKit-sourced data carries its own restrictions on sharing beyond the app.
Decide it when the chat is built; do not let it arrive as a side effect.

**Scope, honestly:** all of §9.2–9.5 is Apple's rules, and they apply at one
user. GDPR/CCPA largely do not engage while the owner is the only person whose
data is in the bucket — that changes the day an external tester's log is in
there.

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
2. **Check the static IAM user can read both SSM parameters**, before opening a
   PR. It's the principal that runs `plan` (§3.2), it's managed outside the
   Terraform, and the failure surfaces as an `AccessDenied` naming the parameter
   — which reads like a parameter that was never created. Confirm
   `ssm:GetParameter` on `/lift-coach-prod/apple/*` and `kms:Decrypt` on the SSM
   default key. A console check; nothing in this spec can grant it.
3. **Confirm the plan comment contains a plan**, not just a heading. A
   directory absent from `matrix.app` produces no comment at all, which reads as
   a passing build — but checking only for the ``#### App: `lift-coach` ``
   heading is a check that passes on nothing. It did: the workflow read
   `steps.plan.outputs.stdout`, which only exists when `setup-terraform` wraps
   the binary, and `terraform_wrapper` is false. **Every plan comment in that
   repo since its initial commit was a heading and four green checkmarks.**
   Confirm a real diff and a `Plan: N to add` line.
4. **Apply is a separate, deliberate step.** Merging does not apply — the owner
   wanted a gate between reading a plan and running it, so apply is
   `workflow_dispatch`: `gh workflow run terraform.yml -f app=lift-coach`.
   Without this step a merged PR reads as done while nothing has been created.
   (GitHub Environments with required reviewers was the better mechanism and is
   unavailable: the API rejects every billing-gated protection rule on that repo
   even though the account reports plan "pro". Revisit if that's ever fixed.)
5. After apply: create a user in the pool, sign in, exchange for credentials,
   and **print the caller identity** (`sts:GetCallerIdentity`). Confirm the
   assumed role is `${prefix}-authenticated`. Cheapest possible check that the
   identity pool and the role attachment are wired.
6. **The test that matters most:** with those credentials, attempt a PUT to
   `users/<some-other-uuid>/snapshot.sqlite.gz`. It must 403. Then PUT to the
   caller's own `sub` prefix — it must succeed. One passing and one failing, in
   that order, is what proves the principal tag is populated and the policy
   variable resolved; a policy where the tag came out empty tends to deny
   *everything*, which looks identical to a working deny if you only test the
   negative case.
7. PUT a real gzipped snapshot exported from the app, with
   `x-amz-checksum-sha256` set. S3 verifies the body against it — that property
   survives the redesign intact, and it's what makes a corrupted upload
   impossible rather than detectable afterwards. A 403 here rather than at step
   6 means the §3.4 KMS grants.
8. Read the `snapshotMeta` item and confirm `schemaVersion` and `rowCounts`
   match what `SnapshotExporter` reported for that same file — **and that they
   were derived, not copied.** Prove it by uploading again with a deliberately
   wrong `x-amz-meta-schema-version`: the index must still record the true
   version out of `grdb_migrations`. That single check is the design's central
   claim, and it's the one that replaced a signature.
9. Upload a file that isn't a SQLite database at all. The index must record
   `readable = false` with a reason, and the function must not retry.
10. **Sign in with Apple end to end on the phone**, and confirm the `sub` it
   yields is what the S3 prefix uses. This is the step that catches a Services
   ID whose Return URL doesn't match the Cognito domain, which fails at Apple's
   end with an error that says nothing useful about why.
11. Re-upload twice with `If-Match` set to a stale etag. The second must 412.
   That's §8's single-writer signal, and it's worth confirming against real S3
   once before any app code is built on it.

---

## 12. Deployed

Applied 2026-08-24, account `292826404083`, `us-west-2`. Neither global
namespace collided, so §3.2's Services ID Return URL stands as written.

| | |
| --- | --- |
| user pool | `us-west-2_IdjBHNPTi` |
| app client | `7b21re969qgped3sfqtit9e5c7` |
| identity pool | `us-west-2:4ceed955-559e-4395-9537-9672249ceeb6` |
| authenticated role | `arn:aws:iam::292826404083:role/lift-coach-prod-authenticated` |
| bucket | `lift-coach-prod-snapshots` |
| KMS key | `…:key/6a920cd3-4fc8-414b-b681-955278c28c28` |
| meta table | `lift-coach-prod-snapshot-meta` |
| Lambda | `lift-coach-prod-index-snapshot` |
| deploy role | `arn:aws:iam::292826404083:role/github-actions-lift-coach` |

None of these are secrets — every one of them ships inside the app's Amplify
configuration and is readable by anyone holding the binary. Access is the
identity pool's job, not the obscurity of an id.

**§11 step 6 is closed, verified at runtime rather than by reading the policy.**
The plan could not prove it — `aws_iam_role_policy` renders as
`(known after apply)` because it interpolates the bucket ARN — so it was tested
against the live account:

| | |
| --- | --- |
| `sts:GetCallerIdentity` as the phone | `assumed-role/lift-coach-prod-authenticated` |
| PUT to another user's prefix | 403 `AccessDenied` |
| PUT to own `sub` prefix | succeeded, SSE-KMS under the right key |
| GET own object back | succeeded — the restore path works |
| `s3:ListBucket` / `s3:DeleteObject` | `AccessDenied`, both absent as designed |

**The identifier trap in §3.3 is closed**, and the two values differ
concretely: the token `sub` was `58a1f320-…` while the identity pool's own
identity id was `us-west-2:442dd054-…`, and the object landed under the former.
That is the check no amount of reading the HCL could have substituted for.

**Step 11 is closed too** — it needed no app code. `If-None-Match: *` on an
existing object returns 412; `If-Match` with the current etag succeeds; `If-Match`
with a stale etag returns 412 `PreconditionFailed`. §8's single-writer signal is
real S3 behaviour, confirmed before any client is built on it. The client half
is still open and is app work: whether Amplify's Storage plugin can send those
headers, or whether the PUT needs the AWS SDK for Swift's
`PutObjectInput.ifMatch` directly.

**Steps 7–10 wait on the Lambda deploy.** Until the function's code is uploaded
it is a placeholder that fails at import, so an upload triggers three retried
import errors and nothing reaches the table — which is itself an incidental
confirmation of D6's reasoning about what a raising handler costs.
