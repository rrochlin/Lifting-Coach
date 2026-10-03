# Roadmap

## Phase 1 — Local-first Tracker
Goal: verify the core premise — a device-local workout tracking app — before investing in server/AI functionality.

- Scaffold the mobile UI, starting with [[Workout Tracker]] since it's fundamentally a device-local feature and can be built independent of the backend
- Local application layer backed by SQLite (see [[Backend/Overview]]'s Local App Backend section) — the core tracking loop should not depend on the server
- Workouts are programmed statically (manually authored/entered plans) — no AI-generated plans, no live adjustment yet
- Build clear stubs in the app for where backend communication will eventually land (auth, sync, AI chat) — inject and accept input at those seams now, even though nothing is wired up behind them yet
- AWS work in phase 1 is bare-bones scaffolding only where actually needed to support the above — not the full buildout in [[Backend/Overview]]

**Explicitly deferred, not phase 1:**
- [[Coach Conversation]] and any AI-assisted plan generation/adjustment
- The web-UI question for [[Workout Planner]] (and the S3/CloudFront decision it drives — see [[Backend/Overview]] Open Questions)
- Full Cognito/DynamoDB/Bedrock/websocket buildout
- **Spreadsheet/xlsx import as an app feature.** The owner's program got in by being hand-translated once into the app's own language (`Resources/Block1.json`); `ProgramLoader` just loads that file and does no interpreting. There is deliberately no parser and no name matching — see Concepts.md's "Programs name exercises, they don't describe them." If real program import ever becomes a feature, it's that same documented JSON schema, or the phase 2 AI coach interviewing the lifter.

## Phase 2 — Server + AI
Once phase 1 validates the tracker itself. Designed in [[Backend/Overview]]; the resource-level spec is `server/INFRA-SPEC.md`. Three sub-phases, in order:

**2.1 — Cloud data storage. Built and on TestFlight.** Sign-in, a per-user SQLite snapshot uploaded to S3, an index the server derives by opening the file, and in-app account deletion. The phone stays the system of record and remains the only writer; it uploads directly with Cognito identity-pool credentials scoped to its own prefix, so there is no API in front of the bucket. Backup and restore fall out of a versioned bucket rather than being built, and "one phone at a time" is S3 conditional writes rather than a device lease. What this buys is the thing 2.3 needs: a Lambda that can run SQL over five years of training history.

- **Sign-in is required, and it is Sign in with Apple — natively, and nothing else** (owner's call, 2026-10-02; INFRA-SPEC §3.5). Apple's own button and the system sheet with Face ID, never a browser. No email or password sign-in: on an iPhone-only app everyone has an Apple ID, and offering both made two accounts out of one person. It replaced a Cognito Hosted UI that read as leaving the app, and it's also what lets account deletion revoke the app's Apple grant, which Apple requires.
- **Signing in is the front door, but never a gate on logging.** Required once on a fresh install; after that, a lapsed session (30 days) asks again and never blocks — a basement gym with no signal still logs the set.
- **Deleting an account deletes it** — every snapshot version, the index, the Cognito user, and the Apple grant — after a fresh Apple confirmation. The phone's own log stays.
- Still to do for 2.1: retire the Hosted UI resources (§3.5 step B); App Privacy questionnaire and privacy policy URL in App Store Connect before external testers.

**2.2 — AI chat.** API Gateway websocket → Lambda → Bedrock, conversation history in DynamoDB, read-only against the snapshot. [[Coach Conversation]] wants the chat aware of what the lifter is currently looking at, so screen context rides on the message.

**2.3 — Agentic coach.** Named query tools over the snapshot, and plan authoring that emits a **draft** program in `Block1.json`'s language. The lifter reviews a diff and accepts; `ProgramLoader` then creates a new block on the device. Completed blocks are never touched, and the coach never writes the lifter's database — see [[Core Tenets]] §1 and §8, which this mechanism is what makes structural.

Also in phase 2, and not optional: the privacy manifest changes the moment a training log leaves the phone (done in 2.1 — the encryption declaration, it turned out, does not: TLS is exempt), and an account needs an in-app deletion path (done, with Apple token revocation).

**Still open:** the web-UI question for [[Workout Planner]] and the S3/CloudFront decision it drives. The Lambda language (Python) and the DynamoDB key-type question are settled — see [[Backend/Overview]].
