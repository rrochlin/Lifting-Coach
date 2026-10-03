"""Account deletion: everything the account holds, then the account.

Two layers, as elsewhere in this package. The policy — order, refusal,
repeatability — runs against honest in-memory fakes. The boto3 adapters are
tested at their own seam with fake clients, because each holds one decision
worth pinning: which Cognito errors mean "sign in again", and that S3's
`DeleteObjects` answering 200 while refusing keys is a failure, not a success.
"""

from __future__ import annotations

import pytest
from botocore.exceptions import ClientError

from liftcoach_server import accounts, handlers
from liftcoach_server.accounts import InvalidToken, user_prefix
from liftcoach_server.aws import CognitoAccounts, S3Versions
from liftcoach_server.snapshots import InMemoryMetaStore, SnapshotMeta, object_key

# ── Fakes ────────────────────────────────────────────────────────────────────


class FakeAccounts:
    """A user pool that knows which tokens are whose."""

    def __init__(self, tokens: dict[str, str], log: list[str]) -> None:
        self.tokens = dict(tokens)
        self.log = log

    def subject(self, access_token: str) -> str:
        if access_token not in self.tokens:
            raise InvalidToken("Invalid Access Token")
        return self.tokens[access_token]

    def delete(self, access_token: str) -> None:
        self.subject(access_token)
        self.log.append("user")
        del self.tokens[access_token]


class FakeVersions:
    """A versioned bucket: keys map to lists of version ids."""

    def __init__(self, log: list[str]) -> None:
        self.versions: dict[str, list[str]] = {}
        self.log = log
        self.fail_next = False

    def delete_all(self, prefix: str) -> int:
        if self.fail_next:
            self.fail_next = False
            raise RuntimeError("SlowDown")
        doomed = [key for key in self.versions if key.startswith(prefix)]
        count = sum(len(self.versions.pop(key)) for key in doomed)
        self.log.append("versions")
        return count


class LoggingMeta(InMemoryMetaStore):
    def __init__(self, log: list[str]) -> None:
        super().__init__()
        self.log = log

    def delete(self, subject: str) -> None:
        self.log.append("meta")
        super().delete(subject)


def recorded(subject: str) -> SnapshotMeta:
    return SnapshotMeta(
        subject=subject,
        key=object_key(subject),
        version_id="v1",
        etag="e",
        byte_count=1,
        uploaded_at="2026-10-02T00:00:00.000Z",
    )


@pytest.fixture
def log() -> list[str]:
    return []


@pytest.fixture
def world(log: list[str]) -> handlers.AccountDeps:
    deps = handlers.AccountDeps(
        accounts=FakeAccounts({"token-a": "sub-a", "token-b": "sub-b"}, log),
        versions=FakeVersions(log),
        meta=LoggingMeta(log),
    )
    deps.versions.versions = {
        object_key("sub-a"): ["v1", "v2", "marker"],
        object_key("sub-b"): ["v1"],
        # Shares a prefix *string* with sub-a; must survive sub-a's deletion.
        object_key("sub-ab"): ["v1"],
    }
    for subject in ("sub-a", "sub-b", "sub-ab"):
        deps.meta.write(recorded(subject))
    handlers.configure_accounts(deps)
    yield deps
    handlers.configure_accounts(None)


# ── Policy ───────────────────────────────────────────────────────────────────


def test_it_deletes_everything_the_account_holds(world: handlers.AccountDeps) -> None:
    assert handlers.delete_account({"accessToken": "token-a"}) == {
        "deleted": True,
        "objectVersions": 3,
    }
    assert object_key("sub-a") not in world.versions.versions
    assert world.meta.read("sub-a") is None
    assert "token-a" not in world.accounts.tokens


def test_it_touches_no_other_account(world: handlers.AccountDeps) -> None:
    handlers.delete_account({"accessToken": "token-a"})

    assert world.versions.versions[object_key("sub-b")] == ["v1"]
    # The prefix carries a trailing slash, so `users/sub-a` can't reach
    # `users/sub-ab/`.
    assert world.versions.versions[object_key("sub-ab")] == ["v1"]
    assert world.meta.read("sub-b") is not None
    assert world.meta.read("sub-ab") is not None


def test_the_user_goes_last(world: handlers.AccountDeps, log: list[str]) -> None:
    """Until the user is deleted the token still works, which is what makes a
    half-finished deletion repeatable."""
    handlers.delete_account({"accessToken": "token-a"})
    assert log == ["versions", "meta", "user"]


@pytest.mark.parametrize("event", [{"accessToken": "forged"}, {"accessToken": ""}, {}, None])
def test_a_refused_token_deletes_nothing(world: handlers.AccountDeps, log: list[str], event) -> None:
    assert handlers.delete_account(event) == {"deleted": False, "reason": "signInRequired"}
    assert log == []
    assert len(world.versions.versions) == 3


def test_a_failure_part_way_can_be_repeated(world: handlers.AccountDeps) -> None:
    world.versions.fail_next = True
    with pytest.raises(RuntimeError):
        handlers.delete_account({"accessToken": "token-a"})

    # Nothing irreversible happened: the token still works.
    assert "token-a" in world.accounts.tokens
    assert handlers.delete_account({"accessToken": "token-a"})["deleted"] is True
    assert object_key("sub-a") not in world.versions.versions


