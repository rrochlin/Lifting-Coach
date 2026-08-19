# Feedback
This document will be a thorough review of the current application state and issues that I'm seeing broken down by section

## Home
- ~~highlighted workout doesn't have  a quickstart click interaction~~ — the today card starts the workout and switches to the Workout tab. An in-progress session now gets its own card above it, in amber, so a workout left running is visible from the screen the app opens on rather than only from the tab you'd have to think to visit.
- ~~we should shift the plan timeline back for testing. I'm actually doing that plan now and I'm on the last workout of week 5 actually~~ — the block's header panel on Plan opens Block Settings: start date (with an explicit "move the program with it"), length in weeks, name, rest defaults, delete. The TODAY readout says which week the change lands you in, so you dial the date until it reads week 6.
- I can log bodyweight, but that doesn't appear to go anywhere. Also I'd like to use a wheel selector prepoulated with the previous recorded weight. we should allow up to 1/10 kg/lb resolution entered.

## Workout
- rest timer is at the top of the page, it should be below each lift since it can change for each lift and we need to see where we are at.
- most improtant things to see are the current lift/lifts being preformed and their details, i.e. if we're currently doing an exercise or superset exercise we should see the sets and reps. We can have a collapsed preview of the next coming workout for the other things.
- In the program we have blocks where we want to do a specific workout, i.e. bench press or deadlift. There are other blocks where we want to do bench press, but heavy/paused. Those are both bench press not two different exercises.
- Slide to delete action, slide happens on the enclosing block for each exercise instead of the individual rows for the workout. The rows for each set should have the slide delete on them. deleting an entire exercise should be done from a settings menu on the workout block itself
- Sets don't have anywhere to input and track weight/rpe, only a box to check off their completion. Everything should be modifiable and adjustable. if we can't change the reps/weight and log RPE we're missing a huge piece of the required function.
~~we should have the ability to drag to reorder the sets and whole exercises.~~ — sets drag inline; exercises have a reorder mode (any exercise's `…` menu) that collapses every lift to one row. The mode isn't cosmetic: `List` maps a drag onto a `ForEach` element, and an expanded exercise is many rows, which is why the old drag animated and landed nowhere.
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
- ~~calendar view~~ — `WorkoutCalendarView`: one month at a time, dots with no detail, a dialog on touch with an EDIT that opens the editor directly. The paged list is still there behind a toolbar toggle, because the two answer different questions.
- ~~no interaction on completed sets~~ — tapping a workout opens `WorkoutDetailView`.
- ~~should be able to update them, i.e. fix mislogged sets, see incomplete sets, and update start/stop times.~~ — EDIT on the detail screen: reps, weight, RPE, set type, notes, add/delete sets and exercises, title, and both start/stop times. Draft-based, saved on an explicit SAVE.
  - "See incomplete sets" is the one part with nothing to show: finishing a workout deletes its incomplete sets, so none survive into history. If they should survive instead, that's a change to `WorkoutSession.finish`, not to this screen.
- ~~not showing time of day workout was completed~~ — shown on every row.

## Search
- ~~search is far too naive — "Barbell incline press" finds nothing even though
  "Barbell Incline Bench Press - Medium Grip" is right there~~ — the picker
  ranks with `ExerciseSearch` now: tokens rather than substrings, so word order
  and missing words are fine; equipment and muscles searchable; plurals and
  compounds collapsed (`pushups` ≡ `push up`); typos tolerated; and a small
  authored alias table for gym words the vendored catalog doesn't use (`pec
  deck` → *Butterfly*, `ohp` → *shoulder press*). Measured against 149 real
  queries from five years of the owner's own logging: substring search answered
  84% of them with a blank screen, this answers 0%.
  - Vector search was built and measured rather than assumed. Both of Apple's
    on-device models are worse than the string matching here — they encode
    topical relatedness, so `squat` lands nearer `deadlift` than any real
    synonym pair, and the contextual model ranks *Pec Deck* → Butterfly 851st
    of 873. The reasoning is in `ExerciseSearch`'s doc comment so it doesn't
    get re-litigated from intuition.

## Profile
- fine for now
- ~~look up exercise info — we have it all, we might as well show it~~ — EXERCISE LIBRARY under `reference`: the whole vendored catalog, searchable, ordered by what you actually train. Each entry shows its tags, primary and secondary muscles (imported since the catalog landed and displayed nowhere until now), everything you've logged under it, and the catalog's own step-by-step instructions. Mid-workout the same screen is one tap away from any lift's `…` menu as "Exercise Info".
- ~~data export~~ — EXPORT DATA writes the whole local database as one JSON archive and hands it to the share sheet. Import stays out by direction; the screen says so rather than leaving the section half-empty.

## Backlog
Not broken — wanted, and bigger than a fix.

- **A warmup block, generated.** Adding warmup sets one at a time and typing
  each weight is the friction; what's wanted is "here is the ramp to today's
  top set", built down from it. This needs a *scheme* the app doesn't have —
  how many steps, what percentages, whether they're of the first working set or
  of a max, whether bar-only counts as a step, and how it rounds to loadable
  plates (which is the plate calculator above, so the two land together). It is
  emphatically not the app deciding your warmup (Core Tenets §1): it proposes a
  ramp into real, editable sets, the way `SetSuggestion` proposes a number.
  Until then `Add Warmup Set` prepends one empty set at a time, and an empty
  warmup field now shows last session's ramp greyed.
- **Rep-aware weight suggestion.** A suggestion drawn from last session's sets
  of 8 is a bad proposal for today's triple, and today the fallback carries the
  weight across unchanged. Doing this properly means relating load to reps —
  which is the **theoretical-max model that deliberately doesn't exist**
  (`MaxReference.theoretical` resolves to `nil` on purpose, and `Ideas.md`
  explicitly distrusts the standard formulas). So this is blocked on that
  decision, not on the suggestion code. What's *not* blocked and is already
  done: matching within set type and by ordinal, so a warmup draws from warmups
  and a fourth working set from the fourth.
- **Lock-screen and Dynamic Island control.** "Unlocking my phone to check off
  an active set sucks" — twice, in two months. The real answer is a Live
  Activity: the running rest timer and the next set on the lock screen, with a
  check-off control. `ActivityKit`, an app-extension target, and a shared app
  group for the session state; the timer is the easy half (it renders from
  `startedAt`/`endsAt`, which is already how `RestTimer` stores itself) and
  logging a set from the widget is the half that needs real design. Notably
  this does **not** need the music player integrated — that was the guess in
  the 19-07 note, and it's wrong; a Live Activity sits on the lock screen
  whatever is playing.
- **Separate RPE scales by rep range.** An RPE 8 triple and an RPE 8 set of ten
  are different instructions, and the app treats the number as one scale. Noted
  19-07-26 and still unaddressed — probably wants the effort target to carry
  its rep context rather than a second scale, but that's a design question.
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
