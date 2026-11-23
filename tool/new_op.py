#!/usr/bin/env python3
"""Scaffold a new vault-core command.

  python3 tool/new_op.py note-pin --group notes --lock unlocked \\
      --param id:string --param pinned?:bool --result '{ok:true}' [--notes "..."] [--dry-run]

Registers the op in crates/vault-core/contract/commands.json (next to its group),
regenerates the TypeScript/Kotlin/Swift request builders and prints the remaining
checklist with the files that already handle the same group. It never writes Rust or
client code: the handler and its tests are yours to write.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tool"))
import core_contract as contract  # noqa: E402

TYPES = set(contract.TS_TYPES)


def parse_param(text: str) -> tuple[str, str]:
    name, _, ty = text.partition(":")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\??", name) or ty not in TYPES or name.rstrip("?") == "op":
        raise argparse.ArgumentTypeError(f"--param expects name[?]:type with type in {sorted(TYPES)}, got {text!r}")
    return name, ty


def handler_files(commands: dict, group: str) -> list[str]:
    """Rust files that already match on an op of this group (where the new arm belongs)."""
    ops = [op for op, entry in commands.items() if entry["group"] == group]
    found: dict[str, int] = {}
    for path in (ROOT / "crates/vault-core/src").rglob("*.rs"):
        text = path.read_text()
        hits = sum(text.count(f'"{op}" =>') + text.count(f'"{op}" |') for op in ops)
        if hits:
            found[str(path.relative_to(ROOT))] = hits
    return sorted(found, key=lambda p: -found[p])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("op", help="kebab-case op name")
    parser.add_argument("--group", required=True)
    parser.add_argument("--lock", required=True, choices=["unlocked", "none"])
    parser.add_argument("--param", action="append", type=parse_param, default=[])
    parser.add_argument("--result", required=True, help="result shape, e.g. '{ok:true}'")
    parser.add_argument("--notes")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    spec = contract.load_spec()
    commands = spec["commands"]
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.op):
        parser.error("op names are kebab-case")
    if args.op in commands:
        parser.error(f"{args.op} is already registered")
    groups = {entry["group"] for entry in commands.values()}
    if args.group not in groups:
        print(f"note: new group {args.group!r} (existing: {', '.join(sorted(groups))})")
    try:
        contract.result_ts(args.result, set(spec.get("types", {})), args.op)
    except ValueError as error:
        parser.error(str(error))

    entry = {"group": args.group, "lock": args.lock, "params": dict(args.param), "result": args.result}
    if args.notes:
        entry["notes"] = args.notes
    names = list(commands)
    last = max((i for i, op in enumerate(names) if commands[op]["group"] == args.group), default=len(names) - 1)
    ordered = names[: last + 1] + [args.op] + names[last + 1:]
    spec["commands"] = {op: (entry if op == args.op else commands[op]) for op in ordered}

    camel = contract.camel(args.op)
    files = handler_files(commands, args.group)
    print(json.dumps({args.op: entry}, indent=2, ensure_ascii=False))
    if not args.dry_run:
        contract.SPEC.write_text(json.dumps(spec, indent=2, ensure_ascii=False) + "\n")
        subprocess.run([sys.executable, str(ROOT / "tool/core_contract.py"), "generate"], check=True)
    print(f"""
Next steps for {args.op}:
  1. Rust handler — add a `"{args.op}" =>` arm next to the other {args.group!r} ops in:
       {chr(10).join('       ' + f for f in files) .strip() or '(no existing handler for this group: add one and route it from native.rs)'}
     lock={args.lock}: {'call self.open()? first; the registry test `unlocked_ops_refuse_while_locked` checks this automatically.' if args.lock == 'unlocked' else 'must not require an unlocked vault.'}
  2. Core test next to that handler (success + at least one failure path).
  3. Clients (only those that need it; see `python3 tool/core_contract.py matrix --group {args.group}`):
       desktop  call({{ op: "{args.op}", ... }})   — params and result typed from the registry
       android  CoreRequest.{camel}(...)
       ios      CoreRequest.{camel}(...)
  4. Verify: python3 tool/check_changed.py
""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
