"""Translates external training logs into Lifting Coach's own language.

Three stages, and only the middle one is allowed to think:

1. **extract** — deterministic, source-specific, catalog-blind. A vendor's
   export becomes :mod:`liftimport.staging`, which knows nothing about the
   exercise catalog and makes no judgment calls.
2. **resolve** — a person or an agent decides what each of the source's
   exercise names actually *is*, once, and writes it down in a mapping file the
   repo then owns. ``report`` prepares that work; nothing here performs it.
3. **load** — deterministic and strict. Reads only the reviewed mapping, and a
   name it doesn't cover aborts the whole import.

The split exists because of the rule in ``notes/Workout App/Concepts.md``:
nothing in this project reads an exercise name and guesses what it is. A guess
that lands wrong is worse than a failure, because it looks like data. The same
discipline already governs program loading (``ProgramLoader``), where the
judgment happens once in ``Resources/Block1.json`` rather than at runtime.
"""

__all__ = ["staging", "mapping", "load", "maxes", "catalog"]
