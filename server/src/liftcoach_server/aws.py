"""The one module that knows AWS exists.

Everything else in this package takes a protocol — `SnapshotObjects`,
`MetaStore` — so the policy is testable without credentials, a network, or a
mocking library. This is where those protocols meet boto3, and deliberately
holds no decisions: if a rule can be stated here or in `inspection.py`, it
belongs in `inspection.py`.

`boto3` is imported at call time rather than at module scope so the rest of the
package imports cleanly in an environment that doesn't have it.
"""

from __future__ import annotations

from decimal import Decimal
from pathlib import Path
from typing import Any

from .snapshots import SnapshotMeta


def _partition_key(subject: str) -> str:
    """`USER#{sub}` — the shape `terraform-infrastructure`'s tables use.

    Prefixed rather than bare so a table that later holds a second item type
    for the same user doesn't have to be migrated to make room for it.
    """
    return f"USER#{subject}"


class S3Objects:
    """Reads one snapshot, at one version.

    Nothing here writes. The phone is the only writer of a snapshot and it
    signs its own requests with credentials scoped to its own prefix, so this
    role holds `s3:GetObject` and `s3:GetObjectVersion` and nothing else. That
    is worth preserving as 2.2 adds functions: no server-side code should be
    able to modify a training log, and the cheapest way to guarantee it is for
    no server-side role to have the permission.
    """

    def __init__(self, bucket: str, client: Any | None = None) -> None:
        self._bucket = bucket
        self._client = client

    @property
    def client(self) -> Any:
        if self._client is None:
            import boto3

            self._client = boto3.client("s3")
        return self._client

    def _version(self, version_id: str) -> dict[str, str]:
        # An empty version id means the bucket wasn't versioned when the event
        # fired. Passing `VersionId=""` is an error rather than a no-op, so the
        # argument is omitted instead — the read then returns the current
        # object, which on an unversioned bucket is the only one there is.
        return {"VersionId": version_id} if version_id else {}

    def download(self, key: str, version_id: str, destination: Path) -> None:
        self.client.download_file(
            Bucket=self._bucket,
            Key=key,
            Filename=str(destination),
            ExtraArgs=self._version(version_id) or None,
        )

    def metadata(self, key: str, version_id: str) -> dict[str, str]:
        """The object's user metadata, as S3 hands it back.

        boto3 strips the `x-amz-meta-` prefix and lowercases the names. Nothing
        derived from this is trusted — the phone writes it with its own
        credentials and no signature covers it — so it carries only the device
        id, which exists to make a log line useful and decides nothing.
        """
        response = self.client.head_object(
            Bucket=self._bucket, Key=key, **self._version(version_id)
        )
        return dict(response.get("Metadata") or {})


class DynamoMetaStore:
    """`snapshotMeta` — what the bucket holds, without the file."""

    def __init__(self, table_name: str, resource: Any | None = None) -> None:
        self._table_name = table_name
        self._resource = resource
        self._table: Any | None = None

    @property
    def table(self) -> Any:
        if self._table is None:
            if self._resource is None:
                import boto3

                self._resource = boto3.resource("dynamodb")
            self._table = self._resource.Table(self._table_name)
        return self._table

    def read(self, subject: str) -> SnapshotMeta | None:
        item = self.table.get_item(Key={"pk": _partition_key(subject)}).get("Item")
        if not item:
            return None
        raw_counts = item.get("rowCounts") or {}
        return SnapshotMeta(
            subject=subject,
            key=str(item.get("key", "")),
            version_id=str(item.get("versionId", "")),
            etag=str(item.get("etag", "")),
            byte_count=int(item.get("byteCount", 0)),
            uploaded_at=str(item.get("uploadedAt", "")),
            schema_version=str(item.get("schemaVersion", "")),
            newer_than_server=bool(item.get("newerThanServer", False)),
            unrecognized_migrations=tuple(item.get("unrecognizedMigrations") or ()),
            # DynamoDB numbers come back as Decimal; a row count is an integer
            # and reporting it as `Decimal('840')` would leak the storage
            # layer's type into whatever reads this next.
            row_counts={str(k): int(v) for k, v in raw_counts.items()},
            readable=bool(item.get("readable", True)),
            problem=str(item.get("problem", "")),
            device_id=str(item.get("deviceId", "")),
        )

    def write(self, meta: SnapshotMeta) -> None:
        self.table.put_item(
            Item={
                "pk": _partition_key(meta.subject),
                "key": meta.key,
                "versionId": meta.version_id,
                "etag": meta.etag,
                "byteCount": Decimal(meta.byte_count),
                "uploadedAt": meta.uploaded_at,
                "schemaVersion": meta.schema_version,
                "newerThanServer": meta.newer_than_server,
                "unrecognizedMigrations": list(meta.unrecognized_migrations),
                "rowCounts": {k: Decimal(v) for k, v in meta.row_counts.items()},
                "readable": meta.readable,
                "problem": meta.problem,
                "deviceId": meta.device_id,
            }
        )


def build_dependencies(bucket: str, meta_table: str) -> Any:
    """The composition root, built from the Lambda's environment."""
    from .handlers import Deps

    return Deps(objects=S3Objects(bucket), meta=DynamoMetaStore(meta_table))
