# Feedback
This document will be a thorough review of the current application state and issues that I'm seeing broken down by section

## Home
- highlighted workout doesn't have  a quickstart click interaction
- we should shift the plan timeline back for testing. I'm actually doing that plan now and I'm on the last workout of week 5 actually
- I can log bodyweight, but that doesn't appear to go anywhere. Also I'd like to use a wheel selector prepoulated with the previous recorded weight. we should allow up to 1/10 kg/lb resolution entered.

## Workout
- rest timer is at the top of the page, it should be below each lift since it can change for each lift and we need to see where we are at.
- most improtant things to see are the current lift/lifts being preformed and their details, i.e. if we're currently doing an exercise or superset exercise we should see the sets and reps. We can have a collapsed preview of the next coming workout for the other things.
- In the program we have blocks where we want to do a specific workout, i.e. bench press or deadlift. There are other blocks where we want to do bench press, but heavy/paused. Those are both bench press not two different exercises.
- Slide to delete action, slide happens on the enclosing block for each exercise instead of the individual rows for the workout. The rows for each set should have the slide delete on them. deleting an entire exercise should be done from a settings menu on the workout block itself
- Sets don't have anywhere to input and track weight/rpe, only a box to check off their completion. Everything should be modifiable and adjustable. if we can't change the reps/weight and log RPE we're missing a huge piece of the required function.
we should have the ability to drag to reorder the sets and whole exercises.
- the popup dialog warning about unfinished sets on a finished workout looks out of place and theme.
- Before a workout is started the only option is to start he programmed "today" workout or a blank one. I'd like to see a local view of the programmed lifts and be able to start another one if needed. the current days workout should be highlighted. We should be able to skip a workout too if needed.
- no notes


## Plan
- clicking the workout title adds new sets, this should only happen with the add set button.
- can't gleam enough information at a glance, you have to click into the days workout to see what is actually going on there. The google sheet gives a much better overview of the info. We need that overview, and the click edit interaction should focus on the day with better edit controls, similar to the workout tracker interface users will be used to.
- No ability to edit weights or set them at all.
- no notes
- slide delete has the same issue as the workout tab
- no confirmation to save changes on the plan, we should have that when modifying a day.
- no where to set RPE's

## History
- ~~no interaction on completed sets~~ — tapping a workout opens `WorkoutDetailView`.
- ~~should be able to update them, i.e. fix mislogged sets, see incomplete sets, and update start/stop times.~~ — EDIT on the detail screen: reps, weight, RPE, set type, notes, add/delete sets and exercises, title, and both start/stop times. Draft-based, saved on an explicit SAVE.
  - "See incomplete sets" is the one part with nothing to show: finishing a workout deletes its incomplete sets, so none survive into history. If they should survive instead, that's a change to `WorkoutSession.finish`, not to this screen.
- ~~not showing time of day workout was completed~~ — shown on every row.

## Profile
- fine for now

## Backlog
Not broken — wanted, and bigger than a fix.

- **Plate calculator (lb and kg).** Given a target weight and a bar, say what to
  load per side. Needs a real model of what's *available*: bar weight (45/35/15
  lb, 20/15 kg), which plates the gym has and how many, and whether the lifter
  wants the closest loadable weight or the nearest one under. Both units, and
  not by converting one to the other — a kg gym has 25/20/15/10/5/2.5/1.25 kg
  plates, not 55.1 lb ones, so rounding a converted target to "available plates"
  in the wrong unit gives a number nobody can load. Reads naturally next to the
  weight field, which since the numeric keyboard bar landed is also where the
  ±2.5 lb / ±1 kg step lives — Strong puts both in the same panel.
- **Bodyweight wheel selector**, prepopulated with the last recorded weight, to
  1/10 of a unit (from Home, above) — still a plain text field.
- **Replay achieved maxes after a history edit.** Correcting a 500 lb squat
  down to 405 leaves the max event that was recorded at the time, and marking a
  heavy single as `.working` after the fact doesn't produce the max it should
  have. `achievedMax` is deliberately append-only *event history* rather than a
  derived table (Core Tenets §6), so a rebuild-from-log would change what that
  table is — which is a decision, not a detail. `scripts/src/liftimport/maxes.py`
  already replays the rule chronologically and is the reference for how.
- **Swap which exercise a logged block was.** "I logged this under the wrong
  lift" is a real correction and the History editor can't make it. Needs the
  picker in the editor plus an answer to the maxes question above, since moving
  sets between lifts invalidates both lifts' bests.
- **Reorder exercises and sets in a logged workout.** `LoggedWorkoutDraft` has
  `moveGroup`/`moveSet` and nothing in the editor drives them — same unresolved
  drag-to-reorder question as the tracker, which lost its `EditButton`.
- **Reorder exercises within one superset.** `moveGroup` reorders whole groups
  and `superset`/`ungroup` form and dissolve them, but nothing swaps the two
  lifts inside a pair.
