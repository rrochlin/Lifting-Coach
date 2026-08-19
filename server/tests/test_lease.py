"""One device at a time, and the asymmetry between claiming and releasing."""

from __future__ import annotations

import pytest

from liftcoach_server import lease as lease_policy
from liftcoach_server.errors import SignedInElsewhere
from liftcoach_server.lease import InMemoryLeaseStore


@pytest.fixture
def store() -> InMemoryLeaseStore:
    return InMemoryLeaseStore()


def test_claiming_grants_the_lease(store: InMemoryLeaseStore) -> None:
    lease_policy.claim(store, "sub-abc", "phone-1", device_name="Rob's iPhone")
    assert lease_policy.require(store, "sub-abc", "phone-1").device_name == "Rob's iPhone"


def test_signing_in_elsewhere_takes_it(store: InMemoryLeaseStore) -> None:
    """Signing in on a phone *is* the decision. Asking the lifter to resolve a
    conflict first would be asking them to answer what they just answered."""
    lease_policy.claim(store, "sub-abc", "phone-1")
    lease_policy.claim(store, "sub-abc", "phone-2")

    assert lease_policy.require(store, "sub-abc", "phone-2").device_id == "phone-2"
    with pytest.raises(SignedInElsewhere):
        lease_policy.require(store, "sub-abc", "phone-1")


def test_a_device_that_never_claimed_is_refused(store: InMemoryLeaseStore) -> None:
    """An account with no lease is refused rather than treated as free —
    otherwise the check is something a caller skips by omitting a step."""
    with pytest.raises(SignedInElsewhere):
        lease_policy.require(store, "sub-abc", "phone-1")


def test_the_refusal_names_the_device_holding_it(store: InMemoryLeaseStore) -> None:
    lease_policy.claim(store, "sub-abc", "phone-2", device_name="the new one")
    with pytest.raises(SignedInElsewhere) as raised:
        lease_policy.require(store, "sub-abc", "phone-1")
    assert raised.value.detail["heldBy"] == "the new one"


def test_only_the_holder_may_release(store: InMemoryLeaseStore) -> None:
    """The conditional write, and the whole reason there is one. Signing out on
    a handset that lost the lease hours ago must not unlock an account somebody
    is currently using."""
    lease_policy.claim(store, "sub-abc", "phone-1")
    lease_policy.claim(store, "sub-abc", "phone-2")

    assert lease_policy.release(store, "sub-abc", "phone-1") is False
    assert lease_policy.require(store, "sub-abc", "phone-2").device_id == "phone-2"

    assert lease_policy.release(store, "sub-abc", "phone-2") is True
    with pytest.raises(SignedInElsewhere):
        lease_policy.require(store, "sub-abc", "phone-2")


def test_leases_are_per_account(store: InMemoryLeaseStore) -> None:
    lease_policy.claim(store, "sub-abc", "phone-1")
    lease_policy.claim(store, "sub-xyz", "phone-2")
    assert lease_policy.require(store, "sub-abc", "phone-1").device_id == "phone-1"
    assert lease_policy.require(store, "sub-xyz", "phone-2").device_id == "phone-2"
