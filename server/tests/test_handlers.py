"""The routes: who is let in, in what order they're refused, and what lands."""

from __future__ import annotations

import json

from conftest import SHA, body_of, request

from liftcoach_server import handlers
from liftcoach_server.snapshots import object_key


def sign_in(deps: handlers.Deps, subject: str = "sub-abc", device: str = "phone-1") -> None:
    handlers.claim_lease(request(subject, deviceId=device, deviceName="a phone"), None)


def upload_request(subject: str = "sub-abc", device: str = "phone-1", **overrides: object):
    body: dict[str, object] = {
        "deviceId": device,
        "schemaVersion": "v14_cognitoSub",
        "sha256": SHA,
        "rowCounts": {"workout": 840},
    }
    body.update(overrides)
    return request(subject, **body)


# MARK: identity


def test_a_request_without_a_verified_identity_is_refused(deps: handlers.Deps) -> None:
    """The subject builds the S3 prefix, so accepting a caller-supplied one
    would let any signed-in account write into another's snapshot."""
    response = handlers.upload_url(request(subject=None, deviceId="phone-1"), None)
    assert response["statusCode"] == 401


def test_the_subject_is_never_taken_from_the_body(deps: handlers.Deps) -> None:
    sign_in(deps, subject="sub-abc")
    event = upload_request()
    json_body = json.loads(str(event["body"]))
    json_body["sub"] = "sub-someone-else"
    event["body"] = json.dumps(json_body)

    handlers.upload_url(event, None)
    assert deps.objects.puts[0]["key"] == object_key("sub-abc")


def test_the_rest_api_claims_shape_is_read_too(deps: handlers.Deps) -> None:
    handlers.claim_lease(
        {
            "requestContext": {"authorizer": {"claims": {"sub": "sub-abc"}}},
            "body": json.dumps({"deviceId": "phone-1"}),
        },
        None,
    )
    assert deps.leases.read("sub-abc") is not None


# MARK: upload


def test_a_signed_in_device_gets_a_url(deps: handlers.Deps) -> None:
    sign_in(deps)
    response = handlers.upload_url(upload_request(), None)

    assert response["statusCode"] == 200
    body = body_of(response)
    assert body["method"] == "PUT"
    assert body["key"] == object_key("sub-abc")
    assert body["headers"]["x-amz-meta-schema-version"] == "v14_cognitoSub"


def test_a_device_that_lost_the_lease_is_refused(deps: handlers.Deps) -> None:
    sign_in(deps, device="phone-1")
    sign_in(deps, device="phone-2")

    response = handlers.upload_url(upload_request(device="phone-1"), None)
    assert response["statusCode"] == 409
    assert body_of(response)["error"] == "signedInElsewhere"


def test_an_old_schema_is_refused_before_a_url_exists(deps: handlers.Deps) -> None:
    """The refusal that would otherwise cost a megabyte of cellular. Nothing
    is signed, so there is no URL for a rejected phone to have tried."""
    sign_in(deps)
    response = handlers.upload_url(upload_request(schemaVersion="v1_core"), None)

    assert response["statusCode"] == 400
    assert body_of(response)["error"] == "unsupportedSchemaVersion"
    assert deps.objects.puts == []


def test_the_lease_is_checked_before_the_schema(deps: handlers.Deps) -> None:
    """Order matters: a device that lost the lease should be told that, not
    told its schema is wrong. Both are true; only one is the lifter's answer."""
    sign_in(deps, device="phone-2")
    response = handlers.upload_url(
        upload_request(device="phone-1", schemaVersion="v1_core"), None
    )
    assert body_of(response)["error"] == "signedInElsewhere"


def test_a_malformed_digest_is_refused(deps: handlers.Deps) -> None:
    sign_in(deps)
    response = handlers.upload_url(upload_request(sha256="not-a-digest"), None)
    assert response["statusCode"] == 400
    assert deps.objects.puts == []


def test_a_missing_field_is_a_sentence_not_a_stack_trace(deps: handlers.Deps) -> None:
    sign_in(deps)
    event = request("sub-abc", deviceId="phone-1")
    response = handlers.upload_url(event, None)
    assert response["statusCode"] == 400
    assert "schemaVersion" in str(body_of(response)["message"])


# MARK: indexing


def test_the_object_landing_is_what_records_it(deps: handlers.Deps) -> None:
    """No commit call. A phone that dies between the PUT and a report is
    ordinary on a cellular link, and there is nothing here for that to leave
    inconsistent."""
    sign_in(deps)
    handlers.upload_url(upload_request(), None)

    key = object_key("sub-abc")
    result = handlers.index_snapshot(
        {
            "Records": [
                {
                    "eventTime": "2026-08-19T12:00:00Z",
                    "s3": {"object": {"key": key, "eTag": '"etag-1"', "size": 1_270_000}},
                }
            ]
        }
    )

    assert result == {"indexed": 1}
    stored = deps.meta.read("sub-abc")
    assert stored is not None
    assert stored.etag == "etag-1"
    assert stored.byte_count == 1_270_000
    assert stored.schema_version == "v14_cognitoSub"
    assert stored.row_counts == {"workout": 840}
    assert stored.device_id == "phone-1"


