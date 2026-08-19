"""The Lambda entry points, and as little else as possible.

Everything a handler does that's worth testing lives in `lease.py`,
`schema.py`, or `snapshots.py`. What's left here is the part that only makes
sense in front of API Gateway: pulling an identity off a validated token,
parsing a body, turning a `ServiceError` into a status code.

**The subject comes from the token, never from the body.** It is what the S3
prefix is built from, so a handler that accepted a caller-supplied `sub` would
let any signed-in account write into any other's snapshot. That is the one line
in this file where a mistake is a breach rather than a bug, which is why it's a
single function every route goes through.
"""

from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass
from typing import Any, Callable

from . import lease as lease_policy
from . import schema, snapshots
from .errors import MalformedRequest, ServiceError, Unauthenticated
from .lease import LeaseStore
from .snapshots import MetaStore, SnapshotObjects

Event = dict[str, Any]
Response = dict[str, Any]


@dataclass
class Deps:
    """What the handlers need, resolved once per container.

    Built from the environment on first use, and replaceable by a test. This is
    `AppEnvironment` on the device side: the composition root is one object, so
    a handler never constructs a client and a test never patches a module.
    """

    objects: SnapshotObjects
    leases: LeaseStore
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
            lease_table=os.environ["LEASE_TABLE"],
            meta_table=os.environ["SNAPSHOT_META_TABLE"],
        )
    return _deps


# MARK: request plumbing


def subject_of(event: Event) -> str:
    """The Cognito `sub` on this request, from the authorizer's claims.

    Both API Gateway shapes are read because the deploy hasn't been written
    yet and choosing between an HTTP API and a REST API shouldn't be settled by
    which one this function happened to parse first. Neither shape is a place
    the caller can write: API Gateway replaces `requestContext.authorizer`
    outright with what the authorizer produced.
    """
    context = event.get("requestContext") or {}
    authorizer = context.get("authorizer") or {}
    claims = authorizer.get("jwt", {}).get("claims") or authorizer.get("claims") or {}
    subject = claims.get("sub")
    if not subject:
        raise Unauthenticated("This request carries no verified identity.")
    return str(subject)


def body_of(event: Event) -> dict[str, Any]:
    raw = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MalformedRequest("The request body is not JSON.") from exc
    if not isinstance(parsed, dict):
        raise MalformedRequest("The request body must be a JSON object.")
    return parsed


def required(body: dict[str, Any], name: str) -> str:
    value = body.get(name)
    if not isinstance(value, str) or not value:
        raise MalformedRequest(f"Missing required field: {name}")
    return value


def respond(status: int, body: object) -> Response:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def route(handler: Callable[[Event, Deps], Response]) -> Callable[[Event, Any], Response]:
    """Turns a refusal into a response, and anything else into a 500.

    Every `ServiceError` is deliberate and safe to describe to the caller;
    anything else is a bug, and its message could carry an object key or a
    table name, so it is logged and answered with a sentence that says nothing.
    """

    def entry(event: Event, context: Any = None) -> Response:
        try:
            return handler(event, dependencies())
        except ServiceError as error:
            return respond(error.status, error.as_body())
        except Exception:  # noqa: BLE001 — the boundary is the point
            import traceback

            traceback.print_exc()
            return respond(500, {"error": "internal", "message": "Something went wrong."})

    entry.__name__ = handler.__name__
    entry.__doc__ = handler.__doc__
    return entry


# MARK: routes


@route
def upload_url(event: Event, deps: Deps) -> Response:
    """`POST /snapshot/upload-url` — may this device upload, and if so, where.

    The order of these three steps is the design, not a preference. The lease
    is checked first because it is the refusal that protects data rather than
    correctness, and it is the cheapest. The schema is judged second. Only then
    does a URL exist — so neither refusal ever costs an upload.
    """
    subject = subject_of(event)
    body = body_of(event)

    device_id = required(body, "deviceId")
    lease_policy.require(deps.leases, subject, device_id)

    verdict = schema.verdict(required(body, "schemaVersion"))

    raw_counts = body.get("rowCounts") or {}
    if not isinstance(raw_counts, dict):
        raise MalformedRequest("rowCounts must be an object of table name to count.")

    ticket = snapshots.prepare_upload(
        deps.objects,
        subject=subject,
        verdict=verdict,
        sha256_hex=required(body, "sha256"),
        row_counts={str(k): int(v) for k, v in raw_counts.items()},
        device_id=device_id,
    )
    return respond(200, ticket.as_body())


