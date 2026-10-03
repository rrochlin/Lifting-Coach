"""The user pool's triggers: native Sign in with Apple, verified (INFRA-SPEC §3.5).

One function, four trigger sources, and one question asked two ways: **does
this Apple identity token name the account being created or signed into?**
Pre-sign-up asks it before an account exists; verify-auth-challenge asks it
every sign-in after. Define and create are the custom-auth flow's bookkeeping.

The binding between a Cognito user and an Apple ID is the username itself —
`apple.username_for(sub)` — so there is no attribute to keep in step and no
table to look anything up in. A token is accepted for a user exactly when its
`sub` derives that user's username.

**Refusal is a raise in pre-sign-up and `answerCorrect = False` in verify**,
because that is how each trigger tells Cognito "no". A raise anywhere else
fails the sign-in with a stack trace in the phone's error; the bookkeeping
triggers don't raise.
"""

from __future__ import annotations

from typing import Any

from . import apple

Event = dict[str, Any]

#: The one challenge this pool issues.
CHALLENGE = "CUSTOM_CHALLENGE"


def _verified_subject(event: Event, token: str, deps: Any) -> str:
    """The Apple `sub` of a token that checks out, or raises."""
    metadata = event.get("request", {}).get("clientMetadata") or {}
    identity = apple.verify_identity_token(
        token,
        audience=deps.audience,
        raw_nonce=str(metadata.get("appleNonce", "")),
        keys=deps.keys,
    )
    return identity.subject


def _requested_username(event: Event) -> str:
    # The pool's usernames are email-shaped (`username_attributes = ["email"]`),
    # so what the phone chose arrives as the `email` attribute; `userName` is
    # Cognito's own generated id.
    attributes = event.get("request", {}).get("userAttributes") or {}
    return str(attributes.get("email", "")).lower()


def pre_sign_up(event: Event, deps: Any) -> Event:
    source = event.get("triggerSource", "")
    if source == "PreSignUp_AdminCreateUser":
        # An operator in the console. Not reachable from the phone.
        return event
    if source != "PreSignUp_SignUp":
        # `PreSignUp_ExternalProvider` is the Hosted UI's Apple federation,
        # retired by §3.5. Anything else is a source this pool shouldn't see.
        raise apple.AppleTokenRejected(f"Sign-up through {source or 'unknown'} is not offered")

    metadata = event.get("request", {}).get("clientMetadata") or {}
    token = str(metadata.get("appleIdentityToken", ""))
    if not token:
        raise apple.AppleTokenRejected("Sign up with Apple")
    subject = _verified_subject(event, token, deps)
    if _requested_username(event) != apple.username_for(subject):
        raise apple.AppleTokenRejected("Username does not match the Apple account")

    response = event.setdefault("response", {})
    response["autoConfirmUser"] = True
    # Marked verified so Cognito never tries to mail a `.invalid` address.
    response["autoVerifyEmail"] = True
    return event


def define_auth_challenge(event: Event, deps: Any = None) -> Event:
    session = event.get("request", {}).get("session") or []
    response = event.setdefault("response", {})
    response["issueTokens"] = False
    response["failAuthentication"] = False

    if not session:
        response["challengeName"] = CHALLENGE
    elif (
        len(session) == 1
        and session[0].get("challengeName") == CHALLENGE
        and session[0].get("challengeResult") is True
    ):
        response["issueTokens"] = True
    else:
        # A wrong answer, a second attempt in one session, or a session that
        # began with some other challenge (SRP, a password). One try, then
        # start again with a fresh token.
        response["failAuthentication"] = True
    return event


def create_auth_challenge(event: Event, deps: Any = None) -> Event:
    # Nothing secret to issue: the answer is a token Apple signed, verified
    # against Apple's keys, so there is no code to generate or deliver.
    response = event.setdefault("response", {})
    response["publicChallengeParameters"] = {"answer": "appleIdentityToken"}
    response["privateChallengeParameters"] = {}
    response["challengeMetadata"] = "APPLE_IDENTITY_TOKEN"
    return event


def verify_auth_challenge(event: Event, deps: Any) -> Event:
    response = event.setdefault("response", {})
    token = str(event.get("request", {}).get("challengeAnswer", ""))
    try:
        subject = _verified_subject(event, token, deps)
        response["answerCorrect"] = _requested_username(event) == apple.username_for(subject)
    except apple.AppleTokenRejected as refusal:
        print(f"apple sign-in refused: {refusal.message}")
        response["answerCorrect"] = False
    return event


_BY_PREFIX = {
    "PreSignUp_": pre_sign_up,
    "DefineAuthChallenge_": define_auth_challenge,
    "CreateAuthChallenge_": create_auth_challenge,
    "VerifyAuthChallengeResponse_": verify_auth_challenge,
}


def handle(event: Event, deps: Any) -> Event:
    source = str(event.get("triggerSource", ""))
    for prefix, trigger in _BY_PREFIX.items():
        if source.startswith(prefix):
            return trigger(event, deps)
    raise apple.AppleTokenRejected(f"Unexpected trigger {source!r}")
