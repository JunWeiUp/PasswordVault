"""Exercise the shell orchestration with fake compilers; no SDK download is needed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class MobileBuildSelectionTests(unittest.TestCase):
    def build(self, platform, **options):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'tool').mkdir()
            shutil.copy(Path(__file__).with_name('build_mobile_core.sh'), root / 'tool/build_mobile_core.sh')
            binaries = root / 'bin'
            binaries.mkdir()
            # Fake binaries produce just the files copied/packaged by the real script.
            script = '''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f: f.write(json.dumps([name,*args])+'\\n')
if name=='uname': print('arm64' if '-m' in args else 'Darwin')
elif name=='rustup': print(str(Path(sys.argv[0]).parent/'rustc'))
elif name=='cargo':
    if '--target' in args:
        folder=Path('target')/args[args.index('--target')+1]/'release'; folder.mkdir(parents=True,exist_ok=True)
        for file in ['libvault_core.a','libvault_core.so']: (folder/file).write_text('synthetic')
    if '--out-dir' in args:
        folder=Path(args[args.index('--out-dir')+1]); folder.mkdir(parents=True,exist_ok=True)
        for file in ['VaultCoreFFI.h','VaultCoreFFI.modulemap']: (folder/file).write_text('synthetic')
elif name=='lipo': Path(args[args.index('-output')+1]).write_text('synthetic universal')
elif name=='xcodebuild': Path(args[args.index('-output')+1]).mkdir(parents=True)
'''
            for name in ['uname', 'rustup', 'cargo', 'lipo', 'xcodebuild']:
                file = binaries / name
                file.write_text(script)
                file.chmod(0o755)
            clang = root / 'ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang'
            clang.parent.mkdir(parents=True)
            clang.touch()
            clang.chmod(0o755)
            result = subprocess.run(['bash', str(root / 'tool/build_mobile_core.sh'), platform], cwd=root,
                env={**os.environ, 'PATH': str(binaries)+os.pathsep+os.environ['PATH'],
                     'CALLS': str(root/'calls'), 'PASSWORDVAULT_NDK': str(root/'ndk'), **options},
                capture_output=True, text=True)
            calls = [json.loads(line) for line in (root/'calls').read_text().splitlines()]
            targets = [call[call.index('--target')+1] for call in calls if call[0]=='cargo' and '--target' in call]
            return result, targets, calls

    def test_android_default_keeps_both_abis(self):
        result, targets, _ = self.build('android')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(targets, ['aarch64-linux-android', 'x86_64-linux-android'])

    def test_android_ci_builds_only_packaged_abi(self):
        result, targets, _ = self.build('android', PASSWORDVAULT_ANDROID_ABI='arm64-v8a')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(targets, ['aarch64-linux-android'])

    def test_ios_default_keeps_device_and_universal_simulator(self):
        result, targets, calls = self.build('ios')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(targets, ['aarch64-apple-ios', 'aarch64-apple-ios-sim', 'x86_64-apple-ios'])
        self.assertTrue(any(call[0]=='lipo' for call in calls))

    def test_ios_host_still_compiles_device(self):
        result, targets, calls = self.build('ios', PASSWORDVAULT_IOS_SIM_ARCH='host')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(targets, ['aarch64-apple-ios', 'aarch64-apple-ios-sim'])
        self.assertFalse(any(call[0]=='lipo' for call in calls))

    def test_ios_intel_simulator(self):
        result, targets, _ = self.build('ios', PASSWORDVAULT_IOS_SIM_ARCH='x86_64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(targets, ['aarch64-apple-ios', 'x86_64-apple-ios'])

    def test_invalid_architectures_fail_before_compilation(self):
        for platform, options in [('android', {'PASSWORDVAULT_ANDROID_ABI': 'invalid'}),
                                  ('ios', {'PASSWORDVAULT_IOS_SIM_ARCH': 'invalid'})]:
            result, targets, _ = self.build(platform, **options)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(targets, [])


if __name__ == '__main__':
    unittest.main()
