#!/usr/bin/env python3
"""Exercise the package gate with real clang-built Mach-O fixtures (macOS/Xcode)."""

import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ios16_build", Path(__file__).with_name("build-ios16.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class MinimumVersionGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(prefix="ictrl-version-tests-")
        cls.root = Path(cls.workspace.name)
        source = cls.root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
        for minimum in ("16.0", "16.3", "17.0"):
            subprocess.run(["xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios" + minimum,
                            "-isysroot", sdk, str(source), "-o", str(cls.root / minimum)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.workspace.cleanup()

    def setUp(self):
        self.case = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(self.case.cleanup)
        self.app = Path(self.case.name) / "Runner.app"
        self.test = self.app / "PlugIns" / builder.XCTEST
        for bundle, executable, minimum, package in (
                (self.app, "Runner", "16.3", "APPL"),
                (self.test, "Tests", "16.0", "BNDL")):
            bundle.mkdir(parents=True)
            info = {"CFBundleIdentifier": "org.example.fixture." + executable,
                    "CFBundleExecutable": executable, "CFBundlePackageType": package,
                    "CFBundleVersion": "1", "MinimumOSVersion": minimum}
            (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
            shutil.copy2(self.root / minimum, bundle / executable)

    def sign(self):
        for bundle in (self.test, self.app):
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(bundle)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)

    def test_compatible_host_and_test_pass(self):
        self.sign()
        report = builder.verify_app(self.app)
        self.assertEqual(report["binaries"]["Runner"], ["16.3"])
        self.assertEqual(report["binaries"]["PlugIns/" + builder.XCTEST + "/Tests"], ["16.0"])

    def test_low_plist_cannot_hide_newer_host(self):
        shutil.copy2(self.root / "17.0", self.app / "Runner")
        self.sign()
        with self.assertRaisesRegex(ValueError, "binary minimum.*17.0"):
            builder.verify_app(self.app)

    def test_low_plist_cannot_hide_newer_test(self):
        shutil.copy2(self.root / "17.0", self.test / "Tests")
        self.sign()
        with self.assertRaisesRegex(ValueError, "binary minimum.*17.0"):
            builder.verify_app(self.app)

    def test_compatible_binary_cannot_hide_newer_plist(self):
        path = self.test / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["MinimumOSVersion"] = "17.0"
        path.write_bytes(plistlib.dumps(info))
        self.sign()
        with self.assertRaisesRegex(ValueError, "invalid MinimumOSVersion"):
            builder.verify_app(self.app)


if __name__ == "__main__":
    unittest.main()
