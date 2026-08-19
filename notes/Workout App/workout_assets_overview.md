# Free Assets & Exercise Database Sources for an iOS Workout App (2026)

## TL;DR
- **Build your exercise catalog on `yuhonas/free-exercise-db`** — an Unlicense (public-domain) JSON dataset of 800+ exercises with images, muscle groups, equipment, categories, and step-by-step instructions — as your ingestion backbone, because it's the only well-maintained source that is both structured JSON AND carries a license with zero commercial/attribution friction.
- For **visual demonstrations (GIFs/videos)**, no single free source cleanly covers commercial use with rich animation; the pragmatic path is free-exercise-db's public-domain photos plus a one-time commercial media license (ExerciseDB/AscendAPI's Kaggle plan or exercisedb.io, from $299) if you want animated GIFs, and Pexels/Pixabay for ambient/hero footage.
- For **icons and UI**, use MIT/ISC-licensed open-source icon libraries (Lucide, Tabler, Phosphor) plus game-icons.net (CC-BY) and unDraw (permissive custom license) for illustrations; for muscle diagrams, the react-native-body-highlighter SVG polygons (MIT) are the best free interactive option.

## Key Findings
1. **Best all-round free exercise dataset:** `yuhonas/free-exercise-db` — The Unlicense (public domain), 1.4k GitHub stars, structured JSON + hosted images. No API key, no attribution, commercial-safe.
2. **Richest live API but license-encumbered:** ExerciseDB/AscendAPI (11,000+ claimed exercises with GIFs/videos) — the free tier is limited to 1,500 exercises and its code is AGPL-3.0; clean commercial use requires a paid one-time license.
3. **wger** is the best actively-maintained open API, but its data is CC-BY-SA (share-alike + attribution), a copyleft-style obligation you must weigh for a commercial app.
4. **API Ninjas Exercises API** has clean structured data (3,000+ exercises) but **prohibits commercial use on its free tier** — commercial use requires a paid plan, and it includes no images.
5. Icons and illustrations have abundant, genuinely free (MIT/CC0) options; muscle-diagram and exercise-GIF media are the hardest assets to obtain free-and-commercial.

## Details

### 1A. Exercise Databases / Datasets / APIs

**yuhonas/free-exercise-db** — https://github.com/yuhonas/free-exercise-db
- **Offers:** 800+ exercises. Each record: `id`, `name`, `force` (push/pull/static), `level` (beginner/intermediate/expert), `mechanic` (compound/isolation), `equipment`, `primaryMuscles`, `secondaryMuscles`, `instructions` (step array), `category` (strength, stretching, plyometrics, powerlifting, cardio, olympic weightlifting, strongman), and `images` (JPG paths, typically 2 per exercise showing start/end position).
- **Format:** Individual JSON files + a combined `dist/exercises.json`; also newline-delimited JSON for PostgreSQL import. Images hostable straight from GitHub raw URLs (`https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/...`). JSON Schema provided.
- **License:** **The Unlicense** (public-domain equivalent) — no attribution, fully commercial-safe.
- **Size/activity:** 800+ exercises; **1.4k stars, 399 forks, 89 commits** as of Aug 2026; actively maintained. Derived from the older `wrkout/exercises.json`.
- **Caveats:** Some records have null `force`/`mechanic`/`equipment`; a handful of duplicate images. Photos are 2-frame stills, not animated GIFs.

**wger** — https://github.com/wger-project/wger / API at https://wger.de/api/v2/
- **Offers:** ~800–850 exercises (roughly 690+ English-approved), with names, descriptions (HTML), primary/secondary muscles, equipment, categories (Abs, Arms, Back, Chest, Legs, Shoulders, Calves, Cardio), and reference images/videos. Also nutrition data via Open Food Facts (2M+ foods).
- **Format:** REST API (JSON), self-hostable Django app, Docker images. Public read endpoints (exercises, ingredients) need **no authentication**; user-owned data needs a token. Paginated 20/page (adjust with `?limit=`). Add `language=2` for English and `status=2` for approved-only.
- **License:** Code is AGPL-3.0. **Exercise/ingredient DATA is CC-BY-SA (3.0, and newer records 4.0)** — commercial use allowed but requires attribution AND share-alike on derivative datasets. Each record carries `license` and `license_author` fields for compliance.
- **Rate limits:** No hard published number on public endpoints; caching recommended (responses can be slow). No CORS — call from a backend, not directly from the app client.
- **Caveats:** CC-BY-SA share-alike is the key friction for a proprietary commercial app; data quality varies by community translation.

