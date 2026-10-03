"""Deleting an account: everything it touches, then the account itself.

App Review requires an in-app path once accounts exist (Guideline 5.1.1(v)) and
it must *delete*, not deactivate — INFRA-SPEC §9.4. This is the one place in
the package that removes anything, so it is worth being exact about three
things.

**Who.** The caller hands over its Cognito **access token**, and Cognito — not
this code — says whose it is: `GetUser` validates the token server-side and
returns the user's attributes, `sub` among them. So there is no JWT signature
check here, no JWKS to fetch and no crypto to get wrong; a token that is forged,
expired or revoked fails that call and nothing is deleted. The `sub` that comes
back is the same one the phone's IAM policy keys its prefix on, which is why it
can name what to delete.

**What.** On a versioned bucket a plain delete only writes a marker, and every
earlier version stays readable for §4's 30 days. "Deleted" that means "in 30
days" is the true-on-a-technicality this project keeps refusing, so every
version and every marker under `users/{sub}/` is removed. Then the
`snapshotMeta` item. Then the Cognito user — `conversations` and `draft-plans`
join this list when 2.2 and 2.3 exist.

**In what order.** Data first, the user last. Each step is idempotent, and
until the last one the token still works, so a call that dies halfway can
simply be made again and finishes the job. Deleting the user first would make a
half-finished deletion unrepeatable: the token would stop working with the
lifter's training still in the bucket.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .errors import ServiceError
from .snapshots import MetaStore


class InvalidToken(ServiceError):
    """Cognito refused the access token: expired, revoked, forged, or lacking
    the `aws.cognito.signin.user.admin` scope `GetUser` requires.

    Not retried and not a server fault — the phone answers it by signing in
    again, which is also why it is returned rather than raised.
    """


class Accounts(Protocol):
    """The user pool, as seen through one access token."""

    def subject(self, access_token: str) -> str:
        """The `sub` the token belongs to. Raises `InvalidToken`."""
        ...

    def delete(self, access_token: str) -> None:
        """Deletes the user the token belongs to. Raises `InvalidToken`."""
        ...


class SnapshotVersions(Protocol):
    """The bucket, as deletion uses it."""

    def delete_all(self, prefix: str) -> int:
        """Removes every version and delete marker under `prefix`.

        Returns how many it removed, so a report can say so. Must leave
        nothing listable behind or raise.
        """
        ...


@dataclass(frozen=True)
class DeletionReport:
    """What the phone is told. The counts are for the log line, not a UI."""

    subject: str
    object_versions: int

    def as_body(self) -> dict[str, object]:
        return {"deleted": True, "objectVersions": self.object_versions}


def user_prefix(subject: str) -> str:
    """Everything this account owns in the bucket, trailing slash included —
    without it `users/abc` would also match `users/abcdef/`."""
    if not subject or "/" in subject:
        # `GetUser` returns a UUID; anything else is not something to build a
        # delete prefix out of.
        raise ServiceError(f"Refusing to build a prefix from {subject!r}")
    return f"users/{subject}/"


def delete_account(
    access_token: str,
    accounts: Accounts,
    versions: SnapshotVersions,
    meta: MetaStore,
) -> DeletionReport:
    """Deletes the account `access_token` belongs to, and all it holds.

    Raises `InvalidToken` before touching anything if Cognito refuses the
    token. Any other failure propagates; every step is safe to repeat.
    """
    if not access_token:
        raise InvalidToken("No access token")

    subject = accounts.subject(access_token)
    removed = versions.delete_all(user_prefix(subject))
    meta.delete(subject)
    accounts.delete(access_token)
    return DeletionReport(subject=subject, object_versions=removed)
