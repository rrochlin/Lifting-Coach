"""Sign in with Apple, from the server's side: verify a token, revoke a grant.

INFRA-SPEC §3.5. The phone signs in natively and hands Cognito an identity
token Apple signed; the custom-auth triggers (`auth_triggers.py`) decide
whether to believe it, and this module is how. At deletion, the phone hands
over a fresh authorization code and this module revokes the app's grant —
Apple's rule for any app offering Sign in with Apple.

**`cryptography` does the cryptography.** RS256 verification and ES256 signing
are primitives, and this project's line is that we don't write those. It is
imported inside the functions that need it, so the indexer — which shares this
package and never verifies anything — doesn't pay for the import.

**Who an Apple user is, here, is their Apple `sub`**, carried in the Cognito
username (`username_for`). Not their email: an Apple ID's address can change,
and an account keyed on it would change owner with it.
"""

from __future__ import annotations

import base64
import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Protocol

from .errors import ServiceError

ISSUER = "https://appleid.apple.com"
KEYS_URL = "https://appleid.apple.com/auth/keys"
TOKEN_URL = "https://appleid.apple.com/auth/token"
REVOKE_URL = "https://appleid.apple.com/auth/revoke"

#: The domain of every Cognito username, and the one string the phone and the
#: server must agree on — `UserPoolAuth.usernameDomain` in LiftingCoachCloud,
#: pinned by a test that reads the Swift. `.invalid` is reserved (RFC 2606):
#: these addresses can never receive mail or collide with a real one.
USERNAME_DOMAIN = "apple.lift-coach.invalid"


class AppleTokenRejected(ServiceError):
    """An identity token that doesn't prove what it claims to."""


class AppleGrantUnusable(ServiceError):
    """Apple refused the authorization code: expired (five minutes), already
    used, or for a different app. The phone's answer is to confirm again."""


def username_for(apple_subject: str) -> str:
    """The Cognito username for an Apple user. Lowercased because the pool's
    usernames are case-insensitive and Apple's `sub` is already lowercase hex
    and dots — so this is a normalisation that should never change anything."""
    if not apple_subject or "@" in apple_subject:
        raise AppleTokenRejected("Apple token has no usable subject")
    return f"{apple_subject.lower()}@{USERNAME_DOMAIN}"


def subject_from_username(username: str) -> str | None:
    """The Apple `sub` a username was derived from, or `None` for a user that
    didn't come from native Sign in with Apple (an operator-created one)."""
    local, _, domain = username.lower().rpartition("@")
    return local if domain == USERNAME_DOMAIN and local else None


@dataclass(frozen=True)
class AppleIdentity:
    subject: str
    email: str


# ── JWT plumbing ─────────────────────────────────────────────────────────────


