"""The refusals this service makes, and the words the phone knows them by.

Every error here has a counterpart in `Sources/App/Backend/BackendClient.swift`'s
`BackendError`. The `code` string is the contract between them: the phone
switches on it to decide what to tell the lifter, so it is a stable identifier
and not a message. The prose in `message` is for a log and for a human reading
a curl, never for a `==`.

Two-copies-of-one-rule is a shape this project has been bitten by before (see
`scripts/src/liftimport/maxes.py`), so the codes are pinned against the Swift
enum by `tests/test_errors.py` rather than kept in step by memory.
"""

from __future__ import annotations


class ServiceError(Exception):
    """Something the caller asked for and may not have.

    Carries the HTTP status because the mapping from "what went wrong" to
    "what the phone sees" belongs with the error, not with each handler that
    might raise it — a handler that had to remember 409 could remember 403.
    """

    status: int = 400
    code: str = "badRequest"

    def __init__(self, message: str, **detail: object) -> None:
        super().__init__(message)
        self.message = message
        self.detail = detail

    def as_body(self) -> dict[str, object]:
        return {"error": self.code, "message": self.message, **self.detail}


class Unauthenticated(ServiceError):
    """No validated identity on the request.

    This is a bug or an attack, never a state the app reaches: every route here
    sits behind a Cognito authorizer, so a request without a `sub` claim did
    not come through the front door.
    """

    status = 401
    code = "unauthenticated"


class SignedInElsewhere(ServiceError):
    """Another device holds the lease.

    The one refusal in the design that exists to protect data rather than
    access. Two devices uploading whole-file snapshots of the same account
    would take turns overwriting each other's training log, and no retry policy
    fixes that — so the second device is stopped at the door instead.
    """

    status = 409
    code = "signedInElsewhere"


class UnsupportedSchemaVersion(ServiceError):
    """The snapshot was written by a build too old for this service to read.

    Raised *before* a presigned URL is issued, so a phone that would be refused
    finds out before it spends a megabyte of cellular getting there.
    """

    status = 400
    code = "unsupportedSchemaVersion"


class MalformedRequest(ServiceError):
    """The body isn't the shape this route takes."""

    status = 400
    code = "malformedRequest"
