## Description
Overview of a workout block as it is being planned/executed. Can modify and alter the workout plans with and without AI help. Changes are tracked and AI can view changes made on session resume in order to help it understand decisions and gaps. 

## Requirements
### Phase 1
- Shows one workout block at a time
- Users can see the programmed workouts, weights, and effort levels
- Users can modify programmed lifts
- We have a compact view of the information taking full advantage of screen real estate
- If a block is in progress the default focus is on the current area of the lift
### Phase 2
- AI can edit and control program
- AI doesn't change the completed parts of the block plan, i.e. if we took out bench in week 3 don't rewrite weeks 1 & 2, just do 3 on.
- Completed workout plans are locked in for % lifts, i.e. if we calculated the lift off of % max and did the workout on jan 1, we wouldn't want that to keep recalculating if we set new PR/max


The key missing piece from other market offerings. Google sheets is the current gold standard that we're seeking to compete with. We need to offer something that has all of the intelligence and organization build in as well as allows AI to manage and update it.

For the initial offering though it will need to just be a csv/excel upload since actually building out the agentic portion will take a lot of testing and refinement. Also crucially the agentic piece can happen outside of the development flow since we can test the agent's ability to modify and refine the plan outside of the UI for doing it in the first phase before shipping the product feature. 

The reason why google sheets is so powerful here is being able to leverage known max lifts in order to quickly gauge weights for workouts: i.e. when programming bench we can write a generic workout plan for a certain bracket of athlete and program it off of x% of max respecting plate weight intervals. 

There are much more advanced analytics that we can do as far as assigning weight to lifts as well but for the purpose of simplicity just offering % of max is a fine start