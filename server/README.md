# server

The server half of Lifting Coach. **It reads the phone's snapshot and never
writes it.**

That sentence is the design, not a policy this code follows. The phone is the
system of record; S3 holds one gzipped SQLite snapshot per user that the phone
uploads and everything else reads; the coach's only output is a draft program
the lifter accepts, which `ProgramLoader` turns into a block *on the device*.
There is exactly one writer of a training log, permanently, which is why there
is no merge logic here and nothing to lock. See
`notes/Workout App/Backend/Overview.md` for the full reasoning and Core Tenets
§1 and §8 for why it matters.

Phase 2.1 — what's here — is storage: who may upload, where it goes, and what
the server knows about it afterwards. The chat (2.2) and the agent's query
tools (2.3) land beside it later.

## Running it

```sh
cd server && uv sync && uv run pytest
```

Python 3.11+, standard library only. `boto3` is a dev dependency rather than a
runtime one because every Lambda runtime already provides it — vendoring a copy
of what the platform ships would be shipping a second copy to keep updated.

## Layout

| module | what it holds |
| --- | --- |
| `errors.py` | The refusals, and the codes the app switches on. |
| `schema.py` | Which schema versions a snapshot may be written at. |
| `lease.py` | One device at a time, per account. |
| `snapshots.py` | Object keys, signed metadata, the `snapshotMeta` record. |
| `handlers.py` | The Lambda entry points, and as little else as possible. |
| `aws.py` | The one module that knows AWS exists. |

**Every AWS surface is behind a narrow protocol** — `SnapshotObjects`,
`LeaseStore`, `MetaStore` — with an in-memory implementation for tests. That's
the same split as `SnapshotWatermarkStore` on the device side, and for the same
reason: the policy is what wants testing, and it can't be tested through a
client whose conditional writes are opaque objects. Nothing in this suite mocks
boto3.

The exception is `tests/test_presigning.py`, which uses real botocore on
purpose. "The metadata is signed, so the phone cannot lie about it" is not a
decision this code makes — it's a property of what botocore emits, and a fake
asserting it would only assert that the fake agrees with the docstring. It
earned its place on the first run: boto3's default presigner produced a
**SigV2** URL, which carries metadata as query parameters rather than signed
headers, and under it a phone could have PUT the right bytes under any schema
version it liked. `S3Objects` pins `s3v4`.

## The upload, end to end

1. `POST /snapshot/upload-url` with the device id, the schema version, the
   digest and the row counts. The lease is checked first, the schema second,
   and only then does a URL exist — **so neither refusal ever costs an
   upload.** Being told "you're signed in on your other phone" after sending a
   megabyte over cellular is the wrong end of the transaction.
2. The response names the **exact headers** to send. The phone replays them
   verbatim; it never builds one. All the signing knowledge — the base64
   checksum encoding, the metadata prefix — stays server-side, so the phone
   can't get it subtly wrong.
3. The phone PUTs. S3 verifies `x-amz-checksum-sha256` against the body it
   received, so a corrupted upload is impossible rather than
   detectable-afterwards, and rejects any header that doesn't match what was
   signed.
4. `ObjectCreated` fires `index_snapshot`, which reads the object's own
   metadata and writes `snapshotMeta`. **There is no commit call.** A phone
   that dies between the PUT and a report is ordinary on a cellular link, and a
   design where that leaves the index disagreeing with the bucket is a design
   that needs a reconciler. Here the object *is* the trigger.

## Two rules worth reading before changing anything

**The subject comes from the validated token, never from a request body.** It
builds the S3 prefix, so a handler that accepted a caller-supplied `sub` would
let any signed-in account write into any other's snapshot. It's one function
(`handlers.subject_of`) that every route goes through, and it's the one place
in this package where a mistake is a breach rather than a bug.

**The schema gate is a floor and a marker, not a set of known versions.**
`Overview.md` first wrote it as "refuse a version the server doesn't know," by
analogy with `liftimport` refusing a database predating `v13`. The analogy
doesn't hold: `liftimport` *writes*, so an old schema means real corruption,
while this *stores*. A snapshot from a newer app is the ordinary consequence of
a TestFlight build landing before a Lambda deploy, and refusing it would stop
backups — silently accumulating unbacked-up training — until somebody
redeployed. So a newer version is stored and flagged `newer-than-server`, and
2.3's query tools consult the flag and decline to answer rather than answer a
question about a table that moved. A declined answer is Tenet 10; a
confidently wrong training number is not.

The floor is `v14_cognitoSub` and it's a fact rather than a rule: a build
without that migration has nowhere to record which account it belongs to, so it
can't sign in, so it can't get a URL.

## Two copies pinned by tests, not by comments

This package restates two things Swift owns, which is the shape that already
went wrong once here (`scripts/src/liftimport/maxes.py` duplicating
`AchievedMaxUpdate.swift`). Both are pinned to the real file rather than to a
comment asking the two to stay in step:

- `schema.KNOWN_MIGRATIONS` against `Migrations.swift` — a migration added to
  the app and not here fails in the repo where both live, rather than as a
  mystery refusal after a deploy.
- The error codes against `BackendError` in `BackendClient.swift` — renaming a
  case in Swift alone would leave the phone showing a generic failure for a
  refusal it has real words for, which reads as an outage rather than "you
  signed in on your other phone."

## Not built yet

- **Cognito itself.** These handlers read a `sub` off an authorizer's claims;
  nothing here issues or validates a token.
- **`server/infra/`** — the Terraform, via `git subtree` against
  `terraform-infrastructure`. Note the bucket needs a lifecycle rule expiring
  noncurrent versions from the day it's created: versioning is what makes
  point-in-time restore free, and it also retains every upload forever.
- **The chat and the query tools** (2.2, 2.3).
- **Account deletion.** App Review requires an in-app path once accounts exist:
  the S3 prefix and every DynamoDB item for that `sub`.
