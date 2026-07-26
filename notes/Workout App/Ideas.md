Currently I'm using claude to help generate a google sheet workout plan and refine it cyclically as I'm working out.
I also use the strong fitness app to track my workouts.
Additionally I've got a fitbit and I have data being logged in apple health as well as the google fitness app trying to coach me etc.

I really like the simple features and data tracking of the strong fitness app but the app doesn't really get updates/attention as it should imo. Seems like the owner just maintains it and doesn't have plans of expansion. The workout catalog is pretty incomplete and is much more geared to simple activities like hitting x sets for y reps, or relies on you to self track the activity instead of trying to help track it for you. i.e. when running you have to log the run metrics and they don't really even make a ton of sense. Running on a treadmil for instance you can't log the incline, and there's plenty of those misses around. Also the workouts haven't been added to in a long time and the RPE schema conflates RPE with RIR.

Google fitness app isn't really focused on working out and is looking more at whole health with integrations to apple health as well as medical records I think???(not 100% on that). It has nice metrics tracking sleep and an AI "Coach" that seems to remember some things and provides regular updates and check ins as events happen. The fitbit device is also pretty good, reliably tracking heart rate and trying it's best to log a workout. 

The biggest miss for both of these applications is the poor ability to plan out a workout program. Strong doesn't let you build out a program or import one. Google fitness won't accept csv files yet to back import fitness data, and doesn't really lend itself much to weightlifting. Both offerings aren't great for specifically weight lifting which is probably not the largest market out there. Chris Bumstead has 4 million subscribers so I would say that for the english speaking market for a weightlifting app that's the approximate size of the market for a serious weightlifting app.

Going to claude I created an excel workout plan after going over some goals and metrics etc. Having the option to AI generate a workout plan is for sure going to be used by some people, but I also want the ability to import the workout plan so people can make/tweak their own.
Also crucial is importing data from other applications, this should be done in an AI agent loop with an AI accepting certain data formats and then having a conversation with a user until they get what they want done.

Once I have a workout setup in strong, despite the setup being grueling, it's super simple to check off workouts and exercises. Setting up the workout at the start or having a template that spans several weeks and has weighted progressions etc is not something the app offers. Also the 1rm progression math is completely flawed, it needs to not do calculations on high rep lifts or use a different formula. The projected 1 rep maxes in my opinion should just be for bench, squat, and deadlift. It should also take into account how much you've been training in low rep ranges and how frequently. It could also have a fatigue tracking estimator

Live adjustments to sets and plans based off of workout performance taking apple metrics into account as well as user assessed energy/diet/etc

## Functional Requirements
- I can track my current workout detailing sets, reps, effort, and notes with minimal effort
- I can setup workouts in advance to load in and go off of
- My workout information is tracked over time and I have tools to see progress
- I can change planned workouts on the fly to adapt to specifically how I'm feeling on a given day. Lifts should be tailored around RPE ratings rather than set to hard numbers
- I can record ad hoc workouts and stretches outside of the normal variations.
- Workouts have clear graphics illustrating the body part
- After completing a workout I have a recap and can talk to my coach about the workout. This will help determine if changes are needed.
- I can work with a coach each block and define a workout plan for that training block while I'm in the deload for the previous block
- I'm able to indicate and differentiate supersets/drop sets/failed reps/warm ups/working sets
- I'm able to create and configure new workouts as needed and save them.


## Feature Ideas
#workout-planner
### Workout Planner
Currently using claude for this having it generate a google sheet, and this isn't really that great. But doing it on mobile and displaying that much info is a tall order. For this portion a web UI might actually be the best thing...... On mobile only though we could certainly collaborate on an excel file or csv type thing going back and forth. The AI could also describe the workout plan or generate templates to review, again though doing this on mobile isn't great. From what I've seen the standard is spreadsheets, and certainly needs to be presented in a tabular format. The big advantage with excel is being able to assign the weight reliably based off of a formula from your actual 1RM, and then have this updated as time goes on. Using RPE to control the weight is a little bit of a cluster. A statistically backed RPE is better definitely, but still a crude tool since its based a ton off of the personal feeling and not as much from the actual empirical truth like a 1RM. This feature also could be a little confused since the whole purpose of the coach is to modify the workout plan.... If we're modifying the workout plan though then we're requiring the user to swap back and forth while reviewing it. That or the chat is an overlay, always available without ruining whatever is going on in the background.