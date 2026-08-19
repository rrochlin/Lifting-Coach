#!/usr/bin/env python3
"""Check Theme.swift's palette against WCAG 2.1 contrast minimums.

Parses the colour literals straight out of `Sources/App/Theme/Theme.swift` so
this can't drift from what actually ships, and fails loudly on a regression.

Three tokens were under the floor before anyone measured — including
`fieldEdge`, whose entire documented purpose was being visible in a gym. That's
the failure mode this guards: contrast is not something the eye audits reliably
on an already-dark palette, because everything looks intentional.

Usage:  python3 Tools/check-contrast.py
Exit:   0 all pass, 1 one or more below their floor.
"""

import re
import sys
from pathlib import Path

THEME = Path(__file__).resolve().parent.parent / "Sources/App/Theme/Theme.swift"

# Panels stack, so panelRaised is the brightest ground any ink sits on and
# therefore the worst case for contrast. Checking against it covers void and
# panel automatically.
GROUND = "panelRaised"

# WCAG 2.1 thresholds. See the doc comment on `enum Theme`.
AA_TEXT = 4.5       # 1.4.3 Contrast (Minimum)
AAA_TEXT = 7.0      # 1.4.6 Contrast (Enhanced)
UI_COMPONENT = 3.0  # 1.4.11 Non-text Contrast

# What each token owes, and why. A token absent here is unchecked on purpose.
REQUIREMENTS = {
    "ink":       (AAA_TEXT,     "primary text, and the lift data read over a bar"),
    "signal":    (AAA_TEXT,     "completion and focus, read mid-set"),
    "live":      (AAA_TEXT,     "the running rest clock, read across a room"),
    "inkMuted":  (AA_TEXT,      "secondary text, and the suggestion placeholder"),
    "inkFaint":  (AA_TEXT,      "annotation layer — set numbers, prescriptions"),
    "alert":     (AA_TEXT,      "errors and destructive actions"),
    "signalDim": (AA_TEXT,      "dimmed accent, used as text often enough"),
    "fieldEdge": (UI_COMPONENT, "the outline that says 'you can change this'"),
    # `hairline` is a decorative rule and is exempt under 1.4.1 — it is
    # deliberately felt rather than seen, and raising it would add visual noise
    # to every panel to satisfy a rule that does not apply to it.
}

LITERAL = re.compile(
    r"static let (\w+)\s*=\s*Color\(red:\s*([\d.]+),\s*green:\s*([\d.]+),\s*blue:\s*([\d.]+)\)"
)


def parse(source):
    return {m[1]: (float(m[2]), float(m[3]), float(m[4])) for m in LITERAL.finditer(source)}


def luminance(color):
    """WCAG relative luminance. Note these are sRGB values already in 0...1,
    which is how SwiftUI's `Color(red:green:blue:)` takes them."""
    def channel(v):
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(v) for v in color)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def main():
    colors = parse(THEME.read_text())

    missing = sorted(set(REQUIREMENTS) - set(colors))
    if GROUND not in colors or missing:
        print(f"could not find in Theme.swift: {missing or [GROUND]}", file=sys.stderr)
        return 1

    ground = colors[GROUND]
    failures = []

    # A hair of headroom, so a literal rounded to three decimals can't land a
    # fraction under its floor and fail a check it visually passes.
    print(f"WCAG 2.1 contrast against {GROUND} (worst-case ground)\n")
    for token, (floor, why) in sorted(REQUIREMENTS.items(), key=lambda kv: -kv[1][0]):
        measured = ratio(colors[token], ground)
        ok = measured >= floor
        print(f"  {'PASS' if ok else 'FAIL'}  {token:11} {measured:5.2f}:1  "
              f"(needs {floor}:1 — {why})")
        if not ok:
            failures.append((token, measured, floor))

    if failures:
        print(f"\n{len(failures)} below floor:", file=sys.stderr)
        for token, measured, floor in failures:
            print(f"  {token}: {measured:.2f}:1 < {floor}:1", file=sys.stderr)
        return 1

    print(f"\nall {len(REQUIREMENTS)} checked tokens meet their floor")
    return 0


if __name__ == "__main__":
    sys.exit(main())
