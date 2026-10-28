#!/usr/bin/env python3
"""Checks MedNotes/Localizable.xcstrings against the Swift sources.

xcodebuild never syncs the string catalog, so keys added in code stay
untranslated until someone adds them by hand. This script finds them.

Two extractors, used together when a build exists:

  * Source scan (always): tokenizes the Swift files, keeps the string
    literals that reach a localizing API — SwiftUI's `Text("…")`,
    `Button("…")` and friends, `String(localized:)`, and any project
    initializer or function parameter typed `LocalizedStringKey`, which are
    discovered from the sources — and compares them with the catalog.
    Interpolations match any format specifier, since their types are unknown
    here.
  * Compiler extraction (`--derived-data`, or found automatically): the
    `.stringsdata` files swiftc emits during a build hold the exact keys,
    with `%@` / `%lld` / `%d` specifiers as String.LocalizationValue formats
    them. They are authoritative; the source scan is reported next to them
    so a gap in either shows up.

It also checks every catalog value for the language: the specifiers must
match the key's (count and type, positional forms allowed), and Greek
punctuation (… for ..., ; for ?, «» for “”) is flagged when it slips.

Usage:
  scripts/check_l10n.py                    # whole app, auto-detects a build
  scripts/check_l10n.py MedNotes/Storage   # only these files or folders
  scripts/check_l10n.py --derived-data ~/Library/Developer/Xcode/DerivedData/MedNotes-local
  scripts/check_l10n.py --no-build         # source scan only

Exit status: 0 when nothing is missing and every value checks out, 1 otherwise.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from dataclasses import dataclass, field

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "MedNotes", "Localizable.xcstrings")
PLACEHOLDER = "￼"

# SwiftUI API whose first unlabeled argument is a LocalizedStringKey when it
# is a literal. Labeled arguments are not localized, except the labels below.
SWIFTUI_FIRST_ARG = {
    "Text", "Button", "Label", "Toggle", "Picker", "SecureField", "TextField",
    "Section", "Menu", "LabeledContent", "GroupBox", "DisclosureGroup",
    "ProgressView", "Link", "Stepper", "DatePicker", "ColorPicker",
    "NavigationLink", "ContentUnavailableView", "Window", "WindowGroup",
    "CommandMenu", "Tab", "Gauge", "Slider", "ShareLink", "TextEditor",
    "TableColumn", "Grid", "Form",
    "LocalizedStringKey", "LocalizedStringResource",
    "help", "navigationTitle", "navigationSubtitle", "alert",
    "confirmationDialog", "accessibilityLabel", "accessibilityHint",
    "accessibilityValue", "badge",
}
SWIFTUI_LABELS = {
    ("String", "localized"), ("TextField", "prompt"), ("SecureField", "prompt"),
    ("searchable", "prompt"), ("Text", "_"),
}
LOCALIZED_TYPES = r"(?:LocalizedStringKey|LocalizedStringResource|String\.LocalizationValue)"

# SwiftUI arguments that take a plain String and show it verbatim.
VERBATIM_ARGS = {
    ("LabeledContent", "value"): "LabeledContent value (shown verbatim)",
}

# Plain-String sinks that reach the user: a literal here is shown in English.
UNLOCALIZED_SINKS = [
    (re.compile(r"\.(?:message|prompt|title|messageText|informativeText|nameFieldLabel)\s*=\s*$"), "AppKit panel/alert text"),
    (re.compile(r"\b(?:notice|errorMessage|initError|integrityWarning)\s*=\s*$"), "session message"),
    (re.compile(r"\.nameFieldStringValue\s*=\s*$"), "default file name"),
    (re.compile(r"\bthrow\s+[\w.]+\($"), "thrown error detail"),
    (re.compile(r"\bfail\($"), "failure message"),
]


@dataclass
class Literal:
    start: int
    end: int
    text: str                       # decoded; interpolations are PLACEHOLDER
    interpolations: list[str] = field(default_factory=list)
    spans: list[tuple[int, int]] = field(default_factory=list)  # interpolation code


@dataclass
class Found:
    key: str
    path: str
    line: int
    how: str


def scan(src: str) -> tuple[list[Literal], str]:
    """Returns the string literals of a Swift file and a copy of the source
    with comments and literal bodies blanked out (same offsets), so code
    structure can be walked without tripping over their contents."""
    lits: list[Literal] = []
    masked = list(src)
    i, n = 0, len(src)

    def blank(a: int, b: int) -> None:
        for k in range(a, b):
            if masked[k] != "\n":
                masked[k] = " "

    def read_string(i: int) -> tuple[Literal, int]:
        start = i
        hashes = 0
        while src[i] == "#":
            hashes += 1
            i += 1
        multiline = src.startswith('"""', i)
        i += 3 if multiline else 1
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        parts: list[str] = []
        interps: list[str] = []
        spans: list[tuple[int, int]] = []
        while i < n:
            if src.startswith(close, i):
                i += len(close)
                break
            if src.startswith(escape, i):
                j = i + len(escape)
                c = src[j] if j < n else ""
                if c == "(":
                    depth, k = 1, j + 1
                    while k < n and depth:
                        if src[k] == '"' or (src[k] == "#" and src[k + 1:k + 2] in ('"', "#")):
                            # A literal inside an interpolation is a literal
                            # of its own, e.g. "\(String(localized: "x")).ext".
                            nested, k = read_string(k)
                            lits.append(nested)
                            continue
                        if src[k] == "(":
                            depth += 1
                        elif src[k] == ")":
                            depth -= 1
                        k += 1
                    interps.append(src[j + 1:k - 1])
                    spans.append((j + 1, k - 1))
                    parts.append(PLACEHOLDER)
                    i = k
                    continue
                simple = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}
                if c in simple:
                    parts.append(simple[c])
                    i = j + 1
                    continue
                if c == "u":
                    m = re.match(r"u\{([0-9a-fA-F]+)\}", src[j:])
                    if m:
                        parts.append(chr(int(m.group(1), 16)))
                        i = j + len(m.group(0))
                        continue
                if multiline and c == "\n":         # line continuation
                    i = j + 1
                    continue
                parts.append(src[i:j + 1])
                i = j + 1
                continue
            parts.append(src[i])
            i += 1
        text = "".join(parts)
        if multiline:
            text = dedent_multiline(text)
        return Literal(start, i, text, interps, spans), i

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif src.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if src.startswith("/*", j):
                    depth += 1
                    j += 2
                elif src.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', src[i:i + 16])):
            lit, j = read_string(i)
            lits.append(lit)
            i = j
        else:
            i += 1
    # Blank each literal's text but keep its interpolated code, so a literal
    # nested in an interpolation still sits inside a visible call.
    for lit in lits:
        pos = lit.start + 1
        for a, b in lit.spans:
            blank(pos, a)
            pos = b
        blank(pos, lit.end)
    lits.sort(key=lambda lit: lit.start)
    return lits, "".join(masked)


