"""The one module that knows AWS exists.

Everything else in this package takes a protocol — `SnapshotObjects`,
`LeaseStore`, `MetaStore` — so the policy is testable without credentials, a
network, or a mocking library. This is where those protocols meet boto3, and
deliberately holds no decisions: if a rule can be stated here or in
`snapshots.py`, it belongs in `snapshots.py`.

`boto3` is imported at call time rather than at module scope so the rest of the
package imports cleanly in an environment that doesn't have it.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from .lease import Lease
from .snapshots import CONTENT_TYPE, SnapshotMeta


def _partition_key(subject: str) -> str:
    """`USER#{sub}` — the shape `terraform-infrastructure`'s tables use.

    Prefixed rather than bare so a table that later holds a second item type
    for the same user doesn't have to be migrated to make room for it.
    """
    return f"USER#{subject}"


class S3Objects:
    """Presigns the phone's requests, and reads back what it uploaded."""

    def __init__(self, bucket: str, client: Any | None = None) -> None:
        self._bucket = bucket
        self._client = client

    @property
    def client(self) -> Any:
        if self._client is None:
            import boto3
            from botocore.config import Config

            # **SigV4 is pinned, and it is not a preference.** Left to its
            # default, boto3 presigns S3 URLs with SigV2 in older regions —
            # measured, not assumed — and SigV2 carries the metadata as *query
            # parameters* rather than signed headers. The whole reason the
            # description rides on the object is that the signature covers it;
            # under SigV2 it doesn't, and a phone could PUT the right bytes
            # under any schema version it liked. `tests/test_presigning.py`
            # pins the signed-header set so this can't quietly regress.
            self._client = boto3.client(
                "s3", config=Config(signature_version="s3v4")
            )
        return self._client

    def presign_put(
        self,
        key: str,
        metadata: dict[str, str],
        checksum_sha256: str,
        expires_in: int,
    ) -> str:
        # Every one of these params is signed, so the phone must send all of
        # them and can alter none of them. That is what makes the metadata a
        # fact about the object rather than the uploader's word for it.
        #
        # Encryption is deliberately absent: the bucket carries a default
        # SSE-KMS rule, which S3 applies to a PUT that asks for nothing. Naming
        # it here as well would mean a key rotation in Terraform silently
        # invalidating every URL this function mints.
        return self.client.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self._bucket,
                "Key": key,
                "ContentType": CONTENT_TYPE,
                "Metadata": metadata,
                "ChecksumSHA256": checksum_sha256,
            },
            ExpiresIn=expires_in,
        )

    def presign_get(self, key: str, expires_in: int) -> str:
        return self.client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": key},
            ExpiresIn=expires_in,
        )

    def head_metadata(self, key: str) -> dict[str, str]:
        """The object's user metadata, as S3 hands it back.

        boto3 strips the `x-amz-meta-` prefix and lowercases the names, which
        is the vocabulary `snapshots.meta_from_object` reads.
        """
        response = self.client.head_object(Bucket=self._bucket, Key=key)
        return dict(response.get("Metadata") or {})


class DynamoLeaseStore:
    """`deviceLease` — one item per account, holding whose phone it is."""

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

    def read(self, subject: str) -> Lease | None:
        item = self.table.get_item(Key={"pk": _partition_key(subject)}).get("Item")
        if not item:
            return None
        return Lease(
            subject=subject,
            device_id=str(item.get("deviceId", "")),
            claimed_at=str(item.get("claimedAt", "")),
            device_name=str(item.get("deviceName", "")),
        )

    def write(self, lease: Lease) -> None:
        self.table.put_item(
            Item={
                "pk": _partition_key(lease.subject),
                "deviceId": lease.device_id,
                "claimedAt": lease.claimed_at,
                "deviceName": lease.device_name,
            }
        )

    def delete_if_held(self, subject: str, device_id: str) -> bool:
        # The one conditional write in the service. Without it, signing out on
        # a handset that lost the lease hours ago would clear the lease
        # belonging to the phone somebody is currently using.
        from botocore.exceptions import ClientError

        try:
            self.table.delete_item(
                Key={"pk": _partition_key(subject)},
                ConditionExpression="deviceId = :device",
                ExpressionAttributeValues={":device": device_id},
            )
            return True
        except ClientError as error:
            if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return False
            raise


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
            etag=str(item.get("etag", "")),
            schema_version=str(item.get("schemaVersion", "")),
            byte_count=int(item.get("byteCount", 0)),
            uploaded_at=str(item.get("uploadedAt", "")),
            # DynamoDB numbers come back as Decimal; a row count is an integer
            # and reporting it as `Decimal('840')` would leak the storage
            # layer's type into the phone's JSON.
            row_counts={str(k): int(v) for k, v in raw_counts.items()},
            sha256=str(item.get("sha256", "")),
            device_id=str(item.get("deviceId", "")),
            newer_than_server=bool(item.get("newerThanServer", False)),
        )

    def write(self, meta: SnapshotMeta) -> None:
        self.table.put_item(
            Item={
                "pk": _partition_key(meta.subject),
                "key": meta.key,
                "etag": meta.etag,
                "schemaVersion": meta.schema_version,
                "byteCount": Decimal(meta.byte_count),
                "uploadedAt": meta.uploaded_at,
                "rowCounts": {k: Decimal(v) for k, v in meta.row_counts.items()},
                "sha256": meta.sha256,
                "deviceId": meta.device_id,
                "newerThanServer": meta.newer_than_server,
            }
        )


def build_dependencies(bucket: str, lease_table: str, meta_table: str) -> Any:
    """The composition root, built from the Lambda's environment."""
    from .handlers import Deps

    return Deps(
        objects=S3Objects(bucket),
        leases=DynamoLeaseStore(lease_table),
        meta=DynamoMetaStore(meta_table),
    )
