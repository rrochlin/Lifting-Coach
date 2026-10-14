
The connection to agentic plan development. It would be pretty normal for a user to want to chat with the AI in light of the context of whatever they're currently seeing on the page.

## Decided (2026-10-13)
- **Its own Coach tab**, not a sheet over every screen — so the screen-context idea above is dropped for now. 2.3's query tools (the coach reads the log itself) cover most of what "what am I looking at" was for.
- **Messages, not live chat.** You send one; it shows straight away; a typing indicator holds the reply's place until it arrives whole. Leaving the tab or the app in between loses nothing — the reply lands in the conversation, and the tab gets a badge.
- **Claude Sonnet 5.5, through Anthropic's API.** A one-time screen says so and asks before the first message is sent.
- **The coach advises; it never changes the plan.** In 2.2 it can't see the log at all and says so rather than guessing. In 2.3 it reads the log through named tools and proposes plan changes as drafts the lifter accepts.
- Design and resources: `server/INFRA-SPEC.md` §13.