def dedent_multiline(text: str) -> str:
    lines = text.split("\n")
    if lines and lines[0].strip() == "":
        lines = lines[1:]
    indent = re.match(r"[ \t]*", lines[-1]).group(0) if lines else ""
    if lines and lines[-1].strip() == "":
        lines = lines[:-1]
    return "\n".join(l[len(indent):] if l.startswith(indent) else l for l in lines)


def discover_localized_params(files: list[str]) -> set[tuple[str, str]]:
    """(callee, label) pairs whose parameter is typed LocalizedStringKey in
    the project: explicit initializers and functions, and memberwise
    initializers of structs with LocalizedStringKey properties."""
    found: set[tuple[str, str]] = set()
    decl = re.compile(r"\b(struct|class|enum|extension)\s+(\w+)")
    for path in files:
        src = open(path, encoding="utf-8").read()
        _, masked = scan(src)
        types = [(m.start(), m.group(2)) for m in decl.finditer(masked)]

        def owner(pos: int) -> str:
            name = ""
            for p, t in types:
                if p < pos:
                    name = t
            return name

        for m in re.finditer(r"\b(init|func\s+(\w+))\s*(?:<[^>]*>)?\s*\(", masked):
            depth, k = 1, m.end()
            while k < len(masked) and depth:
                depth += {"(": 1, ")": -1}.get(masked[k], 0)
                k += 1
            params = src[m.end():k - 1]
            callee = m.group(2) or owner(m.start())
            for p in split_top_level(params):
                pm = re.match(r"\s*(?:(\w+)\s+)?(\w+)\s*:\s*" + LOCALIZED_TYPES + r"\??\s*(?:=|$)", p)
                if pm:
                    found.add((callee, pm.group(1) or pm.group(2)))
        for m in re.finditer(r"^\s*(?:@\w+\s+)*(?:private\s+|fileprivate\s+)?(?:let|var)\s+(\w+)\s*:\s*" + LOCALIZED_TYPES,
                             masked, re.M):
            found.add((owner(m.start()), m.group(1)))
    return found


