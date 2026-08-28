"""Lifting Coach's server half.

**It reads the phone's snapshot and never writes it.** That is not a convention
this code follows; it is the reason there is no code here that could. See
`notes/Workout App/Backend/Overview.md` for the whole design, and Core Tenets
§1 and §8 for why the coach's only output is a draft the lifter accepts.
"""

__all__ = ["errors", "handlers", "lease", "schema", "snapshots"]
