# Overview
The backend splits into two pieces: a local mobile backend on-device, and an AWS-hosted server backend. Per [[Roadmap]], phase 1 is the local piece only — the server piece below is phase 2 and not scheduled yet.

## Local App Backend
- SQLite stores all application data for a user on-device (workouts, plans, profile)
- Schema should reflect and stay compatible with the data types defined in [[Concepts]]
- HealthKit sync is bidirectional: completed workouts are written out to Apple Health; metrics like heart rate, steps, and HRV are read in from it (per [[Design]]'s HealthKit list)
- No explicit iCloud sync planned, but if there's a low-friction way to back up the local SQLite db via iCloud (e.g. storing it in an iCloud ubiquity container), that's worth doing — not a hard requirement

## Server Backend
- AWS Cognito (via the Swift Amplify package) handles auth, including Sign in with Apple
- API Gateway is the entry point; routes cover sign-in, data upload/sync, chat, and exercise/workout planning
- DynamoDB is the system of record for synced user data
- Long-running agentic work (e.g. generating/refining a workout plan) runs in Lambda, updating server state and streaming results back to the client on sync or query
- Coach chat runs over a websocket connection: incoming messages trigger a Lambda, which can respond and also update the workout plan directly (see [[Design]] for the safety requirement around not destroying historical/in-progress data)
- AI chat itself is served by Bedrock, invoked from the chat-handling Lambda

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

## Open Questions
Both deferred to phase 2 per [[Roadmap]] — not blocking phase 1 (local tracker, no backend dependency):
- **S3 / CloudFront** — `amazing-adventure` uses these for a web-hosted component. Ideas.md floated a web UI for the workout planner ("doing this on mobile isn't great... a web UI might actually be the best thing"). If that happens, this app needs those modules too; if it stays mobile-only, it doesn't.
- **Lambda implementation language** — `terraform-infrastructure/CLAUDE.md` notes `amazing-adventure`'s DynamoDB tables use Binary-type UUIDs specifically to match Golang's binary UUID format. Whatever language Workout App's Lambdas are written in should be decided before the DynamoDB schema is finalized, since it affects key type choices the same way.
