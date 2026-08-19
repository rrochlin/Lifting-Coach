"""Gets a loaded database onto a simulator or a connected phone.

The app owns its database, so this works by finding the real file, writing into
it, and — on a device — putting it back. It **always takes a backup first.**
The phone is a dev device whose data is expendable, but the entire point of this
pipeline is putting five years of training onto it, and losing that to a
half-finished write would be a bad joke.

Two identifier gotchas the repo has already paid for once, repeated here so this
module doesn't rediscover them:

- The **simulator container path changes on every reinstall**, so it is resolved
  fresh each run via ``simctl get_app_container`` rather than remembered.
- ``devicectl`` and ``xcodebuild`` use **different identifiers for the same
  phone**. This uses devicectl's.
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

from .load import load
from .mapping import Mapping
from .staging import Staging

BUNDLE_ID = "com.rrochlin.LiftingCoach"
DB_RELATIVE = "Library/Application Support/LiftingCoach/db.sqlite"
# The app opens its database with GRDB's `DatabasePool`, which means **WAL
# mode**, which means `db.sqlite` alone is not the database.
#
# Both halves of the round trip are wrong without these:
# - Pulling only the main file gets a snapshot missing everything still in the
#   write-ahead log — up to and including the migration record that `load`
#   checks for, which would fail on a phone that is perfectly up to date.
# - Pushing a rewritten main file back while the phone still holds the *old*
#   `-wal` lets SQLite replay stale frames over new content on the next open.
#   That isn't staleness, it's corruption.
#
# So all three move together, and the local copy is checkpointed flat before it
# goes back, leaving a truncated log that has nothing left to replay.
WAL_RELATIVE = DB_RELATIVE + "-wal"
SHM_RELATIVE = DB_RELATIVE + "-shm"


def _run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{' '.join(command)}\n{result.stderr.strip()}")
    return result.stdout.strip()


def _booted_simulator() -> str:
    listing = _run(["xcrun", "simctl", "list", "devices", "booted"])
    for line in listing.splitlines():
        if "(" in line and "Booted" in line:
            return line.split("(")[1].split(")")[0]
    raise RuntimeError("no booted simulator — boot one and launch the app once")


def push(
    staging: Staging,
    mapping: Mapping,
    *,
    target: str,
    device_id: str | None = None,
    replay_maxes: bool = True,
) -> int:
    if target == "sim":
        udid = device_id or _booted_simulator()
        container = Path(
            _run(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"])
        )
        database = container / DB_RELATIVE
        if not database.exists():
            raise RuntimeError(
                f"{database} doesn't exist — launch the app once so it migrates."
            )

        backup = database.with_suffix(".sqlite.bak")
        shutil.copy2(database, backup)
        print(f"backed up -> {backup}")

        result = load(staging, mapping, database, replay_maxes=replay_maxes)
        print(result.describe())
        print("relaunch the app to rebuild exerciseStats.")
        return 0

    if not device_id:
        raise RuntimeError(
            "pass --device (from `xcrun devicectl list devices`) for a phone"
        )

    # A device round-trips through a temp copy: pull, load locally, push back.
    # `devicectl` can move files in and out of a development-signed app's data
    # container, but nothing can open that file in place.
    #
    # **Quit the app on the phone first.** A running app holds the database open
    # and may commit between the pull and the push, and those commits would be
    # thrown away by the write-back with nothing to warn you.
    with tempfile.TemporaryDirectory() as scratch:
        local = Path(scratch) / "db.sqlite"
        _pull(device_id, DB_RELATIVE, local)
        # The sidecars may legitimately be absent — a database closed cleanly
        # has no log to carry — so a missing one is not an error.
        _pull(device_id, WAL_RELATIVE, local.with_name("db.sqlite-wal"), optional=True)
        _pull(device_id, SHM_RELATIVE, local.with_name("db.sqlite-shm"), optional=True)

        keep = Path.cwd() / "db.sqlite.device-backup"
        shutil.copy2(local, keep)
        print(f"backed up -> {keep}")

        result = load(staging, mapping, local, replay_maxes=replay_maxes)
        print(result.describe())

        checkpoint(local)

        _push(device_id, local, DB_RELATIVE)
        # The truncated log goes back too, and must: leaving the phone's
        # original `-wal` beside a rewritten main file is the corruption case
        # this whole dance exists to avoid.
        wal = local.with_name("db.sqlite-wal")
        if not wal.exists():
            wal.write_bytes(b"")
        _push(device_id, wal, WAL_RELATIVE)

    print("relaunch the app to rebuild exerciseStats.", file=sys.stderr)
    return 0


def checkpoint(database: Path) -> None:
    """Folds the write-ahead log into the database file and truncates it.

    Python's own close does a passive checkpoint, which folds the frames in but
    leaves the log file sized as it was. That's fine locally and not fine for a
    file about to be copied somewhere else — an empty log is the one state that
    can't replay anything unexpected on the far side.
    """
    connection = sqlite3.connect(database)
    try:
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    finally:
        connection.close()


def _pull(device_id: str, remote: str, local: Path, *, optional: bool = False) -> None:
    try:
        _run([
            "xcrun", "devicectl", "device", "copy", "from",
            "--device", device_id,
            "--domain-type", "appDataContainer",
            "--domain-identifier", BUNDLE_ID,
            "--source", remote,
            "--destination", str(local),
        ])
    except RuntimeError:
        if not optional:
            raise


def _push(device_id: str, local: Path, remote: str) -> None:
    _run([
        "xcrun", "devicectl", "device", "copy", "to",
        "--device", device_id,
        "--domain-type", "appDataContainer",
        "--domain-identifier", BUNDLE_ID,
        "--source", str(local),
        "--destination", remote,
    ])