def split_top_level(s: str) -> list[str]:
    out, depth, cur = [], 0, []
    prev = ""
    for ch in s:
        # The arrow in a closure or function type is not a closing angle bracket.
        if ch in "([{<":
            depth += 1
        elif ch in ")]}" or (ch == ">" and prev != "-"):
            depth -= 1
        prev = ch
        if ch == "," and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def enclosing_call(masked: str, pos: int) -> tuple[str, str] | None:
    """The callee and argument label of the call whose argument list holds
    `pos`, or None when the literal is not a call argument."""
    depth, k, arg_start = 0, pos - 1, None
    while k >= 0:
        ch = masked[k]
        if ch in ")]}":
            depth += 1
        elif ch in "([{":
            if depth == 0:
                break
            depth -= 1
        elif ch == "," and depth == 0 and arg_start is None:
            arg_start = k + 1
        k -= 1
    if k < 0 or masked[k] != "(":
        return None
    if arg_start is None:
        arg_start = k + 1
    m = re.search(r"([A-Za-z_]\w*)\s*(?:<[^()]*>)?\s*$", masked[max(0, k - 200):k])
    if not m:
        # A grouping paren, as in `a ? "x" : (b ? "y" : "z")`: the literal
        # belongs to whatever call holds the whole expression.
        return enclosing_call(masked, k)
    # A label leads its argument; the colon of "a ? b : c" never does.
    lm = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)", masked[arg_start:pos])
    return m.group(1), (lm.group(1) if lm else "_")


def declared_localized(masked: str, pos: int) -> bool:
    """True when a literal outside any call is the value of a declaration
    typed LocalizedStringKey, or is returned from one (through `switch`,
    `if` and friends)."""
    line_start = masked.rfind("\n", 0, pos) + 1
    if re.search(r":\s*" + LOCALIZED_TYPES + r"\??\s*=\s*$", masked[line_start:pos]):
        return True
    depth, k = 0, pos - 1
    while k >= 0:
        ch = masked[k]
        if ch == "}":
            depth += 1
        elif ch == "{":
            if depth:
                depth -= 1
            else:
                boundary = max(masked.rfind("{", 0, k), masked.rfind("}", 0, k), masked.rfind(";", 0, k))
                header = masked[boundary + 1:k]
                if re.search(r"\b(?:func|var)\b", header):
                    return bool(re.search(LOCALIZED_TYPES, header))
                if re.search(r"\b(?:init|subscript|struct|class|enum|extension)\b|\bin\s*$", header):
                    return False
        k -= 1
    return False


def line_of(src: str, pos: int) -> int:
    return src.count("\n", 0, pos) + 1


def scan_sources(files: list[str], params: set[tuple[str, str]]) -> tuple[list[Found], list[Found]]:
    localized: list[Found] = []
    suspicious: list[Found] = []
    for path in files:
        src = open(path, encoding="utf-8").read()
        lits, masked = scan(src)
        rel = os.path.relpath(path, ROOT)
        for lit in lits:
            call = enclosing_call(masked, lit.start)
            how = None
            if call:
                callee, label = call
                if label == "_" and callee in SWIFTUI_FIRST_ARG:
                    how = f"{callee}(…)"
                elif (callee, label) in SWIFTUI_LABELS:
                    how = f"{callee}({label}:)"
                elif (callee, label) in params:
                    how = f"{callee}({label}:) LocalizedStringKey"
                elif label == "verbatim":
                    continue
                elif (callee, label) in VERBATIM_ARGS and re.search(r"[A-Za-z]{3,}", lit.text):
                    suspicious.append(Found(lit.text, rel, line_of(src, lit.start), VERBATIM_ARGS[(callee, label)]))
                    continue
            if call is None and declared_localized(masked, lit.start):
                how = "LocalizedStringKey declaration"
            line = line_of(src, lit.start)
            if how:
                localized.append(Found(lit.text, rel, line, how))
                continue
            before = masked[masked.rfind("\n", 0, lit.start) + 1:lit.start]
            for rx, why in UNLOCALIZED_SINKS:
                if rx.search(before) and re.search(r"[A-Za-z]{3,}", lit.text):
                    suspicious.append(Found(lit.text, rel, line, why))
    return localized, suspicious


