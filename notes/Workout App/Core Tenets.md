# Core Tenets

Principles that decide arguments. When a design question comes up and the answer isn't obvious, it should be resolvable from here. Everything below is a position we've actually taken, with the reasoning attached — so a future disagreement can engage the reasoning rather than re-run the discussion.

---

## 1. The app is an instrument, not an autoregulator

The app **never changes a prescription on the lifter's behalf.** It does not drop weight because an RPE was overshot, does not add weight because a set was easy, does not rewrite next week because this week went badly.

What it does: record what was planned, record what actually happened, and make the difference between them legible. Adjustment is a *decision*, and the decision belongs to the lifter (phase 1) or to the coach (phase 2).

**Why:** the moment the app silently adjusts, the lifter can no longer tell whether a number came from their plan or from an algorithm's opinion — and the plan stops being a thing they can reason about. Autoregulation is a coaching act, not a data-layer act.

This is the tenet most likely to be violated by a well-meaning feature. "It would be smart if it just…" is the warning phrase.

## 2. A prescription has two axes: load and effort

**Load** is an instruction about the bar — 70% of a max, or 405 lb. **Effort** is an instruction about the lifter — RPE 7.

Neither substitutes for the other, and neither is derived from the other:
- Load alone doesn't say whether a set is meant to be easy volume or a grinder. The same 70% can be far too fatiguing or far too light depending on the day.
- Effort alone doesn't say where to start, and leaves the lifter guessing at a number they should have been handed.

Both are stored, both are first-class, and a set carrying only one of them is a legitimate prescription — not a gap to fill in.

**Why it's a tenet and not a detail:** an earlier draft modeled RPE as a *kind of load*, which forced a choice between them. The real program specifies both on the majority of its sets, so that model couldn't represent the thing it existed to represent.

## 3. RPE measures exertion, not reps in reserve

**RIR does not appear in this app.** Not stored, not derived, not offered as a display toggle. RPE is its own scale.

The industry convention is RPE = 10 − RIR. We reject it, for concrete reasons:

- **It breaks across rep ranges.** 17/20 reps and 18/20 reps feel nearly identical; 2/5 and 3/5 are night and day. The mapping from reps-in-reserve to felt effort isn't a rescaling — it isn't even usefully monotonic.
- **It breaks on absolute load.** 5×2 @ 405 with one-minute rests is RPE 7 because 405 takes real focus to move. Under inverse-RIR, the first set scores 8–12 reps in reserve — "RPE 2 to −2," which is meaningless. Meanwhile 455×2 can be RPE 8 at 5–6 reps in reserve, because of what it takes to move it.
- **It breaks on anything that isn't reps.** A mile run has an obvious RPE and no reps in reserve at all. Any non-rep work would need transforming into this frame regardless, so the frame is wrong.
- **It's impractical for strength work.** Training to gain strength means exploring your limits; judging RIR accurately on the fly at heavy loads is guesswork.

### The scale
1–10 in 0.5 increments. Anchored only where the anchors are real:

| RPE | Meaning |
| --- | --- |
| 10 | Failure, or no chance of another rep |
| 9 | All-out effort |
| 8 | Exertion |
| 7 | Some effort |
| 6 | Easy |
| <6 | Unlabeled — warmups, deload, easy conditioning |

Values below 6 are storable but carry no descriptor, because that's the honest state: the programming band is 6–10, and the rest of the scale exists so easy work can be recorded rather than forced into "easy."

## 4. Programming modality belongs to the plan, not the app

An RPE target can mean "work up to this and don't exceed it," or "converge on this," or "three straight sets to failure," or a dual-progression ladder where 225×5, 245×3, and 255×2 each target a different RPE. All of these are valid programming, and which one is in play is communicated by the coach in the plan.

**The app represents all of them and privileges none.** It does not enforce ceiling semantics, does not flag an "undershot" set, does not decide that a modality it doesn't recognize is an error.

Corollary: where intent can't be expressed structurally, it goes in the plan's prose. A notes field carrying "work up, stop at 9" is a *feature*, not a modeling failure.

## 5. Planned and executed are different shapes

They are not the same object with a completion flag:

- **Planned effort lives at the exercise**, with an optional per-set override. That matches how programming is actually written — "Deadlift 5×2 @ RPE 7" is one instruction, not five.
- **Executed effort is always per set**, entered by the lifter, because that's the resolution at which it actually varies. The first set of that 5×2 and the last are different experiences and both are worth having.

The same asymmetry runs through load: planned load can be a percentage of a max, while executed load is always a specific weight that was on the bar.

## 6. Three maxes, never conflated

"1RM" is three different numbers and collapsing them loses information the lifter needs:

- **Achieved** — actually lifted, verified, date-stamped. Ground truth, and the only one that is a fact.
- **Goal** — what the program is written against. Aspirational by construction, set deliberately.
- **Theoretical** — estimated from logged work. Derived, never entered, and changes constantly.

A program written against a goal max is a normal and intentional thing, not an error to correct. Showing a lifter their estimated max next to their achieved max is useful; silently substituting one for the other is not.

See [[Concepts]] for how these are modeled.

## 7. Prediction and analysis are in scope; automatic action is not

Tenet 1 forbids the app from *acting*. It does not forbid the app from *knowing things*. Estimating a max from recent work, projecting a trend, surfacing that a lift has stalled, showing planned against achieved — all squarely in scope, and much of the point.

The line: **the app computes and presents; the lifter decides.**

## 8. Never destroy what was actually lifted

Editing a plan, deleting a block, or letting a coach rewrite programming must never mutate or delete logged history. Logged sets carry a snapshot of what they were prescribed against, so history stays self-contained and readable without the plan that produced it.

Phase 2 makes this sharper: an AI coach with write access to the plan must be structurally incapable of touching the log.

## 9. Phase 1: the lifter is his own coach

There is no AI coach yet, and the app should be genuinely good without one. Phase 1's job is an interface to **organize and plan lifts, and tooling to predict, track, and analyze them.**

A feature that only makes sense once an AI is driving belongs in phase 2. A feature that makes the manual path better is phase 1 work, and stays valuable after the coach arrives.

## 10. Honest empty states

A screen that isn't built says so and names the spec it came from. A number that can't be computed shows as absent, not as zero. A placeholder that looks finished is harder to reason about than a visible gap — and much harder to notice you've been trusting.

Same rule for data: a weight the app can't resolve (an RPE-only prescription, a percentage of a max that was never recorded) stays blank and shows the prescription beside it. Guessing a plausible number is worse than showing none.
