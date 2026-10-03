"""The Lambda entry points: the indexer, and account deletion.

**`index_snapshot`.** The phone uploads to S3 directly with credentials scoped by its Cognito
identity, so there is no request to authorise, no body to parse and no status
code to choose. What remains is a consequence of an object existing:
`ObjectCreated` fires, and this records what arrived.

**That's why there is no commit call.** A phone that dies between the PUT and a
report is ordinary on a cellular link, and a design where that leaves the index
disagreeing with the bucket is a design that needs a reconciler. Here the object
*is* the trigger.

**`delete_account`.** The one thing the phone asks the server to do, and the one
thing it can't do itself: its role has no delete permission of any kind. It
calls this with Lambda's own `Invoke` API, signed with the same identity-pool
credentials it uploads with — so there is still no URL, no API Gateway and no
public endpoint, only an IAM grant on one function. The access token in the
payload is what decides whose account goes; see `accounts.py`.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from . import accounts, apple, auth_triggers, snapshots
from .errors import UnreadableSnapshot
from .inspection import inspect
from .snapshots import MetaStore, SnapshotMeta

Event = dict[str, Any]


class SnapshotObjects(Protocol):
    """The bucket, as this service uses it: read one object, exactly."""

    def download(self, key: str, version_id: str, destination: Path) -> None: ...

    def metadata(self, key: str, version_id: str) -> dict[str, str]: ...


@dataclass
class Deps:
    """What the handler needs, resolved once per container.

    Built from the environment on first use and replaceable by a test. This is
    `AppEnvironment` on the device side: the composition root is one object, so
    a handler never constructs a client and a test never patches a module.
    """

    objects: SnapshotObjects
    meta: MetaStore


_deps: Deps | None = None


def configure(deps: Deps | None) -> None:
    """Installs the dependencies, or clears them so the next call rebuilds."""
    global _deps
    _deps = deps


def dependencies() -> Deps:
    global _deps
    if _deps is None:
        # Imported lazily so the rest of this module — and every test of it —
        # runs without boto3 present or credentials configured.
        from .aws import build_dependencies

        _deps = build_dependencies(
            bucket=os.environ["SNAPSHOT_BUCKET"],
            meta_table=os.environ["SNAPSHOT_META_TABLE"],
        )
    return _deps


def index_snapshot(event: Event, context: Any = None) -> dict[str, Any]:
    """S3 `ObjectCreated` — records what the bucket now holds.

    Records are handled one at a time and anything unexpected re-raises, so S3
    retries the batch. Writing an item is idempotent — same key, same derived
    content — so a redelivered record costs a duplicate write and nothing else.

    The one failure that does *not* re-raise is `UnreadableSnapshot`: see
    `errors.py` for why a file that cannot be opened is recorded rather than
    retried.
    """
    deps = dependencies()
    indexed = 0
    unreadable = 0

    for record in event.get("Records", []):
        detail = record.get("s3", {})
        obj = detail.get("object", {})
        key = str(obj.get("key", ""))
        if not key.endswith(snapshots.SNAPSHOT_FILENAME):
            # Something else landed in the bucket. Not this function's object,
            # and not an error worth failing a batch over.
            continue

        # **Pinned to the version the event names.** On a versioned bucket a
        # bare read returns the current object, so two uploads inside the same
        # minute — a finished workout and a plan save, which is ordinary —
        # would have this event read the *next* upload's bytes and file them
        # against this one's etag and size. The result is a record that is
        # internally inconsistent with nothing to indicate it.
        version_id = str(obj.get("versionId", ""))

        if _index_one(
            deps,
            key=key,
            version_id=version_id,
            etag=str(obj.get("eTag", "")),
            byte_count=int(obj.get("size", 0)),
            uploaded_at=str(record.get("eventTime", "")),
        ):
            indexed += 1
        else:
            unreadable += 1

    return {"indexed": indexed, "unreadable": unreadable}


def _index_one(
    deps: Deps,
    key: str,
    version_id: str,
    etag: str,
    byte_count: int,
    uploaded_at: str,
) -> bool:
    subject = snapshots.subject_from_key(key)
    device_id = deps.objects.metadata(key, version_id).get("device-id", "")

    with tempfile.TemporaryDirectory() as scratch:
        archive = Path(scratch) / snapshots.SNAPSHOT_FILENAME
        deps.objects.download(key, version_id, archive)

        try:
            contents = inspect(archive)
        except UnreadableSnapshot as problem:
            deps.meta.write(
                SnapshotMeta.unreadable(
                    subject=subject,
                    key=key,
                    version_id=version_id,
                    etag=etag,
                    byte_count=byte_count,
                    uploaded_at=uploaded_at,
                    problem=problem.message,
                    device_id=device_id,
                )
            )
            return False

    deps.meta.write(
        SnapshotMeta.describing(
            subject=subject,
            key=key,
            version_id=version_id,
            etag=etag,
            byte_count=byte_count,
            uploaded_at=uploaded_at,
            contents=contents,
            device_id=device_id,
        )
    )
    return True


@dataclass
class AccountDeps:
    """What `delete_account` needs. Separate from `Deps` because it is a
    separate function with a separate role: the indexer never builds a client
    that can delete, and this never builds one that reads a snapshot."""

    accounts: accounts.Accounts
    versions: accounts.SnapshotVersions
    meta: MetaStore
    apple_grants: apple.AppleGrants


_account_deps: AccountDeps | None = None


def configure_accounts(deps: AccountDeps | None) -> None:
    global _account_deps
    _account_deps = deps


def account_dependencies() -> AccountDeps:
    global _account_deps
    if _account_deps is None:
        from .aws import build_account_dependencies

        _account_deps = build_account_dependencies(
            bucket=os.environ["SNAPSHOT_BUCKET"],
            meta_table=os.environ["SNAPSHOT_META_TABLE"],
        )
    return _account_deps


def delete_account(event: Event, context: Any = None) -> dict[str, Any]:
    """`{"accessToken", "appleAuthorizationCode"}` → `{"deleted": true, "objectVersions": n}`.

    A refused token is an *answer*, `{"deleted": false, "reason":
    "signInRequired"}`, rather than a raise: Lambda reports a raised exception
    as a function error carrying a stack trace, and "sign in again" is neither
    an error nor worth one. Anything else does raise — the phone sees a failed
    call, the lifter sees "try again", and every step is safe to repeat.
    """
    deps = account_dependencies()
    payload = event or {}
    try:
        report = accounts.delete_account(
            str(payload.get("accessToken") or ""),
            str(payload.get("appleAuthorizationCode") or ""),
            accounts=deps.accounts,
            versions=deps.versions,
            meta=deps.meta,
            apple_grants=deps.apple_grants,
        )
    except accounts.InvalidToken as refusal:
        print(f"delete_account refused: {refusal.message}")
        return {"deleted": False, "reason": "signInRequired"}
    except accounts.AppleReconfirmationRequired as refusal:
        print(f"delete_account refused: {refusal.message}")
        return {"deleted": False, "reason": "appleReconfirmationRequired"}
    except accounts.AppleAccountMismatch as refusal:
        print(f"delete_account refused: {refusal.message}")
        return {"deleted": False, "reason": "appleAccountMismatch"}

    # The sub and a count, never the token. Enough to answer "did it run, and
    # for whom" from the log group.
    print(f"delete_account: {report.subject} removed, {report.object_versions} object versions")
    return report.as_body()


# ── Sign in with Apple: the user pool's triggers ─────────────────────────────


@dataclass
class AppleSignInDeps:
    keys: apple.AppleKeys
    #: The bundle id. A token minted for any other app is refused.
    audience: str


_apple_deps: AppleSignInDeps | None = None


def configure_apple_sign_in(deps: AppleSignInDeps | None) -> None:
    global _apple_deps
    _apple_deps = deps


def apple_sign_in(event: Event, context: Any = None) -> Event:
    """Every trigger on the user pool — see `auth_triggers`. Built once per
    container so Apple's keys stay cached between sign-ins."""
    global _apple_deps
    if _apple_deps is None:
        _apple_deps = AppleSignInDeps(
            keys=apple.HttpAppleKeys(), audience=os.environ["APPLE_BUNDLE_ID"]
        )
    return auth_triggers.handle(event, _apple_deps)
