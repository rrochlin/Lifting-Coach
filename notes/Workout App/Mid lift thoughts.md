21-08-26
Notes aren’t visible from the workout. If something’s written I need to be able to see it. Also the alert for the rest timer completion should be the next set in order, not the current set that triggered the rest. When I do my last set of deadlifts the notification popup doesn’t say I’m doing squats now. 
After a rest time is over if I’m not on the app I don’t get the sound, but when I open the app the sound plays.

18-08-26
Entering weight in the warmup set I’d like an enter button to take me to the next input field. Also I have to enter all the warmup sets I want if I don’t have warmup sets. Should be a warmup block at the start of every lift building down???
No sound on rest completion. Should receive an auditory notification
For suggested weights on sets with predefined reps it would be better to suggest a weight taking the reps into account. A naive refill would use the previous weight which could be really off if we’re doing a different rep scheme. 
The rpe selector doesn’t feel optimal, could just be used to the other one but having the .5s staggered out also could just not be the ideal design. It feels like it deprioritizes their selection. 
Yeah definitely feels weird selecting a .5 rpe. The text is lighter also. 
Persistant card on Home Screen when workout is active to quick launch?
Lock screen interaction is really what’s needed. Unlocking the phone is a whole separate interaction. Can I provide a lock menu interface for tracking?
For chest supported rows on the Tuesday session, day 2, the choose your own interface failed. Choose your own workout selector did not open on interaction, and the filter selector was unable to find the exercises “programmed”. Second part is probably a plan translation error
Rest timer modifier is pretty frequently open, don’t think I’m trying to open it either, wonder if it’s opening on time expire?
When you’ve got blank sets below you can also autofill by the entered weight above
Separate default rest timers for warm ups and working sets

No way to toggle or see which sets are warm up or working
I usually talk in weight x reps
Checking off a new workout when there’s a timer active doesn’t dismiss the old timer and start the new one. 
When a timer finishes the full panel opens and makes you click done. We shouldn’t be added pointless gestures for the user

### Addressed (19-08-26)
The 18-08 entry above, item by item. Left as written — this is the capture, not
the ledger; the ledger is `notes/Feedback.md`.

- **Enter → next field** — the numeric keyboard bar has a NEXT: weight → reps →
  the next set's weight. Focus is owned by the screen (`SetField`) because a
  field holding its own `@FocusState` has nothing to hand over to.
- **Warmup sets one at a time / a warmup block building down** — not done, and
  it's in `Feedback.md`'s Backlog with the reason: a generated ramp needs a
  *scheme* (how many steps, percentages of what, rounded to which plates) and
  the plate model it rounds against. The empty-field fallback does help in the
  meantime — an empty warmup shows last session's ramp greyed, per set.
- **No sound on rest completion** — `RestChime`. It plays through the silent
  switch (`.playback`) and ducks rather than stops your music. The notification
  already carried `.sound`; depending on it was the mistake, since it needs a
  permission and is the fallback for when the app *isn't* on screen.
- **Rep-aware weight suggestion** — Backlog, blocked on the theoretical-max
  model that deliberately doesn't exist. Suggestions do match within set type
  and by ordinal already.
- **RPE .5s feel deprioritized, text is lighter** — they were: smaller font,
  dimmer ink, narrower button. All three are gone; a half is drawn exactly like
  a whole. (The 1–5.5 disclosure was also overflowing its popover — ten buttons
  in 236pt — and is a grid now.)
- **Persistent card on Home while a workout is active** — done, above TODAY, in
  amber, with what's logged so far. It resumes; it never starts anything.
- **Lock screen interaction** — Backlog. It's a Live Activity, not a music
  integration.
- **Chest-supported rows: selector didn't open, filter found nothing** — both
  real, and two separate bugs. The "your choice" chip was a caption inside the
  expand button, so the one control naming an unmade decision did nothing;
  it's a button now. And the suggestions genuinely resolved to nothing — the
  catalog has no "Chest-supported row" or "Seal row", so tapping the chip
  emptied the screen. Suggestions are search shortcuts, so they now say words
  the catalog contains, a test fails if any of them stops resolving, and a
  search with no hits says so instead of going blank.
- **Rest modifier frequently open on its own** — it was: expiry opened it, and
  when the timer moved to the next set the editor stayed behind on the old one.
- **Autofill blank sets from the weight entered above** — done, as a fallback
  under last session's match, so it fills silence without flattening a ramp.
- **Separate default rest for warmups and working sets** — `RestDefaults`
  (warmup 60s, working 120s, drop 60s). A block still overrides per type, and a
  set still overrides the block.
- **No way to toggle or see warmup vs working** — the set number is now a
  badge: `W1` / `01` / `D1`, and tapping it changes the type.
- **Weight × reps** — reordered, in the tracker and the history editor.
- **Checking a new set doesn't dismiss the old timer** — same stale-editor bug
  as above; the timer itself was always being replaced.
- **Expiry opens the panel and makes you click DONE** — it doesn't any more.
  REST COMPLETE is one line, one tap clears it, and checking off the next set
  clears it too.

07-07-26
It would be nice if the workout adapted to things like vacations, could sync with calendars and health metric like sleep quality etc. 
19-07-26
Swapping to Google Sheets to see notes/intentions suck
Unlocking my phone to check off an active set sucks. Can I get this in the lock screen/summary while musics playing? Do I need to integrate the music player to do that?
It selected multi grip bench for speed which I’m not totally comfortable with doing. 
When programming for power lifting we’re doing our main strength work down in the triples and 5s for reps. But when doing accessories like incline we go up to sets of 10. Using RPE across both sets is clunky since rpe for a triple and rpe for a set of 10 has a huge difference in application. 

27-07-2026
Strong keeps applying previous statuses for a lift I.e. failure to my next sets. This is annoying af since I’m not failing again or using different weights but the UI doesn’t really make it clear i recorded a set as failure on accident. Does failure make sense when I can indicate rpe 10?

Failure really would be 10 with either forced partials or I drop the weight. Not too much difference
