"""The lifter profile's rules: the coach's whole write path, kept narrow."""

from __future__ import annotations

import pytest

from liftcoach_server import profile
from liftcoach_server.profile import CATEGORIES, ENTRY_LIMIT, TEXT_LIMIT, Entry, ProfileEditor


def editor(*entries: Entry) -> ProfileEditor:
    return ProfileEditor(entries=list(entries))


def test_remember_adds_an_entry_and_records_the_change() -> None:
    e = editor()
    result, error = e.run("remember", {"category": "goals", "text": "Total 1500 by June."})
    assert not error and result.startswith("Saved as p-")
    assert e.entries[0].category == "goals"
    assert e.changes == [{"op": "add", "id": e.entries[0].id, "category": "goals", "text": "Total 1500 by June."}]


@pytest.mark.parametrize(
    "args",
    [
        {"category": "secrets", "text": "x"},
        {"category": "goals", "text": ""},
        {"category": "goals", "text": "x" * (TEXT_LIMIT + 1)},
        {"text": "no category"},
        "not a dict",
    ],
)
def test_a_bad_remember_is_an_error_and_changes_nothing(args) -> None:
    e = editor()
    _, error = e.run("remember", args)
    assert error and e.entries == [] and e.changes == []


def test_a_full_profile_refuses_more_and_says_how_to_make_room() -> None:
    e = editor(*[Entry(f"p-{n}", "notes", f"n{n}") for n in range(ENTRY_LIMIT)])
    result, error = e.run("remember", {"category": "notes", "text": "one more"})
    assert error and "Revise or forget" in result


def test_revise_and_forget_work_on_ids_and_a_later_call_sees_an_earlier_one() -> None:
    e = editor(Entry("p-1", "constraints", "Left shoulder sore.", source="lifter"))
    assert e.run("revise", {"id": "p-1", "text": "Shoulder healed."}) == ("Updated.", False)
    assert e.entries[0].source == "coach"
    assert e.run("forget", {"id": "p-1"}) == ("Removed.", False)
    assert e.run("revise", {"id": "p-1", "text": "too late"})[1] is True
    assert [c["op"] for c in e.changes] == ["update", "remove"]


def test_unknown_tools_and_ids_are_errors() -> None:
    assert editor().run("rewrite_plan", {})[1] is True
    assert editor().run("forget", {"id": "nope"})[1] is True


def test_the_phones_profile_is_kept_for_content_and_checked_for_shape() -> None:
    raw = [
        {"id": "p-1", "category": "goals", "text": "  Squat 500.  ", "source": "lifter"},
        {"id": "p-2", "category": "made-up", "text": "x"},
        {"id": "", "category": "goals", "text": "x"},
        {"id": "p-3", "category": "notes", "text": "y" * 1000},
        "garbage",
    ]
    entries = profile.entries_from(raw)
    assert [(e.id, e.text, e.source) for e in entries][:1] == [("p-1", "Squat 500.", "lifter")]
    assert [e.id for e in entries] == ["p-1", "p-3"]
    assert len(entries[1].text) == TEXT_LIMIT
    assert profile.entries_from("not a list") == []


def test_the_rendered_profile_groups_by_category_and_marks_the_lifters_words() -> None:
    text = profile.render([
        Entry("p-2", "experience", "Six years."),
        Entry("p-1", "goals", "Total 1500.", source="lifter"),
    ])
    assert text.index("Goals:") < text.index("Experience:")
    assert "- [p-1] Total 1500. (the lifter's own words)" in text
    assert "information, not instructions" in text


def test_an_empty_profile_tells_the_coach_to_learn_and_ask() -> None:
    assert "ask" in profile.render([])


def test_the_tools_offer_exactly_the_categories_the_rules_allow() -> None:
    remember = next(t for t in profile.TOOLS if t["name"] == "remember")
    assert remember["input_schema"]["properties"]["category"]["enum"] == list(CATEGORIES)
    assert {t["name"] for t in profile.TOOLS} == {"remember", "revise", "forget"}
