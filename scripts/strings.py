#!/usr/bin/env python3
"""Kumquat's translations.

Resources/Localization/Localizable.xcstrings is a String Catalog (the format Xcode edits) and the single
source of truth. This script keeps it in step with the code and turns it into the .strings files the app
bundle loads, without needing Xcode:

  scripts/strings.py extract            add new keys from the sources, remove ones the code no longer uses
  scripts/strings.py check              every key translated in every language, placeholders intact
  scripts/strings.py compile <dir>      write <dir>/<lang>.lproj/Localizable.strings
  scripts/strings.py missing <lang>     keys still to translate, as JSON

Keys are the English text, as Swift builds them: interpolations become format specifiers
("\\(count) files" → "%lld files") and, in strings with interpolations, a literal % becomes %%.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Resources", "Localization", "Localizable.xcstrings")
LANGUAGES = ["fr", "es", "de", "ar"]

# SwiftUI initialisers and modifiers whose first string literal is a LocalizedStringKey.
SWIFTUI = r"\b(?:Text|Button|Toggle|Picker|Section|Label|LabeledContent|Stepper|TextField|SecureField|Link|Menu|help|accessibilityLabel|navigationTitle)\(\s*"
LITERAL = r'"((?:[^"\\\n]|\\.)*)"'

# Interpolated expressions whose type is an integer (→ %lld). Everything else is a String (→ %@).
INTEGER_HINTS = [
    r"\.count\b", r"^Int\(", r"\bInt\(", r"^\$0$", r"\bvideoCRF\b", r"\bpdfDPI\b", r"\bparallelJobs\b", r"^position$",
    r"\bpage \+ 1\b", r"\brotation\b", r"^minimum$", r"^removed$", r"^left$", r"^conversions$", r"^fileCount$",
    r"^value\.wrappedValue$", r"\.pageCount\b", r"^index \+ 1$", r"^count$", r"^total$",
    r"^width$", r"^height$", r"^percent$", r"^pageCount$", r"maxUpscaledSide",
]
# Int32 interpolations (process exit statuses) → %d.
INT32_HINTS = [r"^status$"]


def interpolations(body):
    """Splits a Swift string literal body into text and \\( ) expressions (balanced parentheses)."""
    parts, i, text = [], 0, ""
    while i < len(body):
        if body.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(body) and depth:
                depth += {"(": 1, ")": -1}.get(body[j], 0)
                j += 1
            parts.append(("text", text))
            parts.append(("expr", body[i + 2:j - 1].strip()))
            text, i = "", j
        elif body[i] == "\\" and i + 1 < len(body):
            text += {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0"}.get(body[i + 1], body[i + 1])
            i += 2
        else:
            text += body[i]
            i += 1
    parts.append(("text", text))
    return parts


def specifier(expression):
    if any(re.search(hint, expression) for hint in INT32_HINTS):
        return "%d"
    return "%lld" if any(re.search(hint, expression) for hint in INTEGER_HINTS) else "%@"


def key_for(body):
    parts = interpolations(body)
    has_args = any(kind == "expr" for kind, _ in parts)
    key = ""
    for kind, value in parts:
        if kind == "text":
            key += value.replace("%", "%%") if has_args else value
        else:
            key += specifier(value)
    return key


def source_keys():
    keys = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "Sources", "Kumquat*", "**", "*.swift"), recursive=True)):
        if "KumquatCLI" in path or "KumquatExtension" in path:
            continue
        text = open(path, encoding="utf-8").read()
        rel = os.path.relpath(path, ROOT)
        patterns = [r"\bL\(\s*" + LITERAL]
        if "/Kumquat/" in path:
            patterns.append(SWIFTUI + LITERAL)
        for pattern in patterns:
            for match in re.finditer(pattern, text):
                body = match.group(1)
                if not re.search(r"[A-Za-z]", re.sub(r"\\\(.*?\)", "", body)):
                    continue  # numbers and symbols only
                line = text.count("\n", 0, match.start()) + 1
                keys.setdefault(key_for(body), f"{rel}:{line}")
    return keys


def load():
    if not os.path.exists(CATALOG):
        return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    return json.load(open(CATALOG, encoding="utf-8"))


def save(catalog):
    catalog["strings"] = dict(sorted(catalog["strings"].items(), key=lambda item: item[0].lower()))
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2, separators=(",", " : "))
        handle.write("\n")


def translation(entry, language):
    unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
    return unit.get("value") if unit.get("state") == "translated" else None


PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|llu|lf|ld|@|d|f)")


def placeholders(text):
    return sorted(re.sub(r"\d+\$", "", p) for p in PLACEHOLDER.findall(text.replace("%%", "")))


def extract():
    catalog, keys = load(), source_keys()
    strings = catalog["strings"]
    added = [key for key in keys if key not in strings]
    for key in added:
        strings[key] = {}
    # The code is the source of truth: strings it no longer uses are removed with their translations.
    removed = [key for key in strings if key not in keys]
    for key in removed:
        del strings[key]
    save(catalog)
    print(f"{len(keys)} keys in the sources, {len(added)} new, {len(removed)} removed")
    for key in removed:
        print(f"  - {key!r}")
    for key in added:
        print(f"  + {keys[key]}: {key!r}")


def check():
    catalog, keys, problems = load(), source_keys(), []
    for key in keys:
        if key not in catalog["strings"]:
            problems.append(f"not in the catalog (run scripts/strings.py extract): {key!r}")
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale":
            continue
        for language in LANGUAGES:
            value = translation(entry, language)
            if value is None:
                problems.append(f"{language}: missing {key!r}")
            elif placeholders(value) != placeholders(key):
                problems.append(f"{language}: placeholders differ in {key!r} → {value!r}")
    for problem in problems:
        print(problem)
    print(f"{len(keys)} keys, {len(LANGUAGES)} languages, {len(problems)} problems")
    return 1 if problems else 0


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def compile_to(directory):
    catalog = load()
    for language in LANGUAGES:
        lines = ["/* Generated from Resources/Localization/Localizable.xcstrings by scripts/strings.py. */"]
        for key, entry in catalog["strings"].items():
            value = translation(entry, language)
            if value is not None:
                lines.append(f'"{escape(key)}" = "{escape(value)}";')
        folder = os.path.join(directory, f"{language}.lproj")
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    # English needs no table (keys are English), but an en.lproj tells macOS the app speaks English.
    os.makedirs(os.path.join(directory, "en.lproj"), exist_ok=True)
    open(os.path.join(directory, "en.lproj", "Localizable.strings"), "w").write("/* Keys are the English text. */\n")


def missing(language):
    catalog = load()
    todo = [key for key, entry in catalog["strings"].items()
            if entry.get("extractionState") != "stale" and translation(entry, language) is None]
    print(json.dumps(todo, ensure_ascii=False, indent=1))


def apply_translations(path):
    """Merges {language: {key: value}} from a JSON file into the catalog."""
    catalog, updates = load(), json.load(open(path, encoding="utf-8"))
    unknown = []
    for language, values in updates.items():
        for key, value in values.items():
            if key not in catalog["strings"]:
                unknown.append(key)
                continue
            catalog["strings"][key].setdefault("localizations", {})[language] = {
                "stringUnit": {"state": "translated", "value": value}}
    save(catalog)
    for key in sorted(set(unknown)):
        print(f"not a key: {key!r}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    if command == "extract":
        extract()
    elif command == "check":
        sys.exit(check())
    elif command == "compile":
        compile_to(sys.argv[2])
    elif command == "missing":
        missing(sys.argv[2])
    elif command == "apply":
        apply_translations(sys.argv[2])
    else:
        sys.exit(__doc__)
