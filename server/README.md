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

Phase 2.1 — what's here — is storage: where the file goes and what the server
knows about it afterwards. The chat (2.2) and the agent's query tools (2.3)
land beside it later.

## Running it

```sh
cd server && uv sync && uv run pytest
```

Python 3.11+, standard library only. `boto3` is a dev dependency rather than a
runtime one because every Lambda runtime already provides it — vendoring a copy
of what the platform ships would be shipping a second copy to keep updated.
`sqlite3` and `gzip` being stdlib is what lets the indexer read a snapshot with
no build step at all.

## The shape

**The phone talks to S3 directly.** It signs its own PUT with temporary
credentials from a Cognito identity pool, whose role is scoped by a principal
tag carrying the user pool `sub` to exactly `users/${sub}/*`. There is no API in
front of the bucket, nothing mints a URL, and no code in this package
authorises a request — IAM does that, before any of this runs.

**One Lambda, on the way in.** `ObjectCreated` fires `index_snapshot`, which
downloads the object *at the version the event named*, opens it, and records
what it found. `INFRA-SPEC.md` is the full resource list.

```
phone ──(Cognito identity pool credentials)──► s3://…/users/{sub}/snapshot.sqlite.gz
                                                   │ ObjectCreated
                                                   ▼
                                        index_snapshot ──► snapshotMeta
```

## Layout

| module | what it holds |
| --- | --- |
| `errors.py` | The one distinction that matters: recorded vs. retried. |
| `schema.py` | Which migration a snapshot is at, and whether it's ahead of us. |
| `inspection.py` | Opening a snapshot and reporting what's in it. |
| `snapshots.py` | Object keys, and the `snapshotMeta` record. |
| `handlers.py` | The Lambda entry point, and as little else as possible. |
| `aws.py` | The one module that knows AWS exists. |

**Every AWS surface is behind a narrow protocol** — `SnapshotObjects`,
`MetaStore` — with an in-memory implementation for tests. Same split as
`SnapshotWatermarkStore` on the device side, and for the same reason: the policy
is what wants testing, and it can't be tested through a client whose behaviour
is opaque objects. Nothing in this suite mocks boto3.

What the suite does *not* fake is the snapshot. `conftest.build_snapshot` writes
a real gzipped SQLite database with a real `grdb_migrations` table, because
since the redesign "what the server knows" is defined as "what opening the file
says" — a test that stubbed the opening would assert nothing.

## Three rules worth reading before changing anything

**The record is derived from the object, never from the uploader.** The phone
writes its own `x-amz-meta-*` with its own credentials and no signature covers
them, so `schema_version`, `newer_than_server` and `row_counts` are all read out
of the file by `inspection.inspect`. Only `device-id` is copied from the
metadata, and it decides nothing — it exists so a log line can name a handset.
This is `ExerciseStatsStore`'s discipline applied to the bucket: a derived
record with one writer can be stale, but it cannot disagree with the thing it
describes, and rebuilding it is always a valid repair.

An earlier design got this property from a signature instead — a presigned PUT
with the schema version baked into SigV4, so S3 would reject a mismatched
header. That was real, and `tests/test_presigning.py` caught a genuine bug in it
(boto3 presigned **SigV2** by default, which carries metadata as query
parameters). It's gone, and reading the file is strictly stronger: a signature
proved the phone said the same thing twice; this proves what the bytes contain.

**Reads are pinned to a version id.** On a versioned bucket a bare read returns
whatever is current. Two uploads inside the same minute — a finished workout and
a plan save — would otherwise have the first event read the second object's
contents and file them under the first one's etag and size, producing a record
that is internally inconsistent with nothing to indicate it.

**Nothing here refuses a snapshot for its contents.** `schema.py` records a
version; it does not gate on one. Refusing a *newer* file would stop backups —
silently accumulating unbacked-up training — for as long as it took to redeploy,
which is a self-inflicted outage protecting nothing. A file that cannot be
*opened* is recorded as unreadable rather than retried; see `errors.py` for
where that boundary sits and why a transient failure is the one thing allowed to
escape.

## One copy pinned by a test, not by a comment

`schema.KNOWN_MIGRATIONS` restates `Migrations.swift`, which is the shape that
already went wrong once here (`scripts/src/liftimport/maxes.py` duplicating
`AchievedMaxUpdate.swift`). `tests/test_schema.py` parses the real Swift file
and fails when the two disagree.

It is load-bearing rather than documentary, and that's new: `grdb_migrations` is
an *unordered set* of identifiers, so "the last applied migration" only exists
relative to a registration order. `KNOWN_MIGRATIONS` **is** that order. Get it
wrong — sort it alphabetically, say, where `v9` follows `v14` — and every
snapshot is reported at the wrong version.

## Not built yet

- **Cognito itself.** `INFRA-SPEC.md` §3 specifies the user pool, the identity
  pool and the principal-tag mapping that makes the S3 prefix work. None of it
  is created, and nothing in this package touches auth.
- **`server/infra/`** — the Terraform, via `git subtree` against
  `terraform-infrastructure`. `INFRA-SPEC.md` is the spec for it.
- **The chat and the query tools** (2.2, 2.3).
- **Account deletion.** App Review requires an in-app path once accounts exist,
  and on a versioned bucket the obvious implementation deletes nothing — it
  writes a delete marker over versions that stay readable. `INFRA-SPEC.md` §9.4
  settles it: enumerate the versions and delete them, plus the `snapshotMeta`
  item and the Cognito user. §9.2–9.5 hold the rest of the compliance work the
  first cloud build can't ship without.
