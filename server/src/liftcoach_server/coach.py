"""The coach: one message in, one reply out (INFRA-SPEC §13).

Send and receive rather than live chat. The phone invokes `coach_reply` with
its message, its own id for that message, and the recent conversation; this
answers it with Claude on Bedrock and returns the reply whole.

**The one rule that shapes the module: a message is answered at most once.**
The phone re-sends anything it didn't hear back about — after the app was
killed, after a timeout, after a dead network — with the same id. So the
reply is recorded under `(sub, messageId)` *before* it's returned, and a
request for an id already answered gets the recorded reply back without
calling the model. A lost response costs a retry; never a second charge, and
never a second, different answer to the same question.

**The conversation is not stored here.** It lives on the phone (and so in the
snapshot); the phone sends the recent history with each message. The reply
store is an idempotency cache with a TTL, not a record of anything.

Like the rest of the package, AWS and the model sit behind narrow protocols
(`ReplyStore`, `CoachModel`) so the policy is tested without either.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Any, Protocol

from . import log_tools, profile
from .accounts import Accounts, InvalidToken
from .errors import ServiceError

#: How much conversation goes to the model with each message. The whole
#: conversation stays on the phone; this keeps a long one's cost flat.
HISTORY_LIMIT = 40
#: Longest message accepted, in characters — a question about training, not
#: a document. The phone enforces the same limit as it's typed.
MESSAGE_LIMIT = 4000
#: How long an answered message's reply is kept for re-delivery.
REPLY_TTL_SECONDS = 7 * 24 * 3600

_MESSAGE_ID = re.compile(r"^[A-Za-z0-9-]{8,64}$")

#: The coach's standing instructions. Static on purpose — nothing per-request,
#: no date, no id — so it can be cached, and so what the coach is told is the
#: same for every message and readable here in one place.
#:
#: The rules in it are the Core Tenets a coach is most likely to break
#: (`notes/Workout App/Core Tenets.md`), stated as instructions.
SYSTEM_PROMPT = """You are the coach in Lifting Coach, an iPhone app a powerlifter uses to plan and log their training. You talk with the lifter about their training: programming, technique cues, recovery, how to read a session, how to adjust.

How this app works, and the rules you keep:

- You advise; you never act. You cannot change the lifter's plan, their logged workouts, or any setting, and you must never say or imply that you have. When a change makes sense, say what you would change and why, and leave the decision to the lifter. Adjusting a program is the lifter's call.
- RPE in this app is exertion: how hard the set was, 1 to 10, in half steps. It is not reps in reserve. Never translate an RPE into "reps left in the tank", and don't use RIR. If the lifter asks how many reps they had left, explain in a sentence that RPE here records how hard the set felt rather than a rep count, then answer the question underneath it in terms of effort.
- Load and effort are separate axes of a prescription. "5 × 3 at 80%" and "5 × 3 at RPE 8" are different instructions; don't merge them.
- There are three different maxes and they are never interchangeable: an achieved max (the heaviest weight the lifter actually lifted), a goal max (the number a program is written against), and a theoretical max (an estimate). Say which one you mean.
- You can read the lifter's training log with the log tools — training_overview first, then exercise_history, recent_workouts, maxes and the rest. Use them whenever an answer depends on what they've actually done, rather than asking for numbers the log already has. The log is a backup that may be a little behind; when recency matters, say how current it is. Never invent numbers, sessions or history the tools didn't show you. A plain "I don't know" is better than a confident guess.
- You keep a profile of this lifter — their goals, experience, constraints and preferences — shown below, and you can change it with the remember, revise and forget tools. Update it when you learn something durable that will change how you coach them, so you don't have to ask again. You don't need to announce it; the app shows the lifter what you noted. The profile is the only thing your tools can change; the log tools only read.

Keep replies short enough to read between sets: lead with the answer, then the reasoning if it's needed. Use plain text. A short list is fine; headings are not."""


class MessageRejected(ServiceError):
    """A request this function won't answer as sent: no id, no text, too long.
    Not retried by the phone — sending it again wouldn't change it."""


class ModelUnavailable(ServiceError):
    """The model or the network failed. The phone keeps the message pending
    and tries again; nothing is recorded, so the retry is a fresh attempt."""


@dataclass(frozen=True)
class Reply:
    id: str
    text: str
    created_at: str
    #: Profile changes the coach made in this turn, for the phone to apply
    #: (`profile.ProfileEditor.changes`). Stored with the reply, so a
    #: re-delivered reply carries exactly the same changes.
    memory: tuple[dict[str, str], ...] = ()

    def as_body(self) -> dict[str, Any]:
        return {"id": self.id, "text": self.text, "createdAt": self.created_at,
                "memory": list(self.memory)}


@dataclass(frozen=True)
class Answered:
    reply: Reply
    #: True when the reply came from the store: a re-sent message.
    redelivered: bool
    usage: dict[str, int] | None = None


@dataclass(frozen=True)
class ModelAnswer:
    text: str
    refused: bool = False
    #: Token counts, for the log line. Never the text.
    usage: dict[str, int] | None = None