def _b64url_decode(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unverified_claims(jwt: str) -> dict[str, Any]:
    """A JWT's payload, *not* verified. Only for a token that arrived from
    Apple over TLS in reply to our own request (`AppleRevoker`)."""
    try:
        return json.loads(_b64url_decode(jwt.split(".")[1]))
    except (IndexError, ValueError) as exc:
        raise AppleTokenRejected("Not a JWT") from exc


class AppleKeys(Protocol):
    """Apple's current signing keys, by `kid`."""

    def public_key(self, kid: str) -> Any:
        """An RSA public key, or raises `AppleTokenRejected` for an unknown kid."""
        ...


class HttpAppleKeys:
    """Fetches Apple's JWKS, cached for the life of the container.

    Refetched once on an unknown `kid`, which is what a key rotation looks like
    from here: the token is signed by a key published after the cache filled.
    """

    def __init__(self, url: str = KEYS_URL, timeout: float = 2.0) -> None:
        self._url = url
        self._timeout = timeout
        self._keys: dict[str, Any] = {}

    def _refresh(self) -> None:
        from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers

        with urllib.request.urlopen(self._url, timeout=self._timeout) as response:
            document = json.load(response)
        keys = {}
        for jwk in document.get("keys", []):
            if jwk.get("kty") != "RSA":
                continue
            n = int.from_bytes(_b64url_decode(jwk["n"]), "big")
            e = int.from_bytes(_b64url_decode(jwk["e"]), "big")
            keys[jwk["kid"]] = RSAPublicNumbers(e, n).public_key()
        self._keys = keys

    def public_key(self, kid: str) -> Any:
        if kid not in self._keys:
            self._refresh()
        if kid not in self._keys:
            raise AppleTokenRejected(f"Unknown Apple signing key {kid!r}")
        return self._keys[kid]


def verify_identity_token(
    token: str,
    audience: str,
    raw_nonce: str,
    keys: AppleKeys,
    now: float | None = None,
) -> AppleIdentity:
    """Checks an identity token the way Apple says to, and returns who it names.

    Signature (RS256, against the published key named by `kid`), `iss`, `aud`
    (the bundle id — a token minted for some other app is refused), `exp`, and
    the nonce: the phone asked Apple to embed `SHA-256(raw_nonce)`, so a token
    replayed from another sign-in carries a nonce nobody here knows the
    preimage of.
    """
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding

    parts = token.split(".")
    if len(parts) != 3:
        raise AppleTokenRejected("Not a JWT")
    try:
        header = json.loads(_b64url_decode(parts[0]))
        claims = json.loads(_b64url_decode(parts[1]))
        signature = _b64url_decode(parts[2])
    except ValueError as exc:
        raise AppleTokenRejected("Malformed JWT") from exc

    # Pinned, never read from the header: "alg": "none" and HS256-with-the-
    # public-key are the classic ways a verifier is talked out of verifying.
    if header.get("alg") != "RS256":
        raise AppleTokenRejected(f"Unexpected algorithm {header.get('alg')!r}")
    key = keys.public_key(str(header.get("kid", "")))
    try:
        key.verify(
            signature,
            f"{parts[0]}.{parts[1]}".encode("ascii"),
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
    except InvalidSignature as exc:
        raise AppleTokenRejected("Bad signature") from exc

    if claims.get("iss") != ISSUER:
        raise AppleTokenRejected("Wrong issuer")
    if claims.get("aud") != audience:
        raise AppleTokenRejected("Token is for a different app")
    current = time.time() if now is None else now
    if float(claims.get("exp", 0)) < current:
        raise AppleTokenRejected("Token expired")
    expected_nonce = hashlib.sha256(raw_nonce.encode("utf-8")).hexdigest()
    if not raw_nonce or claims.get("nonce") != expected_nonce:
        raise AppleTokenRejected("Nonce mismatch")

    return AppleIdentity(subject=str(claims.get("sub", "")), email=str(claims.get("email", "")))


# ── Revocation ───────────────────────────────────────────────────────────────


class AppleGrants(Protocol):
    """Apple's token endpoint, as account deletion uses it."""

    def revoke(self, authorization_code: str) -> str:
        """Exchanges the code, revokes the grant, returns the Apple `sub` it
        belonged to. Raises `AppleGrantUnusable` if Apple refuses the code."""
        ...


def client_secret(
    team_id: str, key_id: str, client_id: str, private_key_pem: str, now: float | None = None
) -> str:
    """The ES256 JWT Apple takes in place of a client secret.

    Five minutes is plenty — it's minted for one exchange and one revoke — and
    the shortest lifetime is the least a leaked one is worth.
    """
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    issued = int(time.time() if now is None else now)
    header = {"alg": "ES256", "kid": key_id}
    claims = {"iss": team_id, "iat": issued, "exp": issued + 300, "aud": ISSUER, "sub": client_id}
    signing_input = (
        _b64url_encode(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url_encode(json.dumps(claims, separators=(",", ":")).encode())
    )
    key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
    der = key.sign(signing_input.encode("ascii"), ec.ECDSA(hashes.SHA256()))
    # JWS wants r || s, 32 bytes each; `cryptography` returns DER.
    r, s = decode_dss_signature(der)
    return signing_input + "." + _b64url_encode(r.to_bytes(32, "big") + s.to_bytes(32, "big"))


Post = Any  # (url, form) -> (status, body bytes)


def _urllib_post(url: str, form: dict[str, str]) -> tuple[int, bytes]:
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(form).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


class AppleRevoker:
    """Exchanges an authorization code and revokes the resulting grant."""

    def __init__(
        self,
        client_id: str,
        secret: Any,  # () -> str, minted per call
        post: Post = _urllib_post,
    ) -> None:
        self._client_id = client_id
        self._secret = secret
        self._post = post

    def revoke(self, authorization_code: str) -> str:
        secret = self._secret()
        status, body = self._post(
            TOKEN_URL,
            {
                "client_id": self._client_id,
                "client_secret": secret,
                "code": authorization_code,
                "grant_type": "authorization_code",
            },
        )
        if status == 400:
            # `invalid_grant`: expired, used, or not ours. Apple's error body
            # is a code, not a credential, so it is safe to carry.
            raise AppleGrantUnusable(f"Apple refused the code: {body[:200]!r}")
        if status != 200:
            raise RuntimeError(f"Apple token endpoint answered {status}")
        reply = json.loads(body)
        subject = str(unverified_claims(str(reply.get("id_token", ""))).get("sub", ""))

        # The refresh token is the grant; revoking it ends the app's
        # authorisation for this Apple ID, which is what Apple asks for.
        token = reply.get("refresh_token") or reply.get("access_token")
        hint = "refresh_token" if reply.get("refresh_token") else "access_token"
        status, _ = self._post(
            REVOKE_URL,
            {
                "client_id": self._client_id,
                "client_secret": secret,
                "token": str(token),
                "token_type_hint": hint,
            },
        )
        if status != 200:
            raise RuntimeError(f"Apple revoke endpoint answered {status}")
        return subject
