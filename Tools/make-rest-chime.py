#!/usr/bin/env python3
"""Synthesizes the rest-complete chime.

Generated rather than vendored, for the same reason `make-app-icon.swift` is:
nothing has to be licensed, downloaded or explained, and the thing that decides
what it sounds like is readable and re-runnable.

    python3 Tools/make-rest-chime.py

Writes `Sources/App/Resources/rest-complete.wav`, which `RestChime` plays.

**Why an asset at all, when a system sound is one line.** `RestChime` used to
call `AudioServicesPlaySystemSound(1005)`, and the report from the gym was that
the sound either didn't fire or was "wayyyyy too quiet". Both are the same
cause: system sounds are routed by the system, *not* through the app's
`AVAudioSession`, so the `.playback` category that is supposed to make rest
audible through the silent switch does nothing for them — on a silenced phone
they are simply dropped. Playing our own file through `AVAudioPlayer` is what
actually honours `.playback`, and it also means the volume is ours to set.

**Three rising beeps, not one.** A single soft ding is what was there and it
lost to a gym. A short repeated pattern is what every interval timer uses,
because repetition is what makes a sound findable when you weren't listening
for it.
"""

import math
import struct
import wave
from pathlib import Path

RATE = 44_100
# A-ish major triad rising. High enough to cut through low-frequency gym noise
# (fans, plates, bass) without being shrill on a phone speaker.
NOTES = [880.0, 1174.7, 1567.98]
NOTE_SECONDS = 0.11
GAP_SECONDS = 0.055
# Headroom below full scale: the sum of a fundamental and its harmonic clips
# otherwise, and a clipped chime sounds broken rather than loud.
PEAK = 0.86


def envelope(position, length):
    """Fast attack, smooth decay. A click at the start is what makes a beep
    audible; a click at the end is what makes it sound like a defect."""
    attack = int(0.006 * RATE)
    if position < attack:
        return position / attack
    remaining = (length - position) / max(1, length - attack)
    return remaining ** 1.6


def note(frequency):
    length = int(NOTE_SECONDS * RATE)
    samples = []
    for i in range(length):
        t = i / RATE
        # Fundamental plus a quiet octave: a pure sine reads as soft even at
        # full scale, and the harmonic is what gives it an edge to notice.
        value = math.sin(2 * math.pi * frequency * t)
        value += 0.32 * math.sin(4 * math.pi * frequency * t)
        samples.append(value / 1.32 * envelope(i, length) * PEAK)
    return samples


def main():
    silence = [0.0] * int(GAP_SECONDS * RATE)
    samples = []
    for index, frequency in enumerate(NOTES):
        if index:
            samples.extend(silence)
        samples.extend(note(frequency))
    # A few ms of true silence at the tail so the file never ends mid-cycle.
    samples.extend([0.0] * int(0.02 * RATE))

    out = Path(__file__).resolve().parent.parent / "Sources/App/Resources/rest-complete.wav"
    with wave.open(str(out), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        ))
    print(f"wrote {out} ({out.stat().st_size / 1024:.0f} KB, "
          f"{len(samples) / RATE:.2f}s)")


if __name__ == "__main__":
    main()
