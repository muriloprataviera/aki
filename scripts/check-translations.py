#!/usr/bin/env python3
"""Every language table has exactly the same keys, none repeated, and every
L10n.t("…") text used in the code has a translation.

A repeated key crashes Aki at launch (Swift dictionary literal), so this runs in
CI and before every commit that touches texts:  python3 scripts/check-translations.py
"""
import glob
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TABLES = sorted(glob.glob(str(ROOT / "Sources/Aki/Localization/L10n+*.swift")))
PAIR = re.compile(r'"((?:[^"\\]|\\.)*)"\s*:\s*"(?:[^"\\]|\\.)*"')
USED = re.compile(r'L10n\.t\("((?:[^"\\]|\\.)*)"\)')
# Names and marks that stay the same in every language.
UNTRANSLATED = {"Codex", "Claude Code", "Liquid Glass", "Solid black", "…"}

def keys(path):
    text = Path(path).read_text()
    return PAIR.findall(text[text.index("["):])

failed = False
tables = {Path(p).stem.split("+")[1]: keys(p) for p in TABLES}
reference = set(tables["Portuguese"])
for name, found in tables.items():
    repeated = {k for k in found if found.count(k) > 1}
    missing, extra = reference - set(found), set(found) - reference
    if repeated or missing or extra:
        failed = True
        print(f"✗ {name}: {len(repeated)} repeated, {len(missing)} missing, {len(extra)} extra")
        for k in sorted(repeated | missing | extra)[:10]:
            print(f"    {k[:90]}")
    else:
        print(f"✓ {name}: {len(found)} texts")

used = set()
for swift in (ROOT / "Sources/Aki").rglob("*.swift"):
    if "Codenotch" not in swift.parts:
        used |= set(USED.findall(swift.read_text()))
untranslated = sorted(used - reference - UNTRANSLATED)
if untranslated:
    failed = True
    print(f"✗ {len(untranslated)} text(s) used in the code without a translation:")
    for k in untranslated[:20]:
        print(f"    {k[:90]}")

sys.exit(1 if failed else 0)
