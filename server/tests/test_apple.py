"""Sign in with Apple, server side: tokens, triggers, revocation.

Real keys, real signatures. An RSA key generated here stands in for Apple's,
so verification runs the same `cryptography` calls it runs in Lambda — a fake
verifier that said yes would be testing nothing. Likewise the client secret is
checked by verifying its signature with the EC public key, not by inspecting
the string.
"""

from __future__ import annotations

import base64
import hashlib
import json
import re
import time
from typing import Any

import pytest
from conftest import REPO_ROOT
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature

from liftcoach_server import apple, auth_triggers, handlers
from liftcoach_server.apple import AppleTokenRejected

BUNDLE = "com.rrochlin.LiftingCoach"
APPLE_SUB = "001234.0123456789abcdef0123456789abcdef.0123"
NONCE = "raw-nonce-123"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class StaticKeys:
    def __init__(self, keys: dict[str, Any]) -> None:
        self.keys = keys

    def public_key(self, kid: str) -> Any:
        if kid not in self.keys:
            raise AppleTokenRejected(f"Unknown Apple signing key {kid!r}")
        return self.keys[kid]


APPLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
KEYS = StaticKeys({"k1": APPLE_KEY.public_key()})


def token(
    key: Any = APPLE_KEY,
    kid: str = "k1",
    alg: str = "RS256",
    **overrides: Any,
) -> str:
    claims = {
        "iss": apple.ISSUER,
        "aud": BUNDLE,
        "exp": time.time() + 600,
        "iat": time.time(),
        "sub": APPLE_SUB,
        "email": "lifter@privaterelay.appleid.com",
        "nonce": hashlib.sha256(NONCE.encode()).hexdigest(),
    }
    claims.update(overrides)
    signing_input = b64(json.dumps({"alg": alg, "kid": kid}).encode()) + "." + b64(json.dumps(claims).encode())
    signature = key.sign(signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())
    return signing_input + "." + b64(signature)


def verify(jwt: str, nonce: str = NONCE) -> apple.AppleIdentity:
    return apple.verify_identity_token(jwt, audience=BUNDLE, raw_nonce=nonce, keys=KEYS)


# ── Identity tokens ──────────────────────────────────────────────────────────


def test_a_genuine_token_names_its_apple_user() -> None:
    identity = verify(token())
    assert identity.subject == APPLE_SUB
    assert identity.email == "lifter@privaterelay.appleid.com"


@pytest.mark.parametrize(
    "jwt, why",
    [
        (token(key=OTHER_KEY), "signed by someone else"),
        (token(kid="unknown"), "signed by a key Apple never published"),
        (token(aud="com.someone.else"), "minted for another app"),
        (token(iss="https://evil.example"), "from another issuer"),
        (token(exp=time.time() - 1), "expired"),
        (token(nonce="0" * 64), "from a different sign-in"),
    ],
)
def test_a_token_that_doesnt_check_out_is_refused(jwt: str, why: str) -> None:
    with pytest.raises(AppleTokenRejected):
        verify(jwt)


def test_the_algorithm_is_pinned_not_read_from_the_header() -> None:
    """`alg: none` is the classic way to talk a verifier out of verifying."""
    header = b64(json.dumps({"alg": "none", "kid": "k1"}).encode())
    body = b64(json.dumps({"iss": apple.ISSUER, "aud": BUNDLE, "sub": APPLE_SUB}).encode())
    with pytest.raises(AppleTokenRejected):
        verify(f"{header}.{body}.")


def test_a_token_without_its_nonce_is_refused() -> None:
    with pytest.raises(AppleTokenRejected):
        verify(token(), nonce="")


@pytest.mark.parametrize("garbage", ["", "a.b", "not.a.jwt", "x.y.z.w"])
def test_garbage_is_refused_not_crashed_on(garbage: str) -> None:
    with pytest.raises(AppleTokenRejected):
        verify(garbage)


# ── Usernames ────────────────────────────────────────────────────────────────


def test_a_username_round_trips_to_its_apple_sub() -> None:
    username = apple.username_for(APPLE_SUB)
    assert username == f"{APPLE_SUB}@apple.lift-coach.invalid"
    assert apple.subject_from_username(username) == APPLE_SUB
    assert apple.subject_from_username(username.upper()) == APPLE_SUB


