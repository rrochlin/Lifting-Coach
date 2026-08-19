"""Where a snapshot lives, what rides with it, and how the phone is let in.

The phone never holds AWS credentials. It asks for a presigned PUT, and this is
where the decision to issue one is made — lease first, schema second, URL last.
Both refusals happen **before** the URL exists, so a phone that would be turned
away learns it before spending a megabyte of cellular getting there.

Two properties worth understanding before changing anything here.

**The metadata is signed into the URL, so the phone cannot lie about it.** The
schema version, the digest and the row counts are baked into the signature; S3
rejects a PUT whose headers don't match what was signed. That turns "the phone
told us it was v14" from a claim into a fact, and it means the description
travels welded to the bytes it describes — the same property `SnapshotExporter`
gets by reading its stamp out of the exported file rather than off the live
database.

**Nothing commits metadata by making a second call.** The record in DynamoDB is
written by an S3 `ObjectCreated` event, not by the phone reporting success. A
phone that dies between the PUT and the report is the ordinary case on a
cellular link, and a design where that leaves the index disagreeing with the
bucket is a design that needs a reconciler. Here there is nothing to reconcile:
the object *is* the trigger.

**The digest is enforced, not recorded.** The presign carries
`x-amz-checksum-sha256`, so S3 hashes the body it receives and refuses a PUT
that doesn't match. A corrupted upload becomes impossible rather than
detectable-later. The phone doesn't need to know that rule — the ticket it gets
back names the exact headers to send, so all the signing knowledge stays here.
"""

from __future__ import annotations

import base64
import binascii
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Protocol

from .errors import MalformedRequest
from .schema import SchemaVerdict

#: How long a minted URL stays valid. Long enough for a slow upload to *start*
#: — S3 checks the signature when the request arrives, not continuously — and
#: short enough that the lease check behind it hasn't gone far out of date.
UPLOAD_URL_TTL_SECONDS = 300
DOWNLOAD_URL_TTL_SECONDS = 300

#: S3 caps user metadata at 2 KB across all keys. Row counts are ~15 short
#: names and small integers, so this is slack rather than a real constraint —
#: but a snapshot must never fail to upload because a table was added, so an
#: oversized count map is dropped rather than allowed to break the PUT.
MAX_ROW_COUNTS_BYTES = 1500

CONTENT_TYPE = "application/gzip"


def object_key(subject: str) -> str:
    """Where this account's snapshot lives.

    One object per user, overwritten in place. The bucket is versioned, so the
    history is S3's problem and point-in-time restore is a property of the
    design rather than a feature to build — which is also why a lifecycle rule
    expiring noncurrent versions is not optional (see `server/infra/`).
    """
    return f"users/{subject}/snapshot.sqlite.gz"


class SnapshotObjects(Protocol):
    """The only AWS surface this module touches.

    A protocol rather than a boto3 client so the policy above is testable
    without credentials, a network, or a mocking library. `aws.S3Objects` is
    the real one.

    `head_metadata` is here rather than on a separate reader because an S3
    event notification carries the key, the size and the ETag but *not* the
    user metadata — so the one place that reads an uploaded snapshot's own
    account of itself has to go back for it.
    """

    def presign_put(
        self,
        key: str,
        metadata: dict[str, str],
        checksum_sha256: str,
        expires_in: int,
    ) -> str: ...

    def presign_get(self, key: str, expires_in: int) -> str: ...

    def head_metadata(self, key: str) -> dict[str, str]: ...


@dataclass(frozen=True)
class UploadTicket:
    """Everything the phone needs, and nothing it has to reason about.

    `headers` is replayed verbatim on the PUT. Handing back the exact header
    set rather than the rules for building one keeps every signing detail on
    this side — the phone can't get the checksum encoding subtly wrong, because
    it never encodes anything.
    """

    url: str
    key: str
    method: str = "PUT"
    headers: dict[str, str] = field(default_factory=dict)
    expires_in: int = UPLOAD_URL_TTL_SECONDS

    def as_body(self) -> dict[str, object]:
        return {
            "url": self.url,
            "key": self.key,
            "method": self.method,
            "headers": self.headers,
            "expiresIn": self.expires_in,
        }


def hex_to_base64_sha256(hex_digest: str) -> str:
    """Converts the exporter's lowercase hex digest to S3's base64 encoding.

    `SnapshotExporter.Snapshot.sha256` is hex because that's what a human reads
    in a log; `x-amz-checksum-sha256` is base64 because that's what the header
    spec says. Converting here rather than on the phone is the same decision as
    handing back whole headers: one side knows the encoding rules.
    """
    try:
        raw = binascii.unhexlify(hex_digest)
    except (binascii.Error, ValueError) as exc:
        raise MalformedRequest(f"sha256 is not hex: {hex_digest!r}") from exc
    if len(raw) != 32:
        raise MalformedRequest(
            f"sha256 must be 32 bytes; got {len(raw)}",
        )
    return base64.b64encode(raw).decode("ascii")