@dataclass
class Toolbox:
    """Everything the coach can call in one turn: the profile tools, which
    record changes for the phone, and the log tools, which only read."""

    editor: profile.ProfileEditor
    log: log_tools.LogReader | None = None

    @property
    def tools(self) -> list[dict[str, Any]]:
        return profile.TOOLS + (log_tools.TOOLS if self.log is not None else [])

    def run(self, name: str, tool_input: Any) -> tuple[str, bool]:
        if self.log is not None and name in log_tools.NAMES:
            return self.log.run(name, tool_input)
        return self.editor.run(name, tool_input)


class CoachModel(Protocol):
    def answer(
        self, system: str, profile_text: str, messages: list[dict[str, str]],
        toolbox: Toolbox,
    ) -> ModelAnswer:
        """Runs the turn, calling `toolbox.run` for each tool call.
        Raises `ModelUnavailable` for anything a retry might fix."""
        ...


class ReplyStore(Protocol):
    """Answered messages, keyed by `(sub, messageId)`. A cache with a TTL."""

    def get(self, subject: str, message_id: str) -> Reply | None: ...

    def put(self, subject: str, message_id: str, reply: Reply, expires_at: int) -> None: ...

    def delete_all(self, subject: str) -> int:
        """Everything for one account — account deletion (§9.4)."""
        ...


class InMemoryReplyStore:
    def __init__(self) -> None:
        self.items: dict[tuple[str, str], tuple[Reply, int]] = {}

    def get(self, subject: str, message_id: str) -> Reply | None:
        found = self.items.get((subject, message_id))
        return found[0] if found else None

    def put(self, subject: str, message_id: str, reply: Reply, expires_at: int) -> None:
        self.items[(subject, message_id)] = (reply, expires_at)

    def delete_all(self, subject: str) -> int:
        doomed = [key for key in self.items if key[0] == subject]
        for key in doomed:
            del self.items[key]
        return len(doomed)


#: What the lifter sees when the model declines. Bedrock has no server-side
#: fallback, so this stands in rather than an empty bubble.
REFUSAL_TEXT = "I can't help with that one. Ask me something else about your training?"


_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _today_line(today: Any, now: float | None) -> str:
    """"Today is …", from the phone's local date when it sent one — the
    lifter's day, not UTC's — else the server's."""
    import datetime

    value = str(today or "")
    try:
        day = datetime.date.fromisoformat(value) if _DATE.match(value) else None
    except ValueError:
        day = None
    if day is None:
        day = datetime.datetime.fromtimestamp(time.time() if now is None else now, datetime.UTC).date()
    return f"Today is {day.strftime('%A')}, {day.isoformat()} (the lifter's date)."


def conversation(history: Any, text: str) -> list[dict[str, str]]:
    """The messages to send: the recent history, cleaned, then this message.

    The phone's history is trusted for *content* — it's the lifter's own
    conversation — but not for *shape*, because the model requires one: roles
    alternate, the first is the user's, and nothing is empty. A message whose
    reply never arrived leaves two user turns in a row; they're joined rather
    than dropped, since both were said.
    """
    turns: list[dict[str, str]] = []
    for item in (history if isinstance(history, list) else [])[-HISTORY_LIMIT:]:
        if not isinstance(item, dict):
            continue
        role = item.get("role")
        body = str(item.get("text") or "").strip()
        if role not in ("user", "assistant") or not body:
            continue
        if turns and turns[-1]["role"] == role:
            turns[-1]["content"] += "\n\n" + body
        else:
            turns.append({"role": role, "content": body})
    while turns and turns[0]["role"] != "user":
        turns.pop(0)

    if turns and turns[-1]["role"] == "user":
        turns[-1]["content"] += "\n\n" + text
    else:
        turns.append({"role": "user", "content": text})
    return turns


def answer(
    access_token: str,
    message_id: str,
    text: str,
    history: Any,
    accounts: Accounts,
    store: ReplyStore,
    model: CoachModel,
    memory: Any = None,
    today: Any = None,
    snapshots: Any = None,
    time_zone: Any = None,
    now: float | None = None,
) -> Answered:
    """Answers one message, at most once. See the module docstring.

    Raises `InvalidToken` (sign in again), `MessageRejected` (don't resend),
    or `ModelUnavailable` (resend later).
    """
    if not access_token:
        raise InvalidToken("No access token")
    if not _MESSAGE_ID.match(message_id or ""):
        raise MessageRejected("Message needs an id")
    text = (text or "").strip()
    if not text:
        raise MessageRejected("Empty message")
    if len(text) > MESSAGE_LIMIT:
        raise MessageRejected(f"Message longer than {MESSAGE_LIMIT} characters")

    subject = accounts.user(access_token).subject

    # Answered already: the phone didn't hear back the first time.
    if (stored := store.get(subject, message_id)) is not None:
        return Answered(reply=stored, redelivered=True)

    entries = profile.entries_from(memory)
    editor = profile.ProfileEditor(entries=list(entries))
    # The date goes with the profile, not in the cached rules: without it "a
    # meet next June" was recorded as the June already past.
    context = f"{_today_line(today, now)}\n\n{profile.render(entries)}"
    log = None
    if snapshots is not None:
        # Fetched only if the coach asks, for this verified subject only.
        log = log_tools.LogReader(lambda: snapshots.fetch(subject), str(time_zone or "") or None)
    toolbox = Toolbox(editor=editor, log=log)
    try:
        result = model.answer(SYSTEM_PROMPT, context, conversation(history, text), toolbox)
    finally:
        if log is not None:
            log.close()
    current = time.time() if now is None else now
    reply = Reply(
        # Derived from the message's own id, so the phone can tell which
        # reply answers which message — and a re-delivered reply carries the
        # same id it did the first time.
        id=f"{message_id}-reply",
        text=REFUSAL_TEXT if result.refused or not result.text.strip() else result.text.strip(),
        created_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(current)),
        memory=tuple(editor.changes),
    )
    store.put(subject, message_id, reply, expires_at=int(current) + REPLY_TTL_SECONDS)
    return Answered(reply=reply, redelivered=False, usage=result.usage)