**ExerciseDB / AscendAPI** — https://exercisedb.dev / repo https://github.com/ExerciseDB/exercisedb-api
- **Offers:** Marketed as 11,000+ exercises, 15,000+ videos, 20,000+ images, 5,000+ GIF animations (vendor marketing; actual purchasable/free tiers top out ~1,400–2,000). Rich fields: `exerciseId`, `name`, `imageUrl`, `equipments`, `bodyParts`, `gender`, `exerciseType`, `targetMuscles`, `secondaryMuscles`, `videoUrl`, `keywords`, `overview`, `instructions`, `exerciseTips`, `variations`, `relatedExerciseIds`.
- **Free tier:** "ExerciseDB V1 API (Free Version)" — 1,500 exercises with 180p GIFs, no sign-up, no API key. Endpoint `https://oss.exercisedb.dev/api/v1/exercises`. Free fields: id, name, gifUrl (180p), bodyParts, targetMuscles, secondaryMuscles, equipments, instructions. No published numeric rate limit but "not recommended for production."
- **Format:** REST API (JSON), one-click Vercel self-host; also a Kaggle downloadable dataset.
- **License:** Repo code is **AGPL-3.0 (© 2025 AscendAPI)** — copyleft, risky for a closed-source commercial iOS app. No separate explicit data/media license in the repo (a genuine ambiguity). Clean commercial media rights are available via paid one-time license (see below).
- **Paid commercial routes:**
  - **Kaggle "Fitness Exercises Dataset" by exercisedb** — 1,500+ exercises with GIF animations; "GIF animations in multiple resolutions (180p → 1080p depending on plan)" and "Commercial rights (one-time payment, no recurring fees)." https://www.kaggle.com/datasets/exercisedb/fitness-exercises-dataset
  - **RapidAPI paid tier** (adds multi-resolution media + extra fields like difficulty, movementType). Free/BASIC tier reported by competitor sources as very restrictive (~10 requests/day) and non-commercial — **unverified officially; confirm on the live listing.**
- **Caveats:** Name collision — **exercisedb.dev (AscendAPI)** and **exercisedb.io (DevWorx Consulting LLC)** are different companies. Headline 11,000+ counts are inconsistent with actually-available tiers; treat as marketing.

**exercisedb.io (DevWorx Consulting LLC)** — https://exercisedb.io/pricing
- **Offers:** **1,394 exercises** (a "master list of 1,394 exercise names" viewable via the free sample), each with animated GIFs, metadata, and instructions. Self-hosted downloadable files.
- **License:** One-time purchase with a **perpetual commercial license**. Per its FAQ: *"You can use the dataset commercially and display the exercise GIFs inside your app... You cannot resell, redistribute, or publish the raw dataset or GIF files as a standalone library."* Pricing: **Mobile (iOS/Android) $299** (180×180 + 360×360 GIFs), Web/Desktop $399, Cross-Platform $599.
- **Best for:** The cleanest turnkey commercial path to animated GIFs for an iOS app with no attribution or copyleft strings.

**API Ninjas Exercises API** — https://api-ninjas.com/api/exercises
- **Offers:** **"over 3000 exercises."** Fields: `name`, `type` (cardio, olympic_weightlifting, plyometrics, powerlifting, strength, stretching, strongman), `muscle`, `difficulty` (beginner/intermediate/expert), `equipment`, `instructions`. **No images/GIFs.**
- **Format:** REST API (JSON), `X-Api-Key` header. Returns up to 5 per call (free); `/v1/allexercises` (bulk) is premium-only.
- **License/limits:** Verbatim: *"Commercial use of the Exercises API is not permitted on the free tier. See our pricing page to choose a plan that fits your needs."* Free tier ~100 API calls/hour, no data caching allowed, attribution required, with reported daily downtime windows.
- **Caveats:** Text-only; commercial paywall makes it unsuitable as a free commercial backbone.

