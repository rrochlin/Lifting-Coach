"""One device at a time, per account.

This is the only lock in the design, and **it guards sign-in, not an object.**
It exists because a snapshot is a whole file: two devices uploading one would
take turns overwriting each other's training log, and a mutex over the object
would serialize them without merging them — the loser's sessions are gone
either way. So the second device is stopped before it ever holds a URL.

The three operations are deliberately asymmetric, and the asymmetry is the
design:

- **Claiming is unconditional.** Signing in on a phone *is* the deliberate act
  of saying "this device now." Making the lifter resolve a conflict first would
  be asking them to answer a question they already answered by signing in, and
  the losing device is the one they aren't holding.
- **Requiring is a read**, done when a URL is issued. It is a check with a
  window — a presigned URL outlives it — which is why URLs are minted with a
  short expiry rather than why the check is pointless. See `snapshots.py`.
- **Releasing is conditional on holding.** This is the one place a condition
  earns its keep: a device that lost the lease hours ago and then signs out
  must not be able to clear a lease that now belongs to somebody's current
  phone. Without the condition, signing out on an old handset silently unlocks
  the account.

No TTL, on purpose. A lost or wiped phone doesn't strand an account, because
the next sign-in anywhere takes the lease outright; an expiring lease would add
a window in which two devices both believe they hold it, which is the exact
state this exists to prevent.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Protocol

from .errors import SignedInElsewhere


@dataclass(frozen=True)
class Lease:
    """Which device may currently upload for an account."""

    subject: str
    device_id: str
    claimed_at: str
    #: What the lifter would recognise it as ("Rob's iPhone"), for the message
    #: the losing device shows. Cosmetic — nothing keys off it.
    device_name: str = ""


class LeaseStore(Protocol):
    """The storage this needs, which is less than DynamoDB offers.

    Narrow on purpose: the policy above is what wants testing, and it can't be
    tested through a client whose conditional writes are opaque objects. The
    real implementation is `aws.DynamoLeaseStore`; `InMemoryLeaseStore` below
    is what the tests use, the same split as `SnapshotWatermarkStore` on the
    device side.
    """

    def read(self, subject: str) -> Lease | None: ...

    def write(self, lease: Lease) -> None: ...

    def delete_if_held(self, subject: str, device_id: str) -> bool:
        """Removes the lease only if `device_id` is the one holding it.

        Returns whether it removed anything, so a stale sign-out is a no-op
        that can be logged rather than an error to handle.
        """
        ...


class InMemoryLeaseStore:
    """A lease store for tests and local runs."""

    def __init__(self) -> None:
        self._leases: dict[str, Lease] = {}

    def read(self, subject: str) -> Lease | None:
        return self._leases.get(subject)

    def write(self, lease: Lease) -> None:
        self._leases[lease.subject] = lease

    def delete_if_held(self, subject: str, device_id: str) -> bool:
        held = self._leases.get(subject)
        if held is None or held.device_id != device_id:
            return False
        del self._leases[subject]
        return True


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def claim(
    store: LeaseStore,
    subject: str,
    device_id: str,
    device_name: str = "",
) -> Lease:
    """Takes the lease for this device, whoever held it before."""
    lease = Lease(
        subject=subject,
        device_id=device_id,
        claimed_at=_now(),
        device_name=device_name,
    )
    store.write(lease)
    return lease


def require(store: LeaseStore, subject: str, device_id: str) -> Lease:
    """Confirms this device still holds the lease, or refuses.

    An account with **no** lease at all is refused too, rather than treated as
    free. A device that never claimed one is a device that never signed in
    through the front door, and inventing a lease for it here would make the
    check something a caller can skip by omitting a step.
    """
    held = store.read(subject)
    if held is None:
        raise SignedInElsewhere(
            "This device isn't signed in for this account.",
            heldBy=None,
        )
    if held.device_id != device_id:
        raise SignedInElsewhere(
            "This account was signed in on another device.",
            heldBy=held.device_name or None,
            claimedAt=held.claimed_at,
        )
    return held


def release(store: LeaseStore, subject: str, device_id: str) -> bool:
    """Gives up the lease, if this device is the one holding it."""
    return store.delete_if_held(subject, device_id)
