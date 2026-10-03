## Description
The User profile page should just be limited to connectivity with other services and other account actions. This is a fitness app so we do want to track and display the user's accolades and metrics, however this page is really just for account management.

## Requirements
- User can sign in/out — **Sign in with Apple, native, only** (no email/password, no browser sheet). Sign-in is required on a fresh install, so this page is mostly where you see *who* you're signed in as and sign out.
- ~~User can link SSO services if we offer them~~ — there is one sign-in method, so there is nothing to link. (Revisit only if a second provider is ever added; Apple sign-in would then still be required to be offered.)
- User can export data/import data
- User can delete account — in two taps, as App Review requires. Deleting asks Apple to confirm it's you (Face ID), then removes the account, every cloud backup version, and the app's Apple grant. The log on the phone stays.