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
Once phase 1 validates the tracker itself. Designed in [[Backend/Overview]]; the architecture is settled, the build is not started. Three sub-phases, in order:

**2.1 — Cloud data storage.** Cognito auth, a device lease so one account means one session, and a per-user SQLite snapshot uploaded to S3. The phone stays the system of record and remains the only writer. What this buys is the thing 2.3 needs: a Lambda that can run SQL over five years of training history. Backup and restore fall out of a versioned bucket rather than being built.

**2.2 — AI chat.** API Gateway websocket → Lambda → Bedrock, conversation history in DynamoDB, read-only against the snapshot. [[Coach Conversation]] wants the chat aware of what the lifter is currently looking at, so screen context rides on the message.

**2.3 — Agentic coach.** Named query tools over the snapshot, and plan authoring that emits a **draft** program in `Block1.json`'s language. The lifter reviews a diff and accepts; `ProgramLoader` then creates a new block on the device. Completed blocks are never touched, and the coach never writes the lifter's database — see [[Core Tenets]] §1 and §8, which this mechanism is what makes structural.

Also in phase 2, and not optional: the privacy manifest and encryption declaration both change the moment a training log leaves the phone, and an account needs an in-app deletion path.

**Still open:** the web-UI question for [[Workout Planner]] and the S3/CloudFront decision it drives. The Lambda language (Python) and the DynamoDB key-type question are settled — see [[Backend/Overview]].
