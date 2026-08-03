#!/usr/bin/env python3
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources" / "HyperSwitch"
CATALOGUE = SOURCES / "Resources" / "Localizable.xcstrings"

LITERAL = r'"((?:[^"\\\n]|\\.)+)"'

PATTERNS = [
    re.compile(r'\bText\(\s*' + LITERAL),
    re.compile(r'\bLabel\(\s*' + LITERAL),
    re.compile(r'\bButton\(\s*' + LITERAL),
    re.compile(r'\bPicker\(\s*' + LITERAL),
    re.compile(r'\bToggle\(\s*' + LITERAL),
    re.compile(r'\bSection\(\s*' + LITERAL),
    re.compile(r'\bLabeledContent\(\s*' + LITERAL),
    re.compile(r'\bLocalization\.string\(\s*' + LITERAL),
    re.compile(r'\bString\(localized:\s*' + LITERAL),
    re.compile(r'\btitle:\s*' + LITERAL),
    re.compile(r'\bdetail:\s*' + LITERAL),
    re.compile(r'\baction:\s*' + LITERAL),
    re.compile(r'\bunit:\s*' + LITERAL),
    re.compile(r'\bLocalizedStringKey\(\s*' + LITERAL),
    re.compile(r':\s*LocalizedStringKey\s*=\s*' + LITERAL),
    re.compile(r'->\s*LocalizedStringKey\b[^\n]*?\breturn\s+' + LITERAL),
    re.compile(r'\bitem\(\s*' + LITERAL),
    re.compile(r'\?\s*' + LITERAL + r'\s*:\s*"'),
    re.compile(r'"\s*:\s*' + LITERAL),
]

NOT_TEXT = re.compile(
    r'^(?:'
    r'[a-z0-9]+(?:\.[a-z0-9]+)+'          # SF Symbol names: gearshape.fill, square.stack…
    r'|info|apps|windows|general|about|appearance|appSwitcher'   # enum raw values
    r'|[a-z-]+\.[a-z-]+\.[a-z-]+.*'       # bundle identifiers and settings URLs
    r'|register|unregister'               # verbs spliced into a log line, never shown
    r')$'
)

SKIP_DIRS = {"Debug"}

BARE_CASE = re.compile(r'^\s*case\s+\.?\w+:\s*' + LITERAL + r'\s*$', re.M)

def found_keys() -> dict[str, set[str]]:
    keys: dict[str, set[str]] = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if SKIP_DIRS & set(path.relative_to(SOURCES).parts):
            continue
        text = path.read_text(encoding="utf-8")
        text = re.sub(r'^\s*//.*$', '', text, flags=re.M)
        for pattern in list(PATTERNS) + [BARE_CASE]:
            for match in pattern.finditer(text):
                key = match.group(1)
                if not key.strip() or NOT_TEXT.match(key):
                    continue
                keys.setdefault(key, set()).add(path.relative_to(ROOT).as_posix())
    return keys

def _translation_tables() -> tuple[dict[str, str], list[str]]:
    """`KEY_FOR_SOURCE` and `EXTRA_KEYS`, read out of write-translations.py.

    Parsed rather than imported: the module's filename contains a hyphen, so it is not a
    legal identifier, and `importlib` gymnastics to work around that is more machinery
    than reading two literals deserves.
    """
    text = (ROOT / "scripts" / "write-translations.py").read_text(encoding="utf-8")
    namespace: dict[str, object] = {}
    for name in ("KEY_FOR_SOURCE", "EXTRA_KEYS"):
        match = re.search(rf"^{name}\s*=\s*(\[|\{{)", text, re.M)
        if not match:
            continue
        start = match.start(1)
        depth, index = 0, start
        while index < len(text):
            if text[index] in "[{":
                depth += 1
            elif text[index] in "]}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        namespace[name] = eval(text[start:index + 1])   # noqa: S307 — our own literal
    return (namespace.get("KEY_FOR_SOURCE") or {},      # type: ignore[return-value]
            namespace.get("EXTRA_KEYS") or [])          # type: ignore[return-value]

def catalogue_keys() -> dict[str, str | None]:
    if not CATALOGUE.exists():
        return {}
    data = json.loads(CATALOGUE.read_text(encoding="utf-8"))
    out: dict[str, str | None] = {}
    for key, entry in data.get("strings", {}).items():
        unit = entry.get("localizations", {}).get("zh-Hans", {}).get("stringUnit", {})
        out[key] = unit.get("value")
    return out

def main() -> int:
    source = found_keys()
    catalogue = catalogue_keys()

    if "--list" in sys.argv:
        for key in sorted(source):
            print(key)
        return 0

    key_for_source, extra = _translation_tables()

    source = {key_for_source.get(k, k): v for k, v in source.items()}
    for key in extra:
        source.setdefault(key, {"<not scannable: see EXTRA_KEYS>"})

    missing = sorted(k for k in source if not catalogue.get(k))
    stale = sorted(k for k in catalogue if k not in source)

    print(f"sources: {len(source)} keys   catalogue: {len(catalogue)} keys")
    if missing:
        print(f"\nMISSING zh-Hans ({len(missing)}):")
        for key in missing:
            print(f"  {key}\n      {', '.join(sorted(source[key]))}")
    if stale:
        print(f"\nSTALE — in catalogue, not in sources ({len(stale)}):")
        for key in stale:
            print(f"  {key}")
    if not missing and not stale:
        print("\nOK — every source key has a Chinese translation and nothing is stale.")
    return 1 if missing else 0

if __name__ == "__main__":
    raise SystemExit(main())
