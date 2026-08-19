# Overview
The backend splits into two pieces: a local mobile backend on-device, and an AWS-hosted server backend. Per [[Roadmap]], phase 1 is the local piece only. The server piece below is phase 2, now designed but not yet built.

## Local App Backend
- SQLite stores all application data for a user on-device (workouts, plans, profile)
- Schema should reflect and stay compatible with the data types defined in [[Concepts]]
- HealthKit sync is bidirectional: completed workouts are written out to Apple Health; metrics like heart rate, steps, and HRV are read in from it (per [[Design]]'s HealthKit list)
- No explicit iCloud sync planned. This was once floated as a low-friction backup (an iCloud ubiquity container holding the SQLite file), and the phase 2 snapshot below supersedes it: the same file goes to S3 for reasons iCloud couldn't serve anyway, since the point is that a Lambda can query it. Keeping only one copy off-device avoids two backups that can disagree.

## Server Backend

**The phone stays the system of record. The server gets a read-only copy, and writes back only proposals.**

That one sentence decides most of what follows, so the reasoning is worth having in full.

### The shape: a snapshot the phone writes and everything else reads

Each user's on-device SQLite database is exported as a snapshot and uploaded to S3, one object per user, keyed by their Cognito `sub`. Lambdas read it. Nothing but the phone ever writes it.

```
  phone (system of record, SQLite)
     │  VACUUM INTO → gzip → presigned PUT
     ▼
  s3://…/users/{cognitoSub}/snapshot.sqlite.gz     ← versioned bucket, SSE-KMS
     │  read-only
     ▼
  Lambda (Python)  ── query tools ──►  Bedrock  ◄── WS ── phone
     │
     └─ emits draft program JSON → DynamoDB draftPlans
                                        │
                        phone pulls, previews diff, accepts
                                        │
                            ProgramLoader → new block, locally
```

**Why SQLite and not a DynamoDB-modeled domain.** The data is one small relational graph per user. Measured at real scale — 873 catalog rows, 840 workouts, 13,440 sets, the shape of the owner's actual imported log — the snapshot is **3.86 MB on disk and 1.21 MB gzipped**, of which the shared catalog is 0.94 MB plain and 0.18 MB compressed. Exporting it (`VACUUM INTO` + gzip + describe) takes **95 ms** on a Mac. Those numbers are the ones the rest of this design leans on, and they are an order of magnitude smaller than the "roughly 10 MB" first written here from estimate rather than measurement; sets logged in-app carry a `plannedFrom` JSON snapshot that imported sets don't, so expect the real figure to drift upward, but not by a factor that changes any decision below. That graph already exists, migrated and covered by tests, and `ExerciseStatsStore`'s own measurement says the entire five-year log answers a query in 2.9 ms. Re-expressing it as DynamoDB items would mean two implementations of the same invariants, maintained in step forever — the cost already visible in the one place it happens today, where `AchievedMaxUpdate.swift`'s rule had to be duplicated into `scripts/src/liftimport/maxes.py`. An agent reasoning about training history wants joins and aggregates, which is the thing SQL is for and the thing a key-value store makes you rebuild by hand.

**Why there is no edit mutex, and why one was considered.** The tempting next step is to let agents mutate the S3 database directly under a lock on the object. S3 does support compare-and-swap now (conditional `PutObject` on an ETag), so it is buildable. It is still wrong: a lock over a whole-file blob serializes writers but cannot *merge* them. A phone that logged a session in a basement gym and uploaded afterwards would either clobber a plan the coach edited meanwhile, or be clobbered by it — and no retry policy fixes that, because the retry means re-uploading an entire database against a file that moved.

The mutex disappears once the coach stops writing. AI edits land in a **draft plan** the lifter accepts; completed blocks are never touched. So there is exactly one writer of a user's data, permanently, and nothing to lock.

This also makes two Core Tenets structural rather than conventional. §8 ("an AI coach must be structurally incapable of touching the log") holds because the coach has no write path at all, not because every Lambda is careful. §1 ("the app never changes a prescription on the lifter's behalf") *is* the draft/accept handoff.

**The write path already exists.** `ProgramLoader.load(_:for:startDate:)` takes arbitrary program JSON in the app's own language, resolves exercises by catalog slug, and throws on a slug the catalog doesn't have rather than silently dropping a day. A coach-authored draft is a `Block1.json`-shaped file going through that same loader. Nothing new has to be trusted with the lifter's data.

### Components

- **Cognito** (via the Swift Amplify package) handles auth, including Sign in with Apple. It replaces the *identity* `UserStore.localUser()` invents today, not the storage.
- **API Gateway** is the entry point: sign-in, presigned snapshot upload/download, and the chat websocket.
- **S3** holds the per-user snapshot. Bucket versioning is on, which makes point-in-time restore a property of the design rather than a feature to build.
- **DynamoDB holds metadata, never the domain**: `wsConnections` (TTL'd), `deviceLease`, `conversations`, `draftPlans`, `snapshotMeta` (etag, schema version, uploaded-at, row counts).
- **Lambda** runs the chat handler and the agent's query tools, reading the snapshot from `/tmp` (cached across warm invocations by ETag).
- **Bedrock** serves the chat, invoked from the chat Lambda.

### Rules that fall out of it

- **Upload on workout finish and plan save, and on backgrounding only if something changed** — never per set. The tracker saves after every mutation *locally* so an OS kill mid-session is recoverable; the cloud copy does not need that resolution. An unqualified "on background" trigger was written here first and is wrong: backgrounding happens dozens of times a day, and it would re-upload identical bytes every time.
- **"Changed" is an exact question, not a guess.** The gzip is deterministic — no mtime in the header — so the same database compresses to the same bytes and therefore the same SHA-256. Keep the last uploaded digest; export, compare, and skip the PUT if it matches. The export is ~95 ms and local; the upload is a megabyte over cellular, so spending the first to avoid the second is the right way round.
- **At six sessions a week that's ~26 uploads a month, ~30 MB.** Fine. What isn't automatic is the bucket: versioning is what makes point-in-time restore free, and it also means every one of those uploads is retained forever unless a lifecycle policy expires noncurrent versions. Set one when the bucket is created, not after the bill.
- **Export with `VACUUM INTO`, never the live file.** A live SQLite database has a WAL sidecar and possibly in-flight transactions; `VACUUM INTO` produces a consistent, compacted, single-file snapshot.
- **The schema gate is a floor and a marker, not a set of known versions.** This was first written here as "the server refuses a snapshot whose schema version it doesn't know," by analogy with `liftimport` refusing a database predating `v13`. Implementing it showed the analogy doesn't hold. `liftimport` **writes**, so an old schema means inserting into columns that don't exist — a refusal there prevents corruption. This **stores**, and a snapshot from a *newer* app is the ordinary consequence of a TestFlight build landing before a Lambda deploy. Refusing it would 409 every upload, silently accumulating unbacked-up training, until somebody redeployed — a self-inflicted outage protecting nothing, since at 2.1 nothing reads the file at all. So: refuse below the floor, accept at or above it, and mark a snapshot that's newer than the deploy understands. The marker is what makes drift loud where it can hurt — 2.3's query tools consult it and decline rather than answer a question about a table that moved under them. A declined answer is Tenet 10; a confidently wrong training number is not.
- **The floor is `v14_cognitoSub`, and it's a fact rather than a policy.** A build without that migration has nowhere to record which account it belongs to, so it cannot sign in, so it cannot obtain a URL to upload with. Stating the floor just means a hand-crafted request gets a sentence instead of a stack trace.
- **Restore is the one destructive operation.** Sign-in on a fresh install only, and it must refuse a local database holding workouts the snapshot lacks (Tenet 8).
- **The snapshot is stale by construction.** Upload-if-dirty on entering chat, and the coach's answers say what they're as of — Tenet 10, honest empty states.
- **Multiple sessions are refused, not reconciled.** A `deviceLease` item in DynamoDB, taken by conditional put at sign-in. Signing in elsewhere takes the lease and the old device's next upload is refused with a 409. This is the only lock in the design and it guards sign-in, not an object.
- **The agent gets named, parameterized query tools** — `history(exercise, since)`, `maxes()`, `adherence(block)`, `volume(muscleGroup, weeks)` — not raw SQL. Auditable, testable, and answering in the app's own language. Any raw-SQL escape hatch opens the file `mode=ro` with `query_only` set.

### Built so far

The device half of 2.1, in `LiftingCoachPersistence` — no AWS involved, and all of it testable with `swift test`.

- **`SnapshotExporter`** makes the file. `VACUUM INTO` a temp path, gzip, SHA-256, and a stamp of the last applied migration plus a row count per table. The description is read back out of the *exported* file rather than off the live database, so the stamp always describes the bytes being uploaded. The uncompressed intermediate is deleted before the call returns — it's an unencrypted copy of a training log.
- **`Gzip`** is a real gzip container, not Apple's raw DEFLATE. The reader is a Python Lambda, so `gzip.open` and `gunzip` both have to work on it; a test round-trips through the actual `gunzip` binary rather than through our own decoder. The header carries no mtime, so the same database compresses to the same bytes twice and an S3 ETag means what it looks like it means. Both directions stream in 64 KB windows.
- **`SnapshotImporter`** is the restore, and the one destructive operation in the design. It refuses a snapshot from a newer build (migrations only run forwards), refuses a truncated download (the gzip trailer is verified — a truncated snapshot inflates into a *valid* shorter SQLite file, which is the failure worth catching), and refuses to install over a database holding workouts the snapshot lacks. That last check runs inside `install`, not as advice to the caller, because Tenet 8 shouldn't depend on someone remembering to ask.
- **An unreadable local database is a decision, not a default.** A file that won't open holds an unknown number of sessions, and unknown is not none — so it's refused, with an explicit `replacingUnreadableDatabase` for the lifter to take deliberately. That override covers *only* that case; a readable database with unbacked-up sessions is refused regardless.
- **`BackendClient`'s shape follows** — `uploadSnapshot` / `latestSnapshot` / `downloadSnapshot` / `fetchDrafts` / `resolveDraft`. The old `push(_ workouts:)` / `pullChanges(since:)` pair is gone: it was written against row sync, which this design rejects.

- **`SnapshotSync` decides when a snapshot goes up**, and it exists because both obvious policies are wrong: uploading on every write means gzipping a megabyte after every logged set, and uploading on a timer leaves the one thing worth having in the cloud — the session that just ended — sitting on the phone. Two filters, cheap one first.
  - **A flag, set by the triggers that actually change something.** Backgrounding happens dozens of times a day and must not cost an export each time.
  - **Then the digest**, which catches what a flag can't: a workout started and discarded, a plan opened and saved untouched. Both report a change and both leave the database exactly as it was. This is what the deterministic gzip header was for — identical data really does produce identical bytes, so the comparison is exact rather than a heuristic.
  - **The first sync for an account always uploads**, flag or no flag. Signing in on a phone that already holds five years of training is precisely the case where nothing has "changed" and everything needs to go up.
  - **Nothing retries.** A failure leaves the watermark alone, so the next ordinary trigger *is* the retry — one code path rather than a second one written to recover from the first.
  - Being an actor is the whole of the coalescing story: two triggers firing together run one after the other, and the second finds a fresh watermark.
- **The watermark lives in `UserDefaults`, never in the database.** It describes the file, so storing it inside the file would change the thing it describes: every upload would dirty the database, produce a new digest, and warrant another upload, forever. It's keyed by account so signing in as somebody else can't inherit a claim that their log is already in the bucket, and losing it costs exactly one redundant upload.
- **Triggers**: a workout ending (finished *or* discarded — the tracker writes every mutation to disk as it happens, so an abandoned session is real rows until it isn't), a plan save, a history edit or delete, a change to the lifter, and backgrounding. The planner's hook hangs off `PlannerModel.persist`, the one choke point all four of its write paths already go through, so a fifth can't be added without one.
- **Backgrounding is the safety net, not the main trigger.** The screens that change something say so as it happens; backgrounding catches the path nobody hooked, and it's free when nothing has changed.
- **`v14_cognitoSub`** binds this database to an account. Nullable — every row that exists today has never signed in — and unique, because it's an identity claim like `exercise.sourceSlug`. Deliberately absent from the `User` domain struct and from `UserStore`'s `UserRow`: the binding is a property of this database's relationship to an account, not of the lifter, and keeping it out of the row that `save(_:)` writes means saving a user can never sign the phone out. A test pins that.
  - **Binding a second account is refused.** The local database is the first account's training log; adopting it under a second identity would upload one person's sessions into another person's snapshot. The resolution is the destructive one — `SnapshotImporter` replaces the whole file, and the binding arrives with the snapshot.
  - **Nothing unbinds.** Signing out leaves the note in place: cleared, the next sign-in as somebody else would find an unbound database and silently take over the log this refusal exists to protect.
- **The account for an upload comes from the live session, not from the binding.** A snapshot is filed under the identity authorised to PUT it, and an expired session can't upload however firmly the `user` row says whose log this is.

**The whole mechanism costs nothing until there's an account** — `SnapshotSync` checks for one before it exports anything, so in phase 1 every trigger is a no-op that allocates a task and returns.

**A maintained flag rots, and this one is no exception.** It's the same failure shape `ExerciseStatsStore` is rebuild-only to avoid: a write path added without a `snapshotDidChange` call is invisible until someone notices the cloud copy is stale. Two mitigations were considered and rejected for now. Marking changed on every backgrounding removes the flag's whole point. Deriving the flag from `sqlite3_total_changes` would be automatic and correct, and is what to reach for if the flag does start missing paths — but see the next paragraph for why it currently costs an upload per launch.

**Known wart: rebuilding `exerciseStats` changes the exported bytes.** Measured — two rebuilds over identical data produce two different digests at an identical byte count, because the table's `autoIncrementedPrimaryKey` hands out fresh rowids each time and `sqlite_sequence` keeps climbing. Since `AppEnvironment.bootstrap` rebuilds on every launch, **the digest filter cannot suppress the first upload after a launch**, even when nothing real changed. The flag still does its job (a quiet backgrounding costs nothing), so the practical cost is one needless 1.2 MB upload in a narrow case: launch, then save a plan without actually editing it. Left alone as proportionate rather than fixed, but the fix is identified — give `exerciseStats` its natural key instead of an autoincrement rowid, so a rebuild over the same log is byte-identical. Resetting `sqlite_sequence` inside `rebuild` is *not* the fix: it deletes only one user's rows, so restarting the counter would collide with another user's.

**The server side of 2.1 is built, in `server/`** — Python, standard library plus the `boto3` every Lambda runtime already provides, and `cd server && uv run pytest` needs no AWS account.

- **Three refusals, in a deliberate order.** `POST /snapshot/upload-url` checks the lease, then judges the schema, and only then mints a URL — so neither refusal ever costs an upload. Being told "you're signed in on your other phone" after sending a megabyte over cellular is the wrong end of the transaction. The lease goes first because it's the refusal that protects *data* rather than correctness.
- **The description is signed into the URL, so the phone cannot lie about it.** Schema version, digest, row counts and device id are baked into the signature as `x-amz-meta-*`; S3 rejects a PUT whose headers don't match. That's the same property `SnapshotExporter` gets by reading its stamp out of the exported file rather than off the live database — the account of the bytes travels welded to the bytes.
  - **This was nearly false.** boto3's default presigner emits a **SigV2** URL in older regions, which carries metadata as *query parameters* rather than signed headers — measured, not assumed. Under it a phone could PUT the right bytes under any schema version it liked. `S3Objects` pins `s3v4`, and `tests/test_presigning.py` asserts against real botocore that every header the response tells the phone to send is covered by the signature. It's the one test in the suite that doesn't use a fake, because the claim isn't a decision this code makes — it's a property of what botocore emits, and a fake asserting it would only assert that the fake agrees with the docstring.
- **The digest is enforced, not recorded.** The presign carries `x-amz-checksum-sha256`, so S3 hashes the body it receives and refuses a mismatch. A corrupted upload becomes impossible rather than detectable-later.
- **The phone replays whole headers and builds none.** The response names the exact set. Every encoding rule — hex digest to base64, the metadata prefix — stays server-side, so the phone can't get one subtly wrong.
- **There is no commit call.** `snapshotMeta` is written by an S3 `ObjectCreated` event reading the object's own metadata. A phone that dies between the PUT and a report is ordinary on a cellular link, and a design where that leaves the index disagreeing with the bucket is a design that needs a reconciler. Here the object *is* the trigger, so there's nothing to reconcile.
- **The lease's asymmetry is the design.** Claiming is unconditional — signing in on a phone *is* the decision, and making the lifter resolve a conflict first asks them to answer what they just answered. Requiring is a read, done at URL issue. **Releasing is conditional on holding**, and that's the one place a conditional write earns its keep: without it, signing out on a handset that lost the lease hours ago would clear the lease belonging to the phone somebody is currently using. No TTL, deliberately — a lost phone doesn't strand an account, because the next sign-in anywhere takes the lease outright, and an expiring lease would open a window where two devices both believe they hold it.
- **The subject comes from the validated token, never from a request body.** It builds the S3 prefix, so a handler accepting a caller-supplied `sub` would let any signed-in account write into any other's snapshot. One function every route goes through — the one place in the package where a mistake is a breach rather than a bug.
- **Every AWS surface sits behind a narrow protocol** with an in-memory implementation, the same split as `SnapshotWatermarkStore` on the device. Nothing in the suite mocks boto3.
- **Two copies of Swift-owned facts, both pinned by tests rather than by comments** — the migration list against `Migrations.swift`, and the error codes against `BackendError`. That's the `maxes.py` lesson applied properly: a comment asking two files to stay in step doesn't keep them in step, and a test that reads the real file fails in the repo where both live rather than after a deploy.

Not yet done in 2.1: Cognito itself, and `server/infra/`.

### Deliberately not built

- **Sync as conflict resolution.** Row-level merging, vector clocks, CRDTs, last-writer-wins — all of it becomes necessary only with a second writer of the *log*, and there isn't one: only the lifter lifts. A web planner would make the *plan* multi-writer, which the draft mechanism already covers.
- **Stripping the shared catalog out of each snapshot.** Measured, it is 0.18 MB of a 1.21 MB upload — 15%, in exchange for the file no longer being self-contained for the agent's joins. A knob to turn if storage ever matters, which at this scale it does not.

### Deferred, not rejected: changed-row sync

The obvious efficiency objection to the snapshot model: the phone re-uploads a whole database every time, and the upload grows with the length of a training career, even though a finished workout only changed about twenty rows. The alternative is to buffer changes on-device and flush them to a Lambda that applies them to the server's copy. This was considered properly and deferred, with the reasoning here so it doesn't have to be re-derived.

**Build the upsert form, not an operation log.** The tempting shape is a log of operations replayed in order, which needs sequence numbers, server-side dedup, and exactly-once delivery. The better shape is *changed-row upserts*: record which rows changed, read them at commit, ship them as upserts. That is idempotent by construction and order-insensitive within a batch, so a retried flush after a timeout that actually succeeded is simply harmless. If this is ever built, it is built that way.

**GRDB gives you half of what's needed.** `TransactionObserver` reports which rows changed (table, rowid, insert/update/delete) unconditionally. The row *values* need `SQLITE_ENABLE_PREUPDATE_HOOK`, which the standard SPM build against system SQLite doesn't set — so the collection step is "observe rowids, then re-read them," not "capture the change." That's fine, and it's the automatic path; the tempting alternative of hand-appending to a log at each mutation site is the one that rots, for exactly the reason `ExerciseStatsStore` is rebuild-only.

**What it would buy:**
- Upload proportional to *changes* rather than to career length. Snapshot upload grows about 0.2 MB compressed per year of training; changed-row sync stays at single-digit KB per workout forever.
- A server copy that is current rather than as-of-last-upload, which removes the coach's "as of" caveat.
- Flushes cheap enough to run mid-workout, so cloud-side recovery becomes possible.
- A change history the coach could use directly, and far better economics if this ever stops being a personal app.

**What it would cost:**
- **It makes the server a writer**, which is the property everything else here rests on. Today the coach cannot touch the log because no server-side write path exists; a replay Lambda creates one. It is supposed to be fed only by the phone, but the mechanism exists, so [[Core Tenets]] §8 goes back to being a rule someone enforces rather than a shape that cannot express the violation.
- **It doesn't replace the snapshot, it sits on top of it.** Integrity verification, the "true up" repair when the copies disagree, and syncing into a freshly signed-in empty account are all the snapshot path — `SnapshotExporter` and `SnapshotImporter` are needed either way. This is an optimization with a floor, not a substitute.
- **Something other than the app writes the schema.** The Lambda applying upserts has to know table shapes and migration state, or carry enough metadata to be schema-blind. That is the same "two implementations of the same invariants" cost that ruled out modeling the domain in DynamoDB, arriving by a different door.
- **Integrity checking is real work.** The phone's file and a replayed copy are never byte-identical — different page layout, different `VACUUM` state — so the check has to be logical: per-table counts plus a content hash over a canonical ordering, defined once and kept correct as the schema grows. Both failure directions cost something: a false positive forces a needless full upload, a false negative means silent drift.

**Why it's deferred.** Price the growth argument, since it's the strongest one: about 0.2 MB of compressed snapshot per year of training. Twenty years of lifting is a ~5 MB upload, twenty-six times a month, ~130 MB/month. The point where the snapshot model actually hurts does not arrive within this app's plausible life. **Revisit when** either the coach needs mid-workout freshness that message context can't supply — sending the last few sets on the chat message is far cheaper than continuous replication — or the user count makes per-upload bandwidth a line item.

**One thing the snapshot model does give up**, and it should be accepted knowingly rather than discovered: recovery granularity is the last upload, so a phone lost between workouts loses whatever wasn't uploaded. That is the argument for uploading on workout *finish* specifically, rather than on a timer.

## Infrastructure Pattern
Following the pattern from `An-Amazing-Adventure` / `terraform-infrastructure` (see that repo's `ONBOARDING.md`):
- `terraform-infrastructure` owns AWS *resource* definitions only (Cognito, DynamoDB, API Gateway, Lambda resources, etc.) — it never builds or deploys application code
- The app repo's infra directory (convention: `server/infra/`) and this app's top-level directory in `terraform-infrastructure` are kept in sync via `git subtree` — not a submodule, not CI-linked. Whoever edits one side is responsible for pushing/pulling the other **in the same PR cycle**. `An-Amazing-Adventure` already drifted once from batching infra edits before syncing — don't repeat that
- Lambda resources use a placeholder-archive + `lifecycle { ignore_changes = [filename, source_code_hash] }` pattern so `terraform apply` doesn't stomp on code deployed separately by the app's own CI (`aws lambda update-function-code`)
- Reference modules to build from: `dynamodb`, `cognito`, `s3`, `lambdas`, `api-gateway`, `cloudfront` (the last two only apply if we end up needing a web component — see open question below)

### Onboarding steps (from `ONBOARDING.md`, adapted for this app)
1. New top-level directory in `terraform-infrastructure` (e.g. `workout-app/`), own `main.tf`/`variables.tf`/`outputs.tf`/`modules/`
2. Own S3 backend state key: `workout-app/terraform.tfstate` (same bucket/lock table as `amazing-adventure`, isolated key)
3. Define this app's GitHub OIDC deploy role in Terraform using the shared `modules/github-oidc` module — it looks up the existing account-level OIDC provider rather than creating one, and takes an explicit `allowed_subject_patterns` (e.g. restricted to `refs/heads/main`) plus a `policy_json` scoped to whatever the app's deploy CI actually needs (`lambda:UpdateFunctionCode`, `s3:PutObject`, etc.)
4. Add `workout-app` to the `matrix.app` list in `terraform-infrastructure/.github/workflows/terraform.yml` — CI now runs an explicit static matrix rather than a hardcoded single directory, so a new app must be added to that list in the same PR that adds its directory. Don't assume it's "live" just because `terraform validate` passes locally — confirm it's in the matrix
5. `git subtree add --prefix server/infra ...` from this repo to link it, and document the sync workflow in this repo's own `CLAUDE.md` once that exists

## Settled Questions
Both were open through phase 1 and are answered by the snapshot/draft design above:

- **Lambda implementation language — Python.** `scripts/` already describes itself as "the seed of the Lambda-side layout": stdlib-only, three-stage, and holding `liftimport/maxes.py`, which is a duplicate of `AchievedMaxUpdate.swift`'s rule waiting for one home. Reading a SQLite snapshot is `sqlite3` out of the standard library.
- **DynamoDB key types — moot.** `terraform-infrastructure/CLAUDE.md` warns that `amazing-adventure`'s Binary-type UUID keys exist to match Golang's binary UUID format, and that the language decision has to precede the schema. It doesn't bind here: DynamoDB holds only metadata, keyed by the Cognito `sub`, which is a string.

## Open Questions
- **S3 / CloudFront for a web component** — `amazing-adventure` uses these for a web-hosted UI, and Ideas.md floated a web planner ("doing this on mobile isn't great... a web UI might actually be the best thing"). Still undecided. The snapshot design does anticipate the shape it would take: a web planner is a second writer of the *plan*, which is what the draft/accept mechanism already handles. It is not a second writer of the log, and must never become one.
- **What a draft that revises a *running* block means.** Accepting a draft creates a new block, and completed blocks are never touched. A draft revising a block currently underway should name the week it takes effect from, so weeks already lifted stay as they were. That model isn't written yet.

## Superseded
`notes/FitnessAppNetworkDiagram.drawio` shows DynamoDB tables `users`, `workouts`, `conversations`, `plans`, `ws-connections`. **`workouts` and `plans` are the two this design rejects** — the domain lives in the S3 snapshot, and DynamoDB holds `wsConnections`, `deviceLease`, `conversations`, `draftPlans`, and `snapshotMeta`. The diagram needs redrawing; until it is, this document is the authority on table naming.