def test_something_else_in_the_bucket_is_not_indexed(deps: handlers.Deps) -> None:
    result = handlers.index_snapshot(
        {"Records": [{"s3": {"object": {"key": "users/sub-abc/notes.txt", "size": 1}}}]}
    )
    assert result == {"indexed": 0}


def test_reindexing_the_same_object_is_harmless(deps: handlers.Deps) -> None:
    """S3 may redeliver, so the write has to be idempotent — same key, same
    content — rather than guarded by a dedup table."""
    sign_in(deps)
    handlers.upload_url(upload_request(), None)
    event = {
        "Records": [
            {"s3": {"object": {"key": object_key("sub-abc"), "eTag": "e", "size": 10}}}
        ]
    }
    handlers.index_snapshot(event)
    handlers.index_snapshot(event)

    stored = deps.meta.read("sub-abc")
    assert stored is not None and stored.byte_count == 10


# MARK: reading and restoring


def test_a_fresh_account_holds_nothing(deps: handlers.Deps) -> None:
    sign_in(deps)
    assert handlers.latest_snapshot(request("sub-abc"), None)["statusCode"] == 404


def test_latest_needs_no_lease(deps: handlers.Deps) -> None:
    """Reading your own metadata isn't a whole-file decision, and the device
    that just lost the lease is the one that most wants to see the state."""
    sign_in(deps, device="phone-1")
    handlers.upload_url(upload_request(), None)
    handlers.index_snapshot(
        {"Records": [{"s3": {"object": {"key": object_key("sub-abc"), "eTag": "e", "size": 9}}}]}
    )
    sign_in(deps, device="phone-2")

    response = handlers.latest_snapshot(request("sub-abc"), None)
    assert response["statusCode"] == 200
    assert body_of(response)["byteCount"] == 9


def test_restoring_from_nothing_is_a_404_not_a_dead_url(deps: handlers.Deps) -> None:
    sign_in(deps)
    response = handlers.download_url(request("sub-abc", deviceId="phone-1"), None)
    assert response["statusCode"] == 404
    assert deps.objects.gets == []


def test_a_restore_gets_a_url_once_something_is_stored(deps: handlers.Deps) -> None:
    sign_in(deps)
    handlers.upload_url(upload_request(), None)
    handlers.index_snapshot(
        {"Records": [{"s3": {"object": {"key": object_key("sub-abc"), "eTag": "e", "size": 9}}}]}
    )

    response = handlers.download_url(request("sub-abc", deviceId="phone-1"), None)
    assert response["statusCode"] == 200
    assert body_of(response)["method"] == "GET"


def test_a_restore_is_lease_checked(deps: handlers.Deps) -> None:
    sign_in(deps, device="phone-1")
    sign_in(deps, device="phone-2")
    response = handlers.download_url(request("sub-abc", deviceId="phone-1"), None)
    assert response["statusCode"] == 409


# MARK: sign-out


def test_signing_out_releases_the_lease(deps: handlers.Deps) -> None:
    sign_in(deps, device="phone-1")
    response = handlers.release_lease(request("sub-abc", deviceId="phone-1"), None)
    assert body_of(response)["released"] is True
    assert deps.leases.read("sub-abc") is None


def test_signing_out_on_a_stale_device_reports_success_and_changes_nothing(
    deps: handlers.Deps,
) -> None:
    """There is nothing the lifter could do about it, and the message would be
    describing somebody else's phone."""
    sign_in(deps, device="phone-1")
    sign_in(deps, device="phone-2")

    response = handlers.release_lease(request("sub-abc", deviceId="phone-1"), None)
    assert response["statusCode"] == 200
    assert body_of(response)["released"] is False
    held = deps.leases.read("sub-abc")
    assert held is not None and held.device_id == "phone-2"


# MARK: the boundary


def test_an_unexpected_failure_says_nothing_useful_to_an_attacker(
    deps: handlers.Deps, monkeypatch
) -> None:
    """A `ServiceError` is deliberate and safe to describe. Anything else could
    carry a bucket name or a table name into the response."""

    def explode(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("bucket liftcoach-snapshots-prod is on fire")

    monkeypatch.setattr(deps.objects, "presign_put", explode)
    sign_in(deps)

    response = handlers.upload_url(upload_request(), None)
    assert response["statusCode"] == 500
    assert "liftcoach-snapshots-prod" not in str(response["body"])