@route
def download_url(event: Event, deps: Deps) -> Response:
    """`POST /snapshot/download-url` — where to restore from.

    Lease-checked like the upload. A fresh install claims the lease as part of
    signing in, so by the time it wants this it holds one; a device that lost
    the lease is refused here for the same reason it's refused a PUT, which is
    that it is about to make a whole-file decision about an account somebody
    else is now using.

    A 404 rather than an empty URL when nothing has ever been uploaded. "There
    is no snapshot" is a real answer a fresh account gets, and handing back a
    URL that resolves to a 404 would push that discovery into the download.
    """
    subject = subject_of(event)
    device_id = required(body_of(event), "deviceId")
    lease_policy.require(deps.leases, subject, device_id)

    if deps.meta.read(subject) is None:
        return respond(404, {"error": "noSnapshot", "message": "Nothing has been uploaded yet."})

    return respond(200, snapshots.prepare_download(deps.objects, subject))


@route
def latest_snapshot(event: Event, deps: Deps) -> Response:
    """`GET /snapshot` — what the server holds, without downloading it.

    Not lease-checked. Reading the metadata for your own account is not a
    whole-file decision, and a device that just lost the lease is exactly the
    one that benefits from being able to see the state it's in.
    """
    subject = subject_of(event)
    meta = deps.meta.read(subject)
    if meta is None:
        return respond(404, {"error": "noSnapshot", "message": "Nothing has been uploaded yet."})
    return respond(200, meta.as_body())


@route
def claim_lease(event: Event, deps: Deps) -> Response:
    """`POST /session/lease` — this device, from now on.

    Unconditional: signing in here *is* the decision. See `lease.py` for why
    the asymmetry with `release` is deliberate.
    """
    subject = subject_of(event)
    body = body_of(event)
    held = lease_policy.claim(
        deps.leases,
        subject,
        required(body, "deviceId"),
        device_name=str(body.get("deviceName") or ""),
    )
    return respond(200, {"deviceId": held.device_id, "claimedAt": held.claimed_at})


@route
def release_lease(event: Event, deps: Deps) -> Response:
    """`DELETE /session/lease` — signing out.

    Answers 200 whether or not it removed anything. A device that lost the
    lease hours ago and is now signing out has done all it can, and there is
    nothing for the lifter to do about it — reporting a failure would be
    describing somebody else's phone.
    """
    subject = subject_of(event)
    device_id = required(body_of(event), "deviceId")
    return respond(200, {"released": lease_policy.release(deps.leases, subject, device_id)})


def index_snapshot(event: Event, context: Any = None) -> dict[str, Any]:
    """S3 `ObjectCreated` — records what the bucket now holds.

    Not a route: no caller, no status code, and nothing to answer to. It reads
    the object's own metadata, which was signed into the URL that created it,
    and writes the `snapshotMeta` item.

    **This is why there is no "commit" call.** A phone that dies between the
    PUT and a report is ordinary on a cellular link; making the index a
    consequence of the object existing means there is no window in which the
    two disagree and nothing to reconcile them with.

    Records are handled independently and a failure re-raises, so the whole
    batch is retried by S3. Writing the item is idempotent — same key, same
    content — so a redelivered record costs a duplicate write and nothing else.
    """
    deps = dependencies()
    indexed = 0
    for record in event.get("Records", []):
        s3 = record.get("s3", {})
        key = s3.get("object", {}).get("key", "")
        if not key.endswith("snapshot.sqlite.gz"):
            # Something else landed in the bucket. Not this function's object,
            # and not an error worth failing a batch over.
            continue

        subject = snapshots.subject_from_key(key)
        obj = s3.get("object", {})
        deps.meta.write(
            snapshots.meta_from_object(
                subject=subject,
                key=key,
                etag=str(obj.get("eTag", "")),
                byte_count=int(obj.get("size", 0)),
                metadata=deps.objects.head_metadata(key),
                uploaded_at=str(record.get("eventTime", "")),
            )
        )
        indexed += 1
    return {"indexed": indexed}
