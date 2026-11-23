import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import core_contract as contract

ROOT = Path(__file__).resolve().parent.parent


class ResultNotationTests(unittest.TestCase):
    def ts(self, text, named=("Item",)):
        return contract.result_ts(text, set(named))

    def test_objects_arrays_unions_literals(self):
        self.assertEqual(self.ts("{ok:true}"), "{ ok: true }")
        self.assertEqual(self.ts("{a?:string[],b:'x'|null}"), '{ a?: Array<string>; b: "x" | null }')
        self.assertEqual(self.ts("{id,title}[]"), "Array<{ id: unknown; title: unknown }>")
        self.assertEqual(self.ts("Item & {prf?:object}"), "CoreItem & { prf?: Record<string, unknown> }")
        self.assertEqual(self.ts("{version:2}"), "{ version: 2 }")
        self.assertEqual(self.ts("Record<string,string>"), "Record<string, string>")

    def test_unknown_names_and_garbage_are_rejected(self):
        for bad in ("{x:Foo}", "{a:", "{a:string", "string]", "{a b}"):
            with self.assertRaises(ValueError, msg=bad):
                self.ts(bad)

    def test_every_registered_result_parses(self):
        spec = contract.load_spec()
        named = set(spec.get("types", {}))
        for op, entry in spec["commands"].items():
            contract.result_ts(entry["result"], named, op)


class GeneratorTests(unittest.TestCase):
    def test_builders_escape_keywords_and_order_required_params_first(self):
        commands = {"import": {"group": "g", "lock": "none", "params": {"kind?": "string", "content": "string"}, "result": "{}"}}
        kotlin, swift = contract.render_kotlin(commands), contract.render_swift(commands)
        self.assertIn('fun import(content: String, kind: String? = null): JSONObject = request("import", "content" to content, "kind" to kind)', kotlin)
        self.assertIn("static func `import`(content: String, kind: String? = nil)", swift)
        self.assertIn('("kind", kind.map { .string($0) })', swift)

    def test_generated_files_are_current(self):
        self.assertEqual(contract.main(["core_contract.py", "check"]), 0)


class NewOpTests(unittest.TestCase):
    def test_registers_next_to_its_group_and_regenerates(self):
        with tempfile.TemporaryDirectory() as temp:
            spec_path = Path(temp) / "commands.json"
            spec_path.write_text(contract.SPEC.read_text())
            outputs = [Path(temp) / name for name in ("a.ts", "b.kt", "c.swift")]
            script = f"""
import sys, runpy
sys.path.insert(0, {str(ROOT / 'tool')!r})
import core_contract as c
from pathlib import Path
c.SPEC = Path({str(spec_path)!r})
c.TS_OUT, c.KT_OUT, c.SWIFT_OUT = [Path(p) for p in {[str(p) for p in outputs]!r}]
c.main = (lambda original: (lambda argv: original(argv)))(c.main)
import subprocess
subprocess.run = lambda *a, **k: c.main(["core_contract.py", "generate"])
sys.argv = ["new_op.py", "note-pin", "--group", "notes", "--lock", "unlocked", "--param", "id:string", "--result", "{{ok:true}}"]
runpy.run_path({str(ROOT / 'tool/new_op.py')!r}, run_name="__main__")
"""
            result = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            names = list(json.loads(spec_path.read_text())["commands"])
            self.assertIn("note-pin", names)
            notes = [op for op in names if json.loads(spec_path.read_text())["commands"][op]["group"] == "notes"]
            self.assertEqual(names.index("note-pin"), names.index(notes[-1]))
            self.assertIn("notePin", outputs[1].read_text())


if __name__ == "__main__":
    unittest.main()
