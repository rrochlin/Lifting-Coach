"""The two things that can go wrong here, and the difference between them.

There is no HTTP surface in this service and so no status codes: the phone
talks to S3 directly with credentials scoped by its own Cognito identity, and
the only code here runs behind an S3 event. What's left is a distinction that
decides whether a failure is *retried* or *recorded*, which is the one piece of
error handling in the package that isn't obvious.

- `UnreadableSnapshot` means the bytes in the bucket are not a snapshot this
  service can read. Retrying cannot help — the same bytes will still be the
  same bytes — so it is written into the index as a fact about the object.
- Anything else (a throttle, a timeout, a permissions change) is transient by
  assumption and is allowed to escape, so S3 retries the event.

`ServiceError` exists only so that boundary can be expressed as one `except`.
"""

from __future__ import annotations


class ServiceError(Exception):
    """Base for the failures this service names rather than merely raises."""

    def __init__(self, message: str, **detail: object) -> None:
        super().__init__(message)
        self.message = message
        self.detail = detail


class MalformedKey(ServiceError):
    """An object key that isn't `users/{subject}/…`.

    The event filter already excludes these, so reaching this is either a
    filter that was loosened without reading this file or an object placed in
    the bucket by hand.
    """


class UnreadableSnapshot(ServiceError):
    """The object is not a snapshot this build can open.

    Not a bug and not necessarily an attack: a truncated upload, a file that
    isn't gzip, a database carrying no migration this build recognises. The
    caller records it and returns, because the alternative — raising, so S3
    retries three times and gives up — leaves the index silent about an object
    that is *known* to be wrong. A recorded problem is something 2.2 can
    decline on (Tenet 10); an empty index is indistinguishable from an upload
    that never happened.
    """