def stringsdata_keys(derived: str) -> list[Found]:
    pattern = os.path.join(derived, "Build", "Intermediates.noindex", "MedNotes.build", "*",
                           "MedNotes.build", "Objects-normal", "*", "*.stringsdata")
    files = glob.glob(pattern)
    out: list[Found] = []
    for f in files:
        data = json.load(open(f, encoding="utf-8"))
        rel = os.path.relpath(data["source"], ROOT)
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                continue
            for e in entries:
                out.append(Found(e["key"], rel, e["location"]["startingLine"], "compiler"))
    return out


def newest_derived_data() -> str | None:
    cands = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/MedNotes-*"))
    best, best_t = None, 0.0
    for c in cands:
        hits = glob.glob(os.path.join(c, "Build/Intermediates.noindex/MedNotes.build/*/MedNotes.build/Objects-normal/*/*.stringsdata"))
        # Only a build of this tree: a copy elsewhere has other sources.
        if hits and json.load(open(hits[0], encoding="utf-8"))["source"].startswith(os.path.join(ROOT, "MedNotes") + os.sep):
            t = max(os.path.getmtime(h) for h in hits)
            if t > best_t:
                best, best_t = c, t
    return best


SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfeEgGcCsSpaA%])")


def specifiers(s: str) -> list[str] | None:
    """The argument specifiers of a format string in argument order, or None
    when positional and non-positional forms are mixed."""
    plain, positional = [], {}
    for m in SPEC.finditer(s):
        if m.group(3) == "%":
            continue
        spec = (m.group(2) or "") + m.group(3)
        if m.group(1):
            positional[int(m.group(1))] = spec
        else:
            plain.append(spec)
    if plain and positional:
        return None
    if positional:
        return [positional.get(i, "?") for i in range(1, max(positional) + 1)]
    return plain


def wildcard(s: str) -> str:
    return SPEC.sub(lambda m: "%" if m.group(3) == "%" else PLACEHOLDER, s)


def check_values(catalog: dict, lang: str, keys: set[str] | None) -> list[str]:
    problems = []
    for key, entry in catalog["strings"].items():
        if not key or (keys is not None and key not in keys):
            continue
        if entry.get("shouldTranslate") is False:
            continue
        values = units(entry.get("localizations", {}).get(lang, {}))
        if not values:
            problems.append(f"no {lang} value: {key!r}")
            continue
        for value in values:
            problems += check_value(key, value, lang)
    return problems


def units(loc: dict) -> list[str]:
    """Every value of one localization: its stringUnit, or those of its
    plural/device variations."""
    if "stringUnit" in loc:
        return [loc["stringUnit"].get("value", "")]
    out = []
    for kind in loc.get("variations", {}).values():
        for variant in kind.values():
            out += units(variant)
    return out


def check_value(key: str, value: str, lang: str) -> list[str]:
    problems = []
    ks, vs = specifiers(key), specifiers(value)
    if ks is None or vs is None or ks != vs:
        problems.append(f"specifiers differ: {key!r} {ks} → {value!r} {vs}")
    if lang == "el":
        if "…" in key and "…" not in value:
            problems.append(f"ellipsis dropped: {key!r} → {value!r}")
        if "..." in value:
            problems.append(f"three dots instead of …: {value!r}")
        if "?" in value and "?" in key:
            problems.append(f"Latin question mark (Greek uses ;): {value!r}")
        if "“" in value or "”" in value or re.search(r'(^|\s)"\w', value):
            problems.append(f"English quotes (Greek uses «»): {value!r}")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="Swift files or folders (default: MedNotes/)")
    ap.add_argument("--catalog", default=CATALOG)
    ap.add_argument("--lang", default="el")
    ap.add_argument("--derived-data", help="a DerivedData folder whose build holds .stringsdata files")
    ap.add_argument("--no-build", action="store_true", help="skip the compiler extraction")
    ap.add_argument("--stale", action="store_true", help="also list catalog keys no source uses")
    args = ap.parse_args()

    targets = args.paths or [os.path.join(ROOT, "MedNotes")]
    files: list[str] = []
    for t in targets:
        t = os.path.abspath(t)
        if os.path.isdir(t):
            files += sorted(glob.glob(os.path.join(t, "**", "*.swift"), recursive=True))
        elif t.endswith(".swift"):
            files.append(t)
    all_app_files = sorted(glob.glob(os.path.join(ROOT, "MedNotes", "**", "*.swift"), recursive=True))
    wanted = {os.path.relpath(f, ROOT) for f in files}

    catalog = json.load(open(args.catalog, encoding="utf-8"))
    keys = set(catalog["strings"])
    wild = {wildcard(k).replace("%%", "%"): k for k in keys}

    params = discover_localized_params(all_app_files)
    scanned, suspicious = scan_sources(files, params)

    compiled: list[Found] = []
    derived = None if args.no_build else (args.derived_data or newest_derived_data())
    if derived:
        compiled = [f for f in stringsdata_keys(derived) if f.path in wanted]

    failed = False
    missing: dict[str, list[Found]] = {}
    for f in compiled:
        if f.key not in keys:
            missing.setdefault(f.key, []).append(f)
    for f in scanned:
        norm = f.key.replace("%", "%%") if PLACEHOLDER in f.key else f.key
        if f.key in keys or norm in keys or f.key.replace("%%", "%") in wild:
            continue
        if not any(wildcard(k) == f.key for k in missing):
            missing.setdefault(f.key, []).append(f)

    print(f"catalog: {len(keys) - ('' in keys)} keys · {len(files)} Swift files · "
          f"source scan: {len({f.key for f in scanned})} keys · "
          + (f"compiler: {len({f.key for f in compiled})} keys ({os.path.basename(derived)})" if derived
             else "compiler: not used"))
    if derived:
        stamp = max((os.path.getmtime(f) for f in files), default=0)
        built = max((os.path.getmtime(p) for p in glob.glob(os.path.join(
            derived, "Build/Intermediates.noindex/MedNotes.build/*/MedNotes.build/Objects-normal/*/*.stringsdata"))), default=0)
        if stamp > built:
            print("note: sources changed since that build; rebuild for exact keys")

    if missing:
        failed = True
        print(f"\nMISSING from the catalog ({len(missing)}):")
        for key, where in sorted(missing.items(), key=lambda kv: (kv[1][0].path, kv[1][0].line)):
            locs = ", ".join(sorted({f"{w.path}:{w.line}" for w in where}))
            shown = key.replace(PLACEHOLDER, "\\(…)")
            print(f"  {shown!r}\n      {locs}")

    if derived:
        comp_keys = {f.key for f in compiled}
        scan_keys = {f.key for f in scanned}
        only_compiler = [k for k in comp_keys if k not in scan_keys
                         and not any(wildcard(k).replace("%%", "%") == s for s in scan_keys)]
        only_scan = [s for s in scan_keys if s not in comp_keys
                     and not any(wildcard(k).replace("%%", "%") == s for k in comp_keys)]
        if only_compiler or only_scan:
            print("\nextractors disagree (the compiler is authoritative):")
            for k in sorted(only_compiler):
                print(f"  compiler only: {k!r}")
            for k in sorted(only_scan):
                w = next(f for f in scanned if f.key == k)
                print(f"  source scan only: {k!r} ({w.path}:{w.line}, {w.how})")

    # With paths, check only the values those files use; otherwise all.
    scope = None
    if args.paths:
        scope = {f.key for f in compiled} | {wild.get(f.key.replace("%%", "%"), f.key) for f in scanned}
    problems = check_values(catalog, args.lang, scope)
    if problems:
        failed = True
        print(f"\nVALUE problems ({len(problems)}):")
        for p in problems:
            print("  " + p)

    if suspicious:
        print(f"\nuser-visible literals that bypass localization ({len(suspicious)}; review, not an error):")
        for f in suspicious:
            print(f"  {f.path}:{f.line} [{f.how}] {f.key!r}")

    if args.stale and derived and not args.paths:
        used = {f.key for f in stringsdata_keys(derived)}
        stale = sorted(k for k in keys if k and k not in used)
        print(f"\ncatalog keys no source uses ({len(stale)}; Xcode would mark them stale):")
        for k in stale:
            print(f"  {k!r}")

    if not failed:
        print("\nOK: every localized string has a " + args.lang + " value and its specifiers match.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
