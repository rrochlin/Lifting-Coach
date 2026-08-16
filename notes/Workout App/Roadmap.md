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
- **Spreadsheet/xlsx import as an app feature.** `ProgramImporter` is a one-off dev tool that pulled the owner's own program in as sample data — don't extend it, generalize it, or spend time keeping it in sync with the model as things change. If real program import ever becomes a feature, it's a documented JSON/CSV schema, or the phase 2 AI coach.

## Phase 2 — Server + AI (not scheduled)
Once phase 1 validates the tracker itself:
- Wire the phase 1 stubs up to real endpoints
- Expand into the full backend described in [[Backend/Overview]]
- Build out [[Coach Conversation]] and AI-assisted [[Workout Planner]]
- Revisit the open questions in [[Backend/Overview]] (S3/CloudFront, Lambda implementation language) once there's an actual server component driving them
