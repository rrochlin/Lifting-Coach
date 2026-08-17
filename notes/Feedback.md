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
- no interaction on completed sets
- should be able to update them, i.e. fix mislogged sets, see incomplete sets, and update start/stop times.
- not showing time of day workout was completed

## Profile
- fine for now
