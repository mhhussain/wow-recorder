#!/usr/bin/env python3
"""
Build small, deterministic excerpts of the real combat logs in
tests/fixtures/combatlogs/ for fast unit tests (tests/fixtures/excerpts/).

Kept lines:
  - every event that starts, ends or segments an activity, plus player deaths
    and COMBATANT_INFO (specs, teams);
  - the first SELF_BUDGET aura/cast lines from the logging player after each
    start event, which is how the handlers learn the player's GUID and name;
  - Holy Priest "Restitution" auras (spell 211319), which count as deaths.

Boss health tracking (SPELL_DAMAGE etc.) is not preserved; tests that need
it run against the full logs.

Usage: python3 tests/fixtures/make_excerpts.py
"""

import os

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "combatlogs")
DST = os.path.join(ROOT, "excerpts")

SCENARIOS = {
    "retail": [
        "raid_wipe",
        "raid_reset",
        "raid_unknown_encounter",
        "raid_holy_priest_angel_death",
        "beloren_boss_hp",
        "coiled_altar_boss_hp",
        "mythic_plus",
        "mythic_plus_drop_go",
        "mythic_plus_repair",
        "mythic_plus_no_boss",
        "mythic_plus_ditch_into_raid",
        "zone_changes",
    ],
    "classic": ["raid", "mop_challenge_mode"],
    "era": ["raid"],
}

KEEP = {
    "COMBAT_LOG_VERSION",
    "ZONE_CHANGE",
    "MAP_CHANGE",
    "ENCOUNTER_START",
    "ENCOUNTER_END",
    "CHALLENGE_MODE_START",
    "CHALLENGE_MODE_END",
    "ARENA_MATCH_START",
    "ARENA_MATCH_END",
    "COMBATANT_INFO",
    "WARCRAFT_RECORDER_FORCE_STOP",
}

STARTS = {"ENCOUNTER_START", "CHALLENGE_MODE_START", "ZONE_CHANGE", "ARENA_MATCH_START"}
SELF_EVENTS = {"SPELL_AURA_APPLIED", "SPELL_CAST_SUCCESS"}
SELF_BUDGET = 20

AFFILIATION_MINE = 0x1
REACTION_FRIENDLY = 0x10
PLAYER = 0x100 | 0x400


def event_of(line):
    try:
        return line.split("  ", 1)[1].split(",", 1)[0].strip()
    except IndexError:
        return ""


def flags(value):
    try:
        return int(value, 16)
    except ValueError:
        return 0


def excerpt(path):
    out = []
    budget = 0

    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            event = event_of(line)

            if event in KEEP:
                out.append(line)
                if event in STARTS:
                    budget = SELF_BUDGET
                continue

            parts = line.split(",")

            if event == "UNIT_DIED" and len(parts) > 7:
                if flags(parts[7]) & PLAYER == PLAYER:
                    out.append(line)
                continue

            if event in SELF_EVENTS and len(parts) > 9:
                if event == "SPELL_AURA_APPLIED" and parts[9] == "211319":
                    out.append(line)
                    continue

                src = flags(parts[3])
                is_self = src & (AFFILIATION_MINE | REACTION_FRIENDLY) == (
                    AFFILIATION_MINE | REACTION_FRIENDLY
                )
                if is_self and budget > 0:
                    out.append(line)
                    budget -= 1

    return out


def main():
    for flavour, names in SCENARIOS.items():
        os.makedirs(os.path.join(DST, flavour), exist_ok=True)
        for name in names:
            src = os.path.join(SRC, flavour, f"{name}.txt")
            dst = os.path.join(DST, flavour, f"{name}.txt")
            lines = excerpt(src)
            with open(dst, "w", encoding="utf-8") as f:
                f.writelines(lines)
            print(f"{flavour}/{name}: {len(lines)} lines, {os.path.getsize(dst)} bytes")


if __name__ == "__main__":
    main()
