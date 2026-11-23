#!/usr/bin/env python3
"""vault-core command contract: generate client bindings and check client op usage.

Single source of truth: crates/vault-core/contract/commands.json (also enforced at
runtime by crates/vault-core/src/native/contract.rs).

  python3 tool/core_contract.py generate   # rewrite generated client bindings
  python3 tool/core_contract.py check      # fail on stale bindings or unregistered ops
  python3 tool/core_contract.py matrix     # which client calls which op
  python3 tool/core_contract.py matrix --missing android   # ops other clients use but Android does not
  python3 tool/core_contract.py matrix --group relay-mesh --unused
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = ROOT / "crates/vault-core/contract/commands.json"
TS_OUT = ROOT / "apps/desktop/ui/api/coreContract.generated.ts"
KT_OUT = ROOT / "apps/android/app/src/main/java/com/securepass/vault/CoreRequest.generated.kt"
SWIFT_OUT = ROOT / "apps/ios/Sources/CoreRequest.generated.swift"

TS_TYPES = {
    "string": "string",
    "number": "number",
    "bool": "boolean",
    "object": "object",
    "array": "readonly unknown[]",
    "any": "unknown",
}

# Client call sites that send a request to vault-core. Each pattern captures the op name(s);
# literal Kotlin `.put(...)` chains and Swift dictionary literals are also checked for
# param names that the op does not accept.
SCANS: list[tuple[str, tuple[str, ...], list[re.Pattern[str]]]] = [
    (
        "Kotlin",
        ("apps/android/app/src",),
        [
            re.compile(r'\b(?:command|raw|mutate)\(\s*"([a-z0-9-]+)"'),
            re.compile(r'\b(?:command|raw|mutate)\(\s*if\s*\([^)]*\)\s*"([a-z0-9-]+)"\s*else\s*"([a-z0-9-]+)"'),
            re.compile(r'put\(\s*"op"\s*,\s*"([a-z0-9-]+)"\s*\)'),
        ],
    ),
    (
        "Swift",
        ("apps/ios", "apps/shared"),
        [
            re.compile(r'"op"\s*:\s*\.string\(\s*"([a-z0-9-]+)"\s*\)'),
            re.compile(r'"op"\s*:\s*(?:JSONValue)?\.string\(\s*[^()"]*\?\s*"([a-z0-9-]+)"\s*:\s*"([a-z0-9-]+)"\s*\)'),
            re.compile(r'"op"\s*:\s*JSONValue\.string\(\s*"([a-z0-9-]+)"\s*\)'),
            # ImportReviewView builds core requests through a local `request(op)` helper.
            re.compile(r'\brequest\(\s*"([a-z0-9-]+)"'),
            re.compile(r'\\"op\\"\s*:\s*\\"([a-z0-9-]+)\\"'),
            re.compile(r'"op"\s*:\s*"([a-z0-9-]+)"'),
        ],
    ),
    (
        "Desktop Rust",
        ("apps/desktop/src",),
        # Only requests passed straight to a vault session's `command(...)`; the desktop
        # crate also speaks other JSON protocols (AI control, browser host) with an `op` key.
        [re.compile(r'command\(\s*(?:r#?)?[^;]{0,40}?\{\s*\\?"op\\?"\s*:\s*\\?"([a-z0-9-]+)')],
    ),
]
EXTENSIONS = {"Kotlin": (".kt",), "Swift": (".swift",), "Desktop Rust": (".rs",)}


def load_spec() -> dict:
    return json.loads(SPEC.read_text())


def load() -> dict:
    return load_spec()["commands"]


# ---- result shapes -------------------------------------------------------------------
# `result` uses a small TypeScript-like notation: `{a:number,b?:string[]}`, `T[]`, unions
# `A|B`, intersections `A & B`, literals ('x', true, false, null), bare keys `{id,title}` (untyped), primitives
# string|number|bool|object|any, `Record<K,V>` and the named shapes in the spec's "types".
PRIMITIVE_TS = {"string": "string", "number": "number", "bool": "boolean", "object": "Record<string, unknown>",
                "any": "unknown", "true": "true", "false": "false", "null": "null"}
TOKEN = re.compile(r"\s*(?:(?P<str>'[^']*')|(?P<num>-?\d+(?:\.\d+)?)|(?P<id>[A-Za-z_][A-Za-z0-9_]*)|(?P<p>\[\]|[{}()<>,:?|&]))")


class ResultParser:
    def __init__(self, text: str, named: set[str]):
        self.tokens, self.named, self.i = [], named, 0
        pos = 0
        while pos < len(text.rstrip()):
            m = TOKEN.match(text, pos)
            if not m or m.end() == pos:
                raise ValueError(f"cannot read result type at {text[pos:]!r}")
            self.tokens.append(next(v for v in m.groupdict().values() if v is not None))
            pos = m.end()

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else None

    def take(self, expected=None):
        tok = self.peek()
        if tok is None or (expected and tok != expected):
            raise ValueError(f"expected {expected or 'more'} in result type, got {tok!r}")
        self.i += 1
        return tok

    def parse(self) -> str:
        ts = self.union()
        if self.peek() is not None:
            raise ValueError(f"unexpected {self.peek()!r} in result type")
        return ts

    def union(self) -> str:
        parts = [self.intersection()]
        while self.peek() == "|":
            self.take()
            parts.append(self.intersection())
        return " | ".join(parts)

    def intersection(self) -> str:
        parts = [self.postfix()]
        while self.peek() == "&":
            self.take()
            parts.append(self.postfix())
        return " & ".join(parts)

    def postfix(self) -> str:
        ts = self.primary()
        while self.peek() == "[]":
            self.take()
            ts = f"Array<{ts}>"
        return ts

    def primary(self) -> str:
        tok = self.take()
        if tok == "(":
            inner = self.union()
            self.take(")")
            return f"({inner})"
        if tok == "{":
            fields = []
            while self.peek() != "}":
                name = self.take()
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                    raise ValueError(f"bad field name {name!r}")
                optional = self.peek() == "?" and bool(self.take())
                ty = "unknown"
                if self.peek() == ":":
                    self.take()
                    ty = self.union()
                fields.append(f"{name}{'?' if optional else ''}: {ty}")
                if self.peek() == ",":
                    self.take()
                elif self.peek() != "}":
                    raise ValueError(f"expected ',' or '}}' after field {name!r}")
            self.take("}")
            return "{ " + "; ".join(fields) + " }" if fields else "Record<string, never>"
        if tok.startswith("'"):
            return json.dumps(tok[1:-1])
        if re.fullmatch(r"-?\d+(?:\.\d+)?", tok):
            return tok
        if tok == "Record":
            self.take("<")
            key = self.union()
            self.take(",")
            value = self.union()
            self.take(">")
            return f"Record<{key}, {value}>"
        if tok in PRIMITIVE_TS:
            return PRIMITIVE_TS[tok]
        if tok in self.named:
            return f"Core{tok}"
        raise ValueError(f"unknown result type {tok!r} (declare it under \"types\")")


def result_ts(text: str, named: set[str], where: str = "") -> str:
    try:
        return ResultParser(text, named).parse()
    except ValueError as error:
        raise ValueError(f"{where}: result {text!r}: {error}") from None


# ---- generated clients -----------------------------------------------------------------
KOTLIN_KEYWORDS = {"as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in",
                   "interface", "is", "null", "object", "package", "return", "super", "this", "throw",
                   "true", "try", "typealias", "typeof", "val", "var", "when", "while"}
SWIFT_KEYWORDS = {"import", "func", "let", "var", "class", "struct", "enum", "protocol", "extension", "init",
                  "deinit", "subscript", "typealias", "operator", "return", "if", "else", "for", "while",
                  "repeat", "switch", "case", "default", "break", "continue", "where", "in", "is", "as",
                  "true", "false", "nil", "self", "Self", "super", "throw", "throws", "try", "catch",
                  "static", "public", "private", "internal", "fileprivate", "open", "defer", "guard", "do",
                  "inout", "Any", "Type", "Protocol"}
KT_TYPES = {"string": "String", "number": "Number", "bool": "Boolean", "object": "JSONObject",
            "array": "JSONArray", "any": "Any"}
SWIFT_TYPES = {"string": ("String", ".string({})"), "number": ("Double", ".number({})"),
               "bool": ("Bool", ".bool({})"), "object": ("JSONValue", "{}"), "array": ("JSONValue", "{}"),
               "any": ("JSONValue", "{}")}


def camel(op: str) -> str:
    head, *rest = op.split("-")
    return head + "".join(part[:1].upper() + part[1:] for part in rest)


def params_of(entry: dict) -> list[tuple[str, str, bool]]:
    """(name, type, optional) with required params first, preserving registry order."""
    items = [(raw.rstrip("?"), ty, raw.endswith("?")) for raw, ty in entry["params"].items()]
    return [p for p in items if not p[2]] + [p for p in items if p[2]]


def render_kotlin(commands: dict) -> str:
    out = [
        "// GENERATED by tool/core_contract.py from crates/vault-core/contract/commands.json.",
        "// Do not edit by hand: change commands.json and run `python3 tool/core_contract.py generate`.",
        "@file:Suppress(\"unused\", \"FunctionName\")",
        "",
        "package com.securepass.vault",
        "",
        "import org.json.JSONArray",
        "import org.json.JSONObject",
        "",
        "/** Typed vault-core requests: one builder per registered op, so a misspelled op or param is a compile error. */",
        "internal object CoreRequest {",
        "    private fun request(op: String, vararg params: Pair<String, Any?>): JSONObject {",
        "        val request = JSONObject().put(\"op\", op)",
        "        for ((name, value) in params) if (value != null) request.put(name, value)",
        "        return request",
        "    }",
    ]
    for op, entry in commands.items():
        args, pairs = [], []
        for name, ty, optional in params_of(entry):
            ident = f"`{name}`" if name in KOTLIN_KEYWORDS else name
            args.append(f"{ident}: {KT_TYPES[ty]}{'? = null' if optional else ''}")
            pairs.append(f"{json.dumps(name)} to {ident}")
        fn = camel(op)
        fn = f"`{fn}`" if fn in KOTLIN_KEYWORDS else fn
        out.append("")
        out.append(f"    /** {entry['group']} · {entry['lock']} → `{entry['result']}` */")
        call = ", ".join([json.dumps(op), *pairs])
        out.append(f"    fun {fn}({', '.join(args)}): JSONObject = request({call})")
    out += ["}", ""]
    return "\n".join(out)


def render_swift(commands: dict) -> str:
    out = [
        "// GENERATED by tool/core_contract.py from crates/vault-core/contract/commands.json.",
        "// Do not edit by hand: change commands.json and run `python3 tool/core_contract.py generate`.",
        "",
        "/// Typed vault-core requests: one builder per registered op, so a misspelled op or param is a compile error.",
        "enum CoreRequest {",
        "  private static func request(_ op: String, _ params: [(String, JSONValue?)] = []) -> [String: JSONValue] {",
        "    var request: [String: JSONValue] = [\"op\": .string(op)]",
        "    for (name, value) in params { if let value { request[name] = value } }",
        "    return request",
        "  }",
    ]
    for op, entry in commands.items():
        args, pairs = [], []
        for name, ty, optional in params_of(entry):
            swift_type, wrap = SWIFT_TYPES[ty]
            ident = f"`{name}`" if name in SWIFT_KEYWORDS else name
            args.append(f"{ident}: {swift_type}{'? = nil' if optional else ''}")
            value = name if name not in SWIFT_KEYWORDS else ident
            if optional:
                expr = value if wrap == "{}" else f"{value}.map {{ {wrap.format('$0')} }}"
            else:
                expr = wrap.format(value)
            pairs.append(f"({json.dumps(name)}, {expr})")
        fn = camel(op)
        fn = f"`{fn}`" if fn in SWIFT_KEYWORDS else fn
        out.append("")
        out.append(f"  /// {entry['group']} · {entry['lock']} → `{entry['result']}`")
        body = f"request({json.dumps(op)}" + (f", [{', '.join(pairs)}]" if pairs else "") + ")"
        out.append(f"  static func {fn}({', '.join(args)}) -> [String: JSONValue] {{ {body} }}")
    out += ["}", ""]
    return "\n".join(out)


def ts_name(name: str) -> str:
    return name if re.fullmatch(r"[A-Za-z_$][\w$]*", name) else json.dumps(name)


def render_ts(spec: dict) -> str:
    commands = spec["commands"]
    named = spec.get("types", {})
    lines = [
        "// GENERATED by tool/core_contract.py from crates/vault-core/contract/commands.json.",
        "// Do not edit by hand: change commands.json and run `python3 tool/core_contract.py generate`.",
        "",
        "export const CORE_OPS = [",
        *[f"  {json.dumps(op)}," for op in commands],
        "] as const;",
        "",
        "export type CoreOp = (typeof CORE_OPS)[number];",
        "",
        "/** Request params per op (without `op`). */",
        "export interface CoreParams {",
    ]
    for op, entry in commands.items():
        fields = []
        for raw, ty in entry["params"].items():
            optional = raw.endswith("?")
            name = raw[:-1] if optional else raw
            fields.append(f"{ts_name(name)}{'?' if optional else ''}: {TS_TYPES[ty]}")
        body = "{ " + "; ".join(fields) + " }" if fields else "{}"
        lines.append(f"  /** {entry['group']} · {entry['lock']} → {entry['result']} */")
        lines.append(f"  {json.dumps(op)}: {body};")
    lines += [
        "}",
        "",
        "/** A typed vault-core request: excess or misspelled fields fail type-checking. */",
        "export type CoreRequest = { [K in CoreOp]: { op: K } & CoreParams[K] }[CoreOp];",
        "",
        "/** Named result shapes (`types` in commands.json). */",
    ]
    for name, definition in named.items():
        lines.append(f"export type Core{name} = {result_ts(definition, set(named), name)};")
    lines += ["", "/** Documented result shape per op (`result` in commands.json). */", "export interface CoreResults {"]
    for op, entry in commands.items():
        lines.append(f"  {json.dumps(op)}: {result_ts(entry['result'], set(named), op)};")
    lines += ["}", ""]
    return "\n".join(lines)


OPEN, CLOSE = "([{", ")]}"


def _skip_string(text: str, i: int) -> int:
    """Return the index just past the string literal starting at text[i] == '"'."""
    i += 1
    while i < len(text) and text[i] != '"':
        i += 2 if text[i] == "\\" else 1
    return i + 1


def _top_level_keys(text: str, start: int, key: re.Pattern[str]) -> list[str] | None:
    """Keys matched by `key` at nesting depth 1 of the bracket opened at text[start]."""
    depth, i, keys = 0, start, []
    while i < len(text):
        c = text[i]
        if c == '"':
            if depth == 1:
                m = key.match(text, i)
                if m:
                    keys.append(m.group(1))
            i = _skip_string(text, i)
            continue
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth -= 1
            if depth == 0:
                return keys
        i += 1
    return None


def _enclosing(text: str, pos: int, opener: str) -> int | None:
    """Index of the innermost unclosed `opener` before pos (string-unaware, local scan)."""
    depth = 0
    for i in range(pos - 1, max(-1, pos - 400), -1):
        c = text[i]
        if c in CLOSE:
            depth += 1
        elif c in OPEN:
            if depth == 0:
                return i if c == opener else None
            depth -= 1
    return None


KOTLIN_PUT = re.compile(r'"([A-Za-z_]\w*)"')
SWIFT_KEY = re.compile(r'"([A-Za-z_]\w*)"\s*:')


def request_keys(label: str, text: str, match: re.Match[str]) -> list[str] | None:
    """Best-effort literal request keys for a matched call site (None when not a literal)."""
    if label == "Kotlin" and match.group(0).startswith(("command", "raw", "mutate")):
        call = text.index("(", match.start())
        depth, i, keys = 0, call, []
        while i < len(text):
            c = text[i]
            if c == '"':
                i = _skip_string(text, i)
                continue
            if c in OPEN:
                depth += 1
            elif c in CLOSE:
                depth -= 1
                if depth == 0:
                    return keys
            elif depth == 1 and text.startswith(".put(", i):
                m = KOTLIN_PUT.match(text, i + 5)
                if m:
                    keys.append(m.group(1))
            i += 1
        return None
    if label == "Swift" and match.group(0).startswith('"op"'):
        start = _enclosing(text, match.start(), "[")
        if start is None:
            return None
        keys = _top_level_keys(text, start, SWIFT_KEY)
        return None if keys is None else [k for k in keys if k != "op"]
    return None


def scan(commands: dict) -> list[str]:
    known = set(commands)
    problems = []
    for label, roots, patterns in SCANS:
        for root in roots:
            for path in sorted((ROOT / root).rglob("*")):
                if path.suffix not in EXTENSIONS[label] or not path.is_file() or ".generated." in path.name:
                    continue
                text = path.read_text(errors="replace")
                for pattern in patterns:
                    for match in pattern.finditer(text):
                        line = text.count("\n", 0, match.start()) + 1
                        where = f"{label}: {path.relative_to(ROOT)}:{line}"
                        ops = [op for op in match.groups() if op]
                        for op in ops:
                            if op not in known:
                                problems.append(f"{where}: unregistered op {op!r}")
                        # Unknown param names only: requests are often completed across several
                        # statements, so missing required params are left to the core's own checks.
                        keys = request_keys(label, text, match)
                        if keys is None or not all(op in known for op in ops):
                            continue
                        allowed = {name.rstrip("?") for op in ops for name in commands[op]["params"]}
                        for key in keys:
                            if key not in allowed:
                                problems.append(f"{where}: {'/'.join(ops)!r} has no param {key!r}")
    return problems


# ---- usage matrix ----------------------------------------------------------------------
# Literal requests plus calls to the generated builders. The browser extension talks to a
# separate wasm dispatcher (crates/vault-core/src/browser.rs) that is not gated by this
# registry, so its column only reports op names it shares with the native core.
MATRIX_CLIENTS: list[tuple[str, tuple[str, ...], tuple[str, ...], list[re.Pattern[str]]]] = [
    ("desktop", ("apps/desktop/ui", "apps/desktop/src"), (".ts", ".tsx", ".rs"),
     [re.compile(r'\bop:\s*"([a-z0-9-]+)"'), re.compile(r'\\?"op\\?"\s*:\s*\\?"([a-z0-9-]+)')]),
    ("android", ("apps/android/app/src/main",), (".kt",),
     [*SCANS[0][2], re.compile(r'\bCoreRequest\.`?([A-Za-z0-9]+)`?\(')]),
    ("ios", ("apps/ios/Sources", "apps/ios/Autofill", "apps/shared/Relay", "apps/shared/Capabilities"), (".swift",),
     [*SCANS[1][2], re.compile(r'\bCoreRequest\.`?([A-Za-z0-9]+)`?\(')]),
    ("browser*", ("apps/browser/src",), (".ts", ".tsx"),
     [re.compile(r'\bop:\s*"([a-z0-9-]+)"'), re.compile(r'op\s*===?\s*"([a-z0-9-]+)"'),
      # core.ts forwards UI requests whose op is on a one-name-per-line allow-list.
      re.compile(r'^\s*"([a-z0-9-]+)",\s*$', re.MULTILINE)]),
]


def usage(commands: dict) -> dict[str, set[str]]:
    by_camel = {camel(op): op for op in commands}
    used: dict[str, set[str]] = {op: set() for op in commands}
    for client, roots, suffixes, patterns in MATRIX_CLIENTS:
        for root in roots:
            for path in (ROOT / root).rglob("*"):
                if path.suffix not in suffixes or not path.is_file() or ".generated." in path.name:
                    continue
                text = path.read_text(errors="replace")
                for pattern in patterns:
                    for match in pattern.finditer(text):
                        for name in filter(None, match.groups()):
                            op = name if name in commands else by_camel.get(name)
                            if op in used:
                                used[op].add(client)
    return used


def print_matrix(commands: dict, args: list[str]) -> int:
    clients = [c[0] for c in MATRIX_CLIENTS]
    missing = args[args.index("--missing") + 1] if "--missing" in args else None
    group = args[args.index("--group") + 1] if "--group" in args else None
    if missing and missing not in clients:
        print(f"--missing expects one of: {', '.join(clients)}", file=sys.stderr)
        return 2
    used = usage(commands)
    rows = []
    for op, entry in commands.items():
        if group and entry["group"] != group:
            continue
        who = used[op]
        if "--unused" in args and who:
            continue
        native_users = who - {missing, "browser*"}
        if missing and (missing in who or not native_users):
            continue
        rows.append((op, entry["group"], who))
    width = max([len(op) for op, _, _ in rows] + [2])
    print(f"{'op':<{width}}  {'group':<15} " + " ".join(f"{c:<9}" for c in clients))
    for op, grp, who in rows:
        print(f"{op:<{width}}  {grp:<15} " + " ".join(f"{('●' if c in who else '·'):<9}" for c in clients))
    print(f"\n{len(rows)} op(s). ● = a request for it is built in that client's sources (heuristic scan).")
    print("browser* talks to its own wasm dispatcher; ops with no ● may still be reached internally (core-to-core) or be dead.")
    return 0


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def main(argv: list[str]) -> int:
    mode = argv[1] if len(argv) > 1 else "check"
    spec = load_spec()
    commands = spec["commands"]
    if mode == "matrix":
        return print_matrix(commands, argv[2:])
    try:
        outputs = {TS_OUT: render_ts(spec), KT_OUT: render_kotlin(commands), SWIFT_OUT: render_swift(commands)}
    except ValueError as error:
        print(f"commands.json: {error}", file=sys.stderr)
        return 1
    if mode == "generate":
        for path, text in outputs.items():
            path.write_text(text)
            print(f"wrote {rel(path)} ({len(commands)} ops)")
        return 0
    if mode != "check":
        print(__doc__, file=sys.stderr)
        return 2
    problems = []
    for path, text in outputs.items():
        if not path.exists() or path.read_text() != text:
            problems.append(f"{rel(path)} is stale: run `python3 tool/core_contract.py generate`")
    problems += scan(commands)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print(f"core contract ok ({len(commands)} ops)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