def test_a_second_call_after_success_is_refused_harmlessly(world: handlers.AccountDeps) -> None:
    handlers.delete_account({"accessToken": "token-a"})
    assert handlers.delete_account({"accessToken": "token-a"})["deleted"] is False


@pytest.mark.parametrize("subject", ["", "a/b"])
def test_no_prefix_is_built_from_a_strange_subject(subject: str) -> None:
    with pytest.raises(accounts.ServiceError):
        user_prefix(subject)


# ── Adapters ─────────────────────────────────────────────────────────────────


def client_error(code: str) -> ClientError:
    return ClientError({"Error": {"Code": code, "Message": f"{code} message"}}, "GetUser")


class FakeCognito:
    def __init__(self, raises: ClientError | None = None, attributes=None) -> None:
        self.raises = raises
        self.attributes = attributes if attributes is not None else [
            {"Name": "email", "Value": "x@example.com"},
            {"Name": "sub", "Value": "sub-a"},
        ]
        self.deleted: list[str] = []

    def get_user(self, AccessToken: str) -> dict[str, object]:  # noqa: N803 - boto3's spelling
        if self.raises:
            raise self.raises
        return {"Username": "signinwithapple_1", "UserAttributes": self.attributes}

    def delete_user(self, AccessToken: str) -> dict[str, object]:  # noqa: N803
        if self.raises:
            raise self.raises
        self.deleted.append(AccessToken)
        return {}


def test_cognito_reports_the_sub_attribute_not_the_username() -> None:
    """Federated users' usernames are `signinwithapple_…`; the prefix is keyed
    on `sub`."""
    assert CognitoAccounts(FakeCognito()).subject("t") == "sub-a"


@pytest.mark.parametrize("code", ["NotAuthorizedException", "UserNotFoundException"])
def test_cognito_refusals_mean_sign_in_again(code: str) -> None:
    with pytest.raises(InvalidToken):
        CognitoAccounts(FakeCognito(raises=client_error(code))).subject("t")


def test_other_cognito_errors_are_not_mistaken_for_refusals() -> None:
    """Throttling is transient; reporting it as "sign in again" would send the
    lifter through a sign-in that can't help."""
    with pytest.raises(ClientError):
        CognitoAccounts(FakeCognito(raises=client_error("TooManyRequestsException"))).subject("t")


def test_a_user_with_no_sub_is_refused() -> None:
    with pytest.raises(InvalidToken):
        CognitoAccounts(FakeCognito(attributes=[])).subject("t")


class FakePaginator:
    def __init__(self, pages: list[dict[str, object]]) -> None:
        self.pages = pages
        self.kwargs: dict[str, object] = {}

    def paginate(self, **kwargs: object):
        self.kwargs = kwargs
        return iter(self.pages)


class FakeS3:
    def __init__(self, pages: list[dict[str, object]], errors=None) -> None:
        self.paginator = FakePaginator(pages)
        self.errors = errors or []
        self.batches: list[list[dict[str, str]]] = []

    def get_paginator(self, name: str) -> FakePaginator:
        assert name == "list_object_versions"
        return self.paginator

    def delete_objects(self, Bucket: str, Delete: dict[str, object]) -> dict[str, object]:  # noqa: N803
        self.batches.append(list(Delete["Objects"]))
        return {"Errors": self.errors} if self.errors else {}


def entry(key: str, version: str) -> dict[str, str]:
    return {"Key": key, "VersionId": version}


def test_s3_deletes_versions_and_markers_across_pages() -> None:
    key = object_key("sub-a")
    s3 = FakeS3([
        {"Versions": [entry(key, "v1"), entry(key, "v2")], "DeleteMarkers": [entry(key, "m1")]},
        {"Versions": [entry(key, "v0")]},
    ])
    assert S3Versions("bucket", s3).delete_all("users/sub-a/") == 4
    assert s3.paginator.kwargs == {"Bucket": "bucket", "Prefix": "users/sub-a/"}
    assert {e["VersionId"] for e in s3.batches[0]} == {"v1", "v2", "m1", "v0"}


def test_s3_batches_at_the_api_limit() -> None:
    key = object_key("sub-a")
    s3 = FakeS3([{"Versions": [entry(key, f"v{n}") for n in range(2500)]}])
    assert S3Versions("bucket", s3).delete_all("users/sub-a/") == 2500
    assert [len(b) for b in s3.batches] == [1000, 1000, 500]


def test_s3_nothing_to_delete_makes_no_call() -> None:
    s3 = FakeS3([{}])
    assert S3Versions("bucket", s3).delete_all("users/sub-a/") == 0
    assert s3.batches == []


def test_s3_refusing_keys_inside_a_200_is_a_failure() -> None:
    """`DeleteObjects` succeeds as a request while refusing individual keys.
    Swallowing that would report a deletion with the log still in the bucket."""
    key = object_key("sub-a")
    s3 = FakeS3([{"Versions": [entry(key, "v1")]}], errors=[{"Code": "AccessDenied", "Message": "no"}])
    with pytest.raises(RuntimeError, match="AccessDenied"):
        S3Versions("bucket", s3).delete_all("users/sub-a/")
