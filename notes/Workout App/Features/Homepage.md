## Description
Quick actions like begin the workout, and then analytics and metrics on metrics we're interested in tracking for the lifter. For the time being I'm building the app for myself so we can start with bench, squat, deadlift, and weight. Some other things could be adherence to workout plan, phase of workout block, projected strength.

Note: "phase of workout block" here means calendar progress — what week/day of the current block we're on (e.g. "week 3 of 6, day 15") — not a training phase like deload vs. load. That's derivable directly from the current #WorkoutBlock's `startDate`/`endDate` against today (see [[Concepts]]); no separate stored concept needed.

## Requirements
- Simple interaction to start the currently programmed workout for the day if there is one
- Shows current 1RM/max estimates for bench, squat, and deadlift
- Shows current bodyweight
- Shows adherence to the workout plan (planned vs. completed sets/workouts for the current block)
- Shows calendar progress through the current block (what week/day we're on)
- Shows projected strength trend (low priority — depends on the improved 1RM projection work called out in [[Ideas]])