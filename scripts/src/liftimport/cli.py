"""``uv run liftimport <command>``.

    extract   a vendor export           ->  staging JSON
    report    staging + mapping         ->  what still needs a decision
    load      staging + mapping + db    ->  rows in an app database
    push      the same, into a simulator or a connected phone

``extract`` and ``report`` are safe to run at will. ``load`` writes, and
``push`` writes to a device — both take an explicit ``--db``/``--target``, and
neither has a default that could surprise you.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from . import report as report_module
from .mapping import Mapping, MappingError
from .sources import strong
from .staging import Staging


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="liftimport", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    extract = commands.add_parser("extract", help="vendor export -> staging JSON")
    extract.add_argument("--csv", type=Path, required=True)
    extract.add_argument("-o", "--out", type=Path, required=True)
    # No unit or zone is inferred from the file: Strong's export states neither,
    # and guessing either one corrupts every row it touches.
    extract.add_argument("--tz", default="America/Los_Angeles")
    extract.add_argument("--unit", default="lb", choices=["lb", "kg"])
    extract.add_argument("--distance-unit", default="mi")

    report = commands.add_parser("report", help="what still needs a decision")
    report.add_argument("--staging", type=Path, required=True)
    report.add_argument("--map", dest="mapping", type=Path)
    report.add_argument("--all", action="store_true", help="include mapped names")

    load = commands.add_parser("load", help="write staging into an app database")
    load.add_argument("--staging", type=Path, required=True)
    load.add_argument("--map", dest="mapping", type=Path)
    load.add_argument("--db", type=Path, required=True)
    load.add_argument(
        "--no-maxes",
        action="store_true",
        help="skip the achieved-max replay",
    )

    push = commands.add_parser("push", help="load into a simulator or phone")
    push.add_argument("--staging", type=Path, required=True)
    push.add_argument("--map", dest="mapping", type=Path)
    push.add_argument("--target", choices=["sim", "device"], required=True)
    push.add_argument("--device", help="simulator UDID or devicectl identifier")
    push.add_argument("--no-maxes", action="store_true")

    args = parser.parse_args(argv)

    try:
        return _dispatch(args)
    except MappingError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


def _dispatch(args: argparse.Namespace) -> int:
    if args.command == "extract":
        staging = strong.parse(
            args.csv,
            timezone_name=args.tz,
            weight_unit=args.unit,
            distance_unit=args.distance_unit,
        )
        staging.write(args.out)
        print(
            f"{len(staging.workouts)} workouts, {staging.set_count} sets, "
            f"{len(staging.exercise_names)} exercise names -> {args.out}"
        )
        return 0

    if args.command == "report":
        staging = Staging.read(args.staging)
        mapped: dict[str, str] = {}
        if args.mapping is not False and (args.mapping or _default_map_exists()):
            mapping = Mapping.read(args.mapping)
            mapped = {
                name: entry.slug or entry.kind
                for name, entry in mapping.entries.items()
            }
        reports = report_module.build(staging, mapped)
        print(report_module.render(reports, unmapped_only=not args.all))
        return 0

    if args.command in ("load", "push"):
        from . import load as load_module

        staging = Staging.read(args.staging)
        mapping = Mapping.read(args.mapping)
        mapping.validate_against_catalog()
        mapping.require(staging.exercise_names)

        if args.command == "load":
            result = load_module.load(
                staging, mapping, args.db, replay_maxes=not args.no_maxes
            )
            print(result.describe())
            return 0

        from . import device

        return device.push(
            staging,
            mapping,
            target=args.target,
            device_id=args.device,
            replay_maxes=not args.no_maxes,
        )

    raise AssertionError(args.command)


def _default_map_exists() -> bool:
    from .mapping import DEFAULT_PATH

    return DEFAULT_PATH.exists()


if __name__ == "__main__":
    raise SystemExit(main())