def _metadata(
    verdict: SchemaVerdict,
    sha256_hex: str,
    row_counts: dict[str, int],
    device_id: str,
) -> dict[str, str]:
    meta = {
        "schema-version": verdict.version,
        "sha256": sha256_hex,
        "device-id": device_id,
        "uploaded-at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    if verdict.newer_than_server:
        # Recorded on the object, so it survives everything: a reader that
        # doesn't understand this schema can tell without consulting a table
        # that may have been written by a different deploy.
        meta["newer-than-server"] = "true"

    encoded = json.dumps(row_counts, separators=(",", ":"), sort_keys=True)
    if len(encoded) <= MAX_ROW_COUNTS_BYTES:
        meta["row-counts"] = encoded
    return meta


def prepare_upload(
    objects: SnapshotObjects,
    subject: str,
    verdict: SchemaVerdict,
    sha256_hex: str,
    row_counts: dict[str, int],
    device_id: str,
    expires_in: int = UPLOAD_URL_TTL_SECONDS,
) -> UploadTicket:
    """Mints the PUT the phone will make.

    Assumes the lease has already been required and the schema already judged —
    both are the caller's to do, and both are done in `handlers.upload_url`
    before this is reached. Splitting it that way keeps this function about
    *shaping a request*, so the order of the refusals is stated in one readable
    place rather than implied by argument evaluation.
    """
    key = object_key(subject)
    checksum = hex_to_base64_sha256(sha256_hex)
    metadata = _metadata(verdict, sha256_hex, row_counts, device_id)

    url = objects.presign_put(
        key=key,
        metadata=metadata,
        checksum_sha256=checksum,
        expires_in=expires_in,
    )

    headers = {
        "Content-Type": CONTENT_TYPE,
        "x-amz-checksum-sha256": checksum,
    }
    headers.update({f"x-amz-meta-{name}": value for name, value in metadata.items()})

    return UploadTicket(url=url, key=key, headers=headers, expires_in=expires_in)


def prepare_download(
    objects: SnapshotObjects,
    subject: str,
    expires_in: int = DOWNLOAD_URL_TTL_SECONDS,
) -> dict[str, object]:
    """Mints the GET a fresh install restores from."""
    key = object_key(subject)
    return {
        "url": objects.presign_get(key=key, expires_in=expires_in),
        "key": key,
        "method": "GET",
        "expiresIn": expires_in,
    }


@dataclass(frozen=True)
class SnapshotMeta:
    """The `snapshotMeta` item: what the server holds, without the file.

    This is the read side of the whole storage design. A coach answering a
    question needs to say what it's as of (Tenet 10), and a phone deciding
    whether to restore needs to know a snapshot exists at all — neither wants
    to download a megabyte to find out.
    """

    subject: str
    key: str
    etag: str
    schema_version: str
    byte_count: int
    uploaded_at: str
    row_counts: dict[str, int]
    sha256: str = ""
    device_id: str = ""
    newer_than_server: bool = False

    def as_body(self) -> dict[str, object]:
        """The `SnapshotDescriptor` shape the phone decodes."""
        return {
            "etag": self.etag,
            "schemaVersion": self.schema_version,
            "byteCount": self.byte_count,
            "uploadedAt": self.uploaded_at,
            "rowCounts": self.row_counts,
        }


def meta_from_object(
    subject: str,
    key: str,
    etag: str,
    byte_count: int,
    metadata: dict[str, str],
    uploaded_at: str | None = None,
) -> SnapshotMeta:
    """Reads a stored object's own account of itself.

    Everything here came off the object, which is the point: it was signed into
    the URL that created it, so none of it is the phone's word for anything.

    Missing row counts are an empty map rather than an error. They are a
    consistency aid — they make "the upload succeeded but the file is wrong" a
    noticeable state — and losing that aid is not a reason to fail an upload
    that S3 already checksummed.
    """
    raw_counts = metadata.get("row-counts", "")
    try:
        counts = json.loads(raw_counts) if raw_counts else {}
    except json.JSONDecodeError:
        counts = {}
    if not isinstance(counts, dict):
        counts = {}

    return SnapshotMeta(
        subject=subject,
        key=key,
        etag=etag.strip('"'),
        schema_version=metadata.get("schema-version", ""),
        byte_count=byte_count,
        uploaded_at=uploaded_at or metadata.get("uploaded-at", ""),
        row_counts={str(k): int(v) for k, v in counts.items()},
        sha256=metadata.get("sha256", ""),
        device_id=metadata.get("device-id", ""),
        newer_than_server=metadata.get("newer-than-server") == "true",
    )


def subject_from_key(key: str) -> str:
    """Recovers whose snapshot an object is, from where it sits.

    The S3 event carries a key and nothing else, so the prefix is the only
    identity available at index time. It is also the one the presigner
    *derived* from a validated token rather than accepted from a request body,
    so trusting it here is trusting the same fact twice, not a new one.
    """
    parts = key.split("/")
    if len(parts) < 3 or parts[0] != "users" or not parts[1]:
        raise MalformedRequest(f"Not a snapshot key: {key!r}")
    return parts[1]


class MetaStore(Protocol):
    """Where `snapshotMeta` items live. `aws.DynamoMetaStore` is the real one."""

    def read(self, subject: str) -> SnapshotMeta | None: ...

    def write(self, meta: SnapshotMeta) -> None: ...


class InMemoryMetaStore:
    """A metadata store for tests and local runs."""

    def __init__(self) -> None:
        self._items: dict[str, SnapshotMeta] = {}

    def read(self, subject: str) -> SnapshotMeta | None:
        return self._items.get(subject)

    def write(self, meta: SnapshotMeta) -> None:
        self._items[meta.subject] = meta