**WorkoutX** — https://workoutxapp.com
- **Offers:** 1,400+ exercises with CDN-hosted GIFs; fields include bodyPart, target, equipment, difficulty, calorie estimates, instructions. Direct REST API (no RapidAPI middleware).
- **License/limits:** Free plan 500 requests/month, 30 req/min, no credit card; GIFs usable commercially on paid plans (and free plan "for evaluation"). Paid $9.99–$24.99/month.
- **Caveats:** Commercial-vendor product (not open data); ongoing subscription; its blog aggressively markets against ExerciseDB, so weigh comparative claims critically.

**Other datasets worth knowing:**
- `wrkout/exercises.json` (public domain) — the original dataset free-exercise-db is built from.
- `exercemus/exercises` — curated from wger + exercises.json; code MIT but each exercise keeps its own (CC) license; minified JSON via `https://raw.githubusercontent.com/exercemus/exercises/minified/minified-exercises.json`.
- `hasaneyldrm/exercises-dataset` — 1,324 exercises, animation GIFs + 180×180 thumbnails, 10 languages, but **media is © Gym Visual (attribution + separate license required)**.
- `azilRababe/Exercises_Dataset` — MIT-licensed curated exercise+GIF collection.
- **OpenPowerlifting** — https://gitlab.com/openpowerlifting/opl-data — competition results (CSV); **data is public domain (CC0)**, code AGPLv3. Useful for strength standards/records, not exercise instructions.

### 1B. Icons & UI Graphics
- **Lucide** — https://lucide.dev — **1,768 icons** (per Iconify), **ISC license** ("No attribution required, commercial use is allowed"); official React/Vue/Svelte/Flutter packages. Best default.
- **Tabler Icons** — https://tabler.io/icons — **6,184 free MIT-licensed SVG icons** (1,053 filled), 24×24 grid, 2px stroke. Broadest coverage including medical/technical.
- **Phosphor Icons** — https://phosphoricons.com — ~1,200 icons × 6 weights (~9,000 total), MIT.
- **Heroicons** — MIT, 292 icons from the Tailwind team.
- **Font Awesome Free** — CC-BY 4.0 (attribution) + fonts under SIL OFL/MIT; many fitness icons but attribution and bloat tradeoffs.
- **game-icons.net** — many muscle/body/equipment icons; CC-BY 3.0 (attribution required).
- **Flaticon / Iconscout / Vecteezy** — huge fitness/muscle icon selection but free tier requires attribution and licensing is per-asset; Premium removes attribution. Read each asset's license.
- **Iconify** — aggregator/framework to consume most of the above open sets programmatically.

### 1C. Illustrations, Muscle Diagrams & Body Silhouettes
- **react-native-body-highlighter** (`@teambuildr/react-native-body-highlighter`, MIT) and **react-body-highlighter** (giavinh79, MIT) — SVG human-body muscle-highlighter components with named muscle slugs (chest, biceps, quadriceps, trapezius, obliques, etc.). The **SVG polygons themselves are reusable** even outside React. Best free interactive muscle map.
- **react-muscle-highlighter** (soroojshehryar, MIT) — front/back views, male/female, intensity gradients, ARIA labels.
- **unDraw** — https://undraw.co — 1,000+ customizable SVG illustrations incl. health/fitness; permissive custom license (free commercial, no attribution; cannot resell as a pack or build a competing service).
- **DrawKit** (MIT), **Flowbite Illustrations** (MIT, 3D-style), **ManyPixels**, **Storyset/Freepik** — health/fitness illustration packs (check each license/attribution).
- **FreeSVG.org / Wikimedia Commons / OpenClipart** — public-domain anatomy/musculature SVGs (e.g., "Male musculature," "Human Anatomy Diagram"), CC0/public domain but older/less polished.
- **Vecteezy** — 11,000+ muscle-anatomy vectors, but free use requires attribution.