class BedrockCoach:
    """Claude on Bedrock, through Anthropic's SDK (`AnthropicBedrock`).

    Signs with the Lambda role's own credentials — no API key anywhere. The
    model is whatever `COACH_MODEL` names (INFRA-SPEC §13: Opus 4.5 today, the
    best Claude this account can call), so moving to a newer one is a
    configuration change.
    """

    MAX_TOKENS = 8000
    #: Adaptive thinking (Sonnet 4.6 and later decide how much to think) at
    #: medium effort: a coaching answer wants more than chat and less than
    #: an agent. Re-tune on real use.
    EFFORT = "medium"

    def __init__(self, model_id: str, region: str, client: Any | None = None) -> None:
        self._model_id = model_id
        self._region = region
        self._client = client

    @property
    def client(self) -> Any:
        if self._client is None:
            from anthropic import AnthropicBedrock

            # The SDK retries 429/5xx/connection errors twice by itself; the
            # timeout leaves room inside the function's own 120 s.
            self._client = AnthropicBedrock(aws_region=self._region, timeout=90.0)
        return self._client

    #: Tool rounds per turn. A turn that is still calling tools after this
    #: is answered with whatever text it has, rather than looping. Reading a
    #: log takes a few: an overview, then a lift's history or two.
    MAX_TOOL_ROUNDS = 6

    def answer(
        self, system: str, profile_text: str, messages: list[dict[str, str]],
        toolbox: Toolbox,
    ) -> ModelAnswer:
        import anthropic

        turn: list[dict[str, Any]] = [dict(m) for m in messages]
        usage = {"input": 0, "output": 0, "cacheRead": 0}
        # Text from every round, not just the last: the coach often writes
        # the first half of its answer, calls a tool, and carries on — keeping
        # only the final round's text cut replies off mid-thought.
        texts: list[str] = []
        refused = False
        for _ in range(self.MAX_TOOL_ROUNDS + 1):
            try:
                response = self.client.messages.create(
                    model=self._model_id,
                    max_tokens=self.MAX_TOKENS,
                    thinking={"type": "adaptive"},
                    output_config={"effort": self.EFFORT},
                    # The static rules carry the breakpoint (Bedrock rejects
                    # top-level automatic caching); the profile comes after it,
                    # so a changed profile doesn't invalidate the static part.
                    system=[
                        {"type": "text", "text": system, "cache_control": {"type": "ephemeral"}},
                        {"type": "text", "text": profile_text},
                    ],
                    tools=toolbox.tools,
                    messages=turn,
                )
            except anthropic.BadRequestError as error:
                raise MessageRejected(f"Model rejected the request: {error.message}") from None
            except (anthropic.APIStatusError, anthropic.APIConnectionError) as error:
                raise ModelUnavailable(f"Model unavailable: {type(error).__name__}") from None

            usage["input"] += int(response.usage.input_tokens or 0)
            usage["output"] += int(response.usage.output_tokens or 0)
            usage["cacheRead"] += int(getattr(response.usage, "cache_read_input_tokens", 0) or 0)
            round_text = "".join(block.text for block in response.content if block.type == "text").strip()
            if round_text:
                texts.append(round_text)
            refused = response.stop_reason == "refusal"

            calls = [block for block in response.content if block.type == "tool_use"]
            if response.stop_reason != "tool_use" or not calls:
                break
            # The assistant turn goes back whole — thinking blocks included,
            # unchanged, as a tool loop with thinking requires — and every
            # result goes back in one user message.
            turn.append({"role": "assistant", "content": response.content})
            results = []
            for call in calls:
                result, is_error = toolbox.run(call.name, call.input)
                results.append({"type": "tool_result", "tool_use_id": call.id, "content": result,
                                "is_error": is_error})
            turn.append({"role": "user", "content": results})

        return ModelAnswer(text="\n\n".join(texts), refused=refused, usage=usage)