def test_an_operator_created_user_has_no_apple_sub() -> None:
    assert apple.subject_from_username("someone@example.com") is None


def test_the_phone_and_the_server_agree_on_the_username_domain() -> None:
    """Pinned against the Swift, the same way `schema.py` pins the migration
    list: if the two disagree, every sign-up is refused as a mismatch."""
    swift = (REPO_ROOT / "LiftingCoachModel/Sources/LiftingCoachCloud/UserPoolAuth.swift").read_text()
    match = re.search(r'usernameDomain = "([^"]+)"', swift)
    assert match is not None
    assert match.group(1) == apple.USERNAME_DOMAIN


# ── Triggers ─────────────────────────────────────────────────────────────────


DEPS = handlers.AppleSignInDeps(keys=KEYS, audience=BUNDLE)


def sign_up_event(jwt: str, username: str, source: str = "PreSignUp_SignUp") -> dict[str, Any]:
    return {
        "triggerSource": source,
        "userName": "generated-uuid",
        "request": {
            "userAttributes": {"email": username},
            "clientMetadata": {"appleIdentityToken": jwt, "appleNonce": NONCE},
        },
        "response": {},
    }


def test_sign_up_with_a_genuine_token_is_confirmed_without_mail() -> None:
    event = auth_triggers.handle(sign_up_event(token(), apple.username_for(APPLE_SUB)), DEPS)
    assert event["response"] == {"autoConfirmUser": True, "autoVerifyEmail": True}


def test_sign_up_as_someone_elses_username_is_refused() -> None:
    """A genuine token for one Apple ID can't create the account of another."""
    with pytest.raises(AppleTokenRejected):
        auth_triggers.handle(sign_up_event(token(), apple.username_for("someone.else")), DEPS)


@pytest.mark.parametrize("source", ["PreSignUp_ExternalProvider", "PreSignUp_Unknown"])
def test_sign_up_by_any_other_route_is_refused(source: str) -> None:
    """The Hosted UI's federation is retired (INFRA-SPEC §3.5)."""
    with pytest.raises(AppleTokenRejected):
        auth_triggers.handle(sign_up_event(token(), apple.username_for(APPLE_SUB), source), DEPS)


def test_sign_up_without_a_token_is_refused() -> None:
    event = sign_up_event("", apple.username_for(APPLE_SUB))
    with pytest.raises(AppleTokenRejected):
        auth_triggers.handle(event, DEPS)


def test_an_operator_may_still_create_a_user() -> None:
    event = auth_triggers.handle(
        sign_up_event("", "someone@example.com", "PreSignUp_AdminCreateUser"), DEPS
    )
    assert event["response"] == {}


def define(session: list[dict[str, Any]]) -> dict[str, Any]:
    event = {"triggerSource": "DefineAuthChallenge_Authentication", "request": {"session": session}}
    return auth_triggers.handle(event, DEPS)["response"]


def test_define_issues_one_custom_challenge_then_tokens() -> None:
    assert define([]) == {"challengeName": "CUSTOM_CHALLENGE", "issueTokens": False, "failAuthentication": False}
    passed = [{"challengeName": "CUSTOM_CHALLENGE", "challengeResult": True}]
    assert define(passed)["issueTokens"] is True


@pytest.mark.parametrize(
    "session",
    [
        [{"challengeName": "CUSTOM_CHALLENGE", "challengeResult": False}],
        [{"challengeName": "SRP_A", "challengeResult": True}],
        [
            {"challengeName": "CUSTOM_CHALLENGE", "challengeResult": False},
            {"challengeName": "CUSTOM_CHALLENGE", "challengeResult": True},
        ],
    ],
)
def test_define_fails_anything_but_one_good_answer(session: list[dict[str, Any]]) -> None:
    response = define(session)
    assert response["failAuthentication"] is True
    assert response["issueTokens"] is False


def test_create_issues_no_secret() -> None:
    event = auth_triggers.handle(
        {"triggerSource": "CreateAuthChallenge_Authentication", "request": {}}, DEPS
    )
    assert event["response"]["privateChallengeParameters"] == {}


def verify_event(jwt: str, username: str) -> dict[str, Any]:
    return {
        "triggerSource": "VerifyAuthChallengeResponse_Authentication",
        "request": {
            "userAttributes": {"email": username},
            "challengeAnswer": jwt,
            "clientMetadata": {"appleNonce": NONCE},
        },
        "response": {},
    }


def test_verify_accepts_this_users_apple_token() -> None:
    event = auth_triggers.handle(verify_event(token(), apple.username_for(APPLE_SUB)), DEPS)
    assert event["response"]["answerCorrect"] is True


@pytest.mark.parametrize(
    "jwt, username",
    [
        (token(), apple.username_for("someone.else")),
        (token(key=OTHER_KEY), apple.username_for(APPLE_SUB)),
        ("garbage", apple.username_for(APPLE_SUB)),
    ],
)
def test_verify_rejects_without_raising(jwt: str, username: str) -> None:
    """A wrong answer is `answerCorrect = False`; a raise would put a stack
    trace in the phone's error instead of "sign-in failed"."""
    event = auth_triggers.handle(verify_event(jwt, username), DEPS)
    assert event["response"]["answerCorrect"] is False


# ── Revocation ───────────────────────────────────────────────────────────────


EC_KEY = ec.generate_private_key(ec.SECP256R1())
EC_PEM = EC_KEY.private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
).decode()


def test_the_client_secret_is_an_es256_jwt_apple_can_verify() -> None:
    secret = apple.client_secret("TEAM123", "KEY456", BUNDLE, EC_PEM, now=1_000_000)
    header_b64, claims_b64, signature_b64 = secret.split(".")
    header = json.loads(base64.urlsafe_b64decode(header_b64 + "=="))
    claims = json.loads(base64.urlsafe_b64decode(claims_b64 + "=="))
    assert header == {"alg": "ES256", "kid": "KEY456"}
    assert claims == {
        "iss": "TEAM123", "iat": 1_000_000, "exp": 1_000_300, "aud": apple.ISSUER, "sub": BUNDLE,
    }
    raw = base64.urlsafe_b64decode(signature_b64 + "==")
    assert len(raw) == 64  # r || s, not DER
    der = encode_dss_signature(int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big"))
    EC_KEY.public_key().verify(der, f"{header_b64}.{claims_b64}".encode(), ec.ECDSA(hashes.SHA256()))


class FakeAppleEndpoint:
    def __init__(self, token_status: int = 200, revoke_status: int = 200) -> None:
        self.token_status = token_status
        self.revoke_status = revoke_status
        self.calls: list[tuple[str, dict[str, str]]] = []

    def __call__(self, url: str, form: dict[str, str]) -> tuple[int, bytes]:
        self.calls.append((url, form))
        if url == apple.TOKEN_URL:
            if self.token_status != 200:
                return self.token_status, b'{"error":"invalid_grant"}'
            id_token = "h." + b64(json.dumps({"sub": APPLE_SUB}).encode()) + ".s"
            return 200, json.dumps(
                {"access_token": "at", "refresh_token": "rt", "id_token": id_token}
            ).encode()
        return self.revoke_status, b""


def test_revocation_exchanges_the_code_and_revokes_the_refresh_token() -> None:
    endpoint = FakeAppleEndpoint()
    revoker = apple.AppleRevoker(client_id=BUNDLE, secret=lambda: "secret", post=endpoint)

    assert revoker.revoke("the-code") == APPLE_SUB
    (token_url, exchange), (revoke_url, revocation) = endpoint.calls
    assert token_url == apple.TOKEN_URL
    assert exchange == {
        "client_id": BUNDLE, "client_secret": "secret", "code": "the-code",
        "grant_type": "authorization_code",
    }
    assert revoke_url == apple.REVOKE_URL
    assert revocation["token"] == "rt"
    assert revocation["token_type_hint"] == "refresh_token"


def test_a_refused_code_asks_for_another_confirmation() -> None:
    revoker = apple.AppleRevoker(BUNDLE, lambda: "secret", post=FakeAppleEndpoint(token_status=400))
    with pytest.raises(apple.AppleGrantUnusable):
        revoker.revoke("expired")


@pytest.mark.parametrize("endpoint", [FakeAppleEndpoint(token_status=503), FakeAppleEndpoint(revoke_status=500)])
def test_apple_being_down_is_a_failure_to_retry(endpoint: FakeAppleEndpoint) -> None:
    """Not "confirm again" — confirming again can't fix Apple being down."""
    with pytest.raises(RuntimeError):
        apple.AppleRevoker(BUNDLE, lambda: "secret", post=endpoint).revoke("code")