### 1D. Exercise Demonstration Videos / GIFs
- **Pexels** — https://pexels.com — 3,000+ exercise videos, Pexels License (free commercial, no attribution). Great for ambient/hero footage, not per-exercise form demos.
- **Pixabay** — 500+ workout videos, Pixabay Content License (free commercial, no attribution).
- **Mixkit / Coverr / Videezy** — additional free stock footage (check per-clip terms; some attribution).
- **Per-exercise animated form GIFs are the hard gap:** the free-and-commercial options are free-exercise-db's 2-frame photos; genuinely animated GIF sets that are free tend to carry © Gym Visual or similar attribution/licensing. For polished animated demos, budget a one-time media license (ExerciseDB Kaggle plan or exercisedb.io) rather than relying on free.

## Recommendations

**Stage 1 — Ship your MVP on public-domain data (zero license risk):**
1. Ingest **`yuhonas/free-exercise-db`** JSON as your core exercise catalog (800+ exercises, all categories, Unlicense). Host its images on your own CDN or via GitHub raw URLs. This gives you names, muscles (primary/secondary), equipment, category, difficulty, mechanic, force, instructions, and start/end photos with **no attribution or share-alike obligations** — ideal for a commercial iOS app and trivial to ingest (structured JSON, no scraping).
2. Use **Lucide (ISC)** or **Tabler (MIT)** for all UI icons; add **game-icons.net (CC-BY)** for equipment/muscle glyphs with a small attribution notice in your credits screen.
3. Use the **react-native-body-highlighter SVG polygons (MIT)** for muscle-group diagrams, mapping free-exercise-db's muscle strings to its slugs.
4. Use **unDraw** for onboarding/empty-state illustrations; **Pexels/Pixabay** for ambient hero video.

**Stage 2 — Enrich once you have traction / budget:**
5. If you need **animated form GIFs**, buy a one-time commercial media license: **exercisedb.io ($299 mobile tier, perpetual, explicit commercial + in-app GIF display rights)** or **ExerciseDB's Kaggle "Fitness Exercises Dataset"**. This avoids AGPL and attribution ambiguity entirely.
6. If you want a **live-updating catalog** and can accept attribution + share-alike, layer in **wger's API** (self-host to control rate/uptime), keeping the `license`/`license_author` fields and displaying attribution.

**Avoid as a commercial backbone:** API Ninjas free tier (no commercial use), raw AGPL ExerciseDB *code* in a closed app, and any Gym Visual-sourced GIFs without buying the license.

**Thresholds that change the recommendation:**
- If your app will itself be **free/open-source** → wger (AGPL + CC-BY-SA) becomes an easy fit and you can even use ExerciseDB's AGPL code.
- If **animated demos are a core differentiator from day one** → skip Stage 1's photo-only approach and buy the media license immediately.
- If you need **>2,000 exercises with rich metadata** → the paid ExerciseDB/AscendAPI tier or the exercisedb.io dataset is the only realistic single source.

## Caveats
- **"Free" ≠ "free for commercial use."** wger (CC-BY-SA, share-alike), API Ninjas (no commercial on free tier), Flaticon/Vecteezy (attribution), and Gym Visual GIFs (paid) all carry obligations. Maintain a `THIRD_PARTY_LICENSES` file listing each source, license, and any attribution text.
- **AGPL is strong copyleft.** Using ExerciseDB's or wger's *code* (not just consuming its data via API) in a networked/commercial app triggers source-disclosure obligations. Consuming wger *data* over the API is a different question from bundling its code — but the data's CC-BY-SA still requires attribution and share-alike on derived datasets.
- **Vendor count claims are inflated.** ExerciseDB's "11,000+ exercises" is inconsistent with its actually-available ~1,400–2,000-exercise tiers; treat marketing numbers skeptically and validate the real payload before committing.
- **RapidAPI free-tier limits for ExerciseDB are unverified** (competitor sources cite ~10 req/day and non-commercial-only). Confirm on the live RapidAPI listing before depending on it.
- **Name collision:** exercisedb.dev (AscendAPI) and exercisedb.io (DevWorx Consulting LLC) are distinct companies with different terms and pricing — don't assume one's license applies to the other.
- **Maintenance signals:** GitHub stars are a reliability proxy, not a guarantee. `yuhonas/free-exercise-db` (1.4k stars, recent commits) and `wger` (active AGPL project with Android/iOS apps) are the most clearly actively maintained free sources as of 2026. Verify the last-commit date on any smaller dataset repo before building on it.