# UI
## Overview
SwiftUI - swiftUI handles everything we will need for the application. Charts, gestures, tables, interaction etc.
## Features

### [[Workout Tracker]]
feature that allows users to view and track their current workout
#### Needed
- shows sets/reps/workout name
- allows modification/addition/deviation of workout
- lets user check off sets when complete
- lets user end workout to save the session data
#### Extra
- shows planned vs achieved
- shows historical sets
- RPE goal will show predicted weight based off of data
	- kind of implies that data needs to be on the phone already to run the calculation
- shows elapsed time
- rest timer/push notification
- tracks time in each set/workout (timing)
- add notes to workout
- pull in notes from plan to remember on workout/set
- difference between working set/warmup/drop set
- forced partials
#### Notes
Strong's approach to this part of the application is really nice and only needs minimal refinements imo. The rest timers are whatever when I use them but the ease at constructing a workout on the fly really points to its effectivity. The important thing for me is capturing what was done and retaining this for data analysis.
### [[Workout Planner]]
##### Needed
- displays planned workouts for training block
- sets/reps/weights/RPE target or % 1RM/notes
- can reference recorded 1RM for bench squat and deadlift to calibrate weight
- can change values at will
#### Extra
- can reference statistics of historical sets with certain criteria to suggest weight
- shows what actually was achieved
- shows historical blocks
- allows targeted conversation with coach about certain items
- shows performance and prediction of strength gain during block
### [[Coach Conversation]]
overlay that will allow you to talk to the "coach" who can provide advice and change the workout plan on the fly.
#### Needed
- safety to not destroy historical/in progress workout data from agent
- overlay that does not disrupt current activity and resumes when dismissed
- background chats are still captured and display when reopened. Background can either be chat panel hidden or app closed/phone locked.
- coach can edit workout plan
- coach can see workout data
#### Extra
- Coach will check in after workouts with the user
- notification badges
- advanced agentic capabilities like tool calls for calculations and workout creation
### [[Workout History]]
Historical tracking of workouts - could be a standalone view or could just be inside of the plan....
#### Needed
- previous workout summary cards
- ability to view and edit them in depth
##### Extra
- visualize workout progress over time with charts showing trends (could be on a separate component)
### [[User Profile]]
Basic configuration page and apple health management options
### [[Homepage]]
Probably should just have quick action buttons that take you into the planned workout or the coaching plan since these are the two primary functions of the app.



# Backend
## Overview
AWS - using cognito with the swift amplify package we can get apple sign on simply. We will use lambdas, and api gateway, and dynamoDB table to serve as the backend application logic. AI chat streams will use bedrock and websocket connections through the lambda to receive chat messages. 


# User Data
| Location | Solution                                                                                                                                                   |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Device   | sqlite/icloud                                                                                                                                              |
| Cloud    | DynamoDB                                                                                                                                                   |
| Photos   | Local only, sent to cloud but not retained in image format just extracted info. i.e. nutrition label is sent: just retain the info pulled not the og image |
App stores user data on device with sqlite but also backs up and syncs to cloud storage when free. App will pull in data from apple health and sync that to our cloud dynamo table for user profile and coach suggestions

## HealthKit Data (low prio)
- Heart Rate during workout
- Food
- Workouts via healthkit
- Steps
- HRV

## App Data
- Workout plan
- Coach conversations (low prio)
- Height (low prio)
- Weight (low prio)
- Body Fat (low prio)
- Workouts

