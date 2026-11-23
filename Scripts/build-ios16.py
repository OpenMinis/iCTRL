#!/usr/bin/env python3
"""Build an opt-in iOS 16.3 runner from source, without patching Mach-O minos."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
HOST_MINIMUM = "16.3"
TEST_MINIMUM = "16.0"
RUNNER = "iCTRLUITests-Runner"
XCTEST = "iCTRLUITests.xctest"
MACHO_MAGICS = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                b"\xca\xfe\xba\xbf", b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"}


def run(*args, log=None):
    print("+", " ".join(map(str, args)), flush=True)
    if log:
        with log.open("w") as stream:
            subprocess.run(args, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, check=True)
    else:
        subprocess.run(args, cwd=ROOT, check=True)


def version(value):
    return tuple((list(map(int, value.split("."))) + [0, 0])[:3])


def binary_minimum(path):
    # Check the actual load commands, including binaries using the older command.
    commands = subprocess.check_output(["xcrun", "otool", "-l", str(path)], text=True)
    minimums = []
    for block in re.split(r"Load command \d+", commands)[1:]:
        if re.search(r"\bcmd LC_BUILD_VERSION\b", block):
            platform = re.search(r"\bplatform (\S+)", block)
            if not platform or platform[1].upper() not in {"IOS", "2"}:
                raise ValueError(f"Not an iOS device binary: {path}")
            minimums += re.findall(r"\bminos ([\d.]+)", block)
        elif re.search(r"\bcmd LC_VERSION_MIN_IPHONEOS\b", block):
            minimums += re.findall(r"\bversion ([\d.]+)", block)
    if not minimums:
        raise ValueError(f"No iOS minimum-version command: {path}")
    if any(version(v) > version(HOST_MINIMUM) for v in minimums):
        raise ValueError(f"{path}: binary minimum {minimums} exceeds {HOST_MINIMUM}")
    return minimums


def verify_app(app):
    report = {"maximumMinimumOSVersion": HOST_MINIMUM, "plists": {}, "binaries": {}}
    for bundle in (app, app / "PlugIns" / XCTEST):
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        minimum = info.get("MinimumOSVersion")
        if not minimum or version(minimum) > version(HOST_MINIMUM):
            raise ValueError(f"{bundle}: invalid MinimumOSVersion {minimum!r}")
        executable = bundle / info["CFBundleExecutable"]
        if not executable.is_file():
            raise ValueError(f"Missing executable: {executable}")
        report["binaries"][str(executable.relative_to(app))] = binary_minimum(executable)
        report["plists"][str(bundle.relative_to(app.parent))] = minimum
    for path in sorted(app.rglob("*")):
        if path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
            if magic in MACHO_MAGICS:
                report["binaries"][str(path.relative_to(app))] = binary_minimum(path)
    for bundle in (app / "PlugIns" / XCTEST, app):
        run("codesign", "--verify", "--deep", "--strict", str(bundle))
    if list(app.rglob("*.mobileprovision")):
        raise ValueError("A provisioning profile survived the unsigned build")
    return report


def build(args):
    legacy = args.legacy_frameworks.resolve()
    legacy_binary = legacy / "XCTest.framework/XCTest"
    if not legacy_binary.is_file():
        raise ValueError("--legacy-frameworks must contain XCTest.framework/XCTest")
    binary_minimum(legacy_binary)  # Reject modern XCTest before starting a build.
    xcodegen = args.xcodegen or shutil.which("xcodegen")
    if not xcodegen:
        raise ValueError("Install XcodeGen or pass --xcodegen /path/to/xcodegen")
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    build_dir = ROOT / "build/ios16"
    project_dir = build_dir / "project"
    project_dir.mkdir(parents=True, exist_ok=True)
    # Derive the runner target from the maintained spec, rather than maintaining
    # another source/resource list or fetching the companion's IDevice library.
    spec = json.loads(subprocess.check_output([
        xcodegen, "dump", "--spec", str(ROOT / "project.yml"), "--type", "json", "--no-env"], text=True))
    target = spec["targets"]["iCTRLUITests"]
    target.pop("dependencies", None)
    spec["targets"] = {"iCTRLUITests": target}
    spec["name"] = "iCTRL-iOS16"
    spec["schemes"]["iCTRL"]["build"]["targets"] = {"iCTRLUITests": ["test"]}
    spec_path = project_dir / "project.json"
    spec_path.write_text(json.dumps(spec, indent=2) + "\n")
    run(xcodegen, "generate", "--spec", str(spec_path), "--project-root", str(ROOT),
        "--project", str(ROOT))
    run("bash", "Scripts/stamp-build.sh")
    defaults = (ROOT / "Config/Signing.xcconfig").read_text()
    prefix = re.search(r"^ICTRL_BUNDLE_PREFIX\s*=\s*(\S+)", defaults, re.MULTILINE)[1]
    run("xcodebuild", "build-for-testing", "-project", str(ROOT / "iCTRL-iOS16.xcodeproj"),
        "-scheme", "iCTRL", "-derivedDataPath", str(build_dir / "derived"),
        "-destination", "generic/platform=iOS", "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM=",
        "ICTRL_BUNDLE_PREFIX=" + prefix, "ARCHS=arm64", "IPHONEOS_DEPLOYMENT_TARGET=" + TEST_MINIMUM,
        log=output / "xctest-build.log")
    stage = build_dir / "package"
    if stage.exists():
        shutil.rmtree(stage)
    app = stage / "Payload" / (RUNNER + ".app")
    shutil.copytree(build_dir / "derived/Build/Products/Debug-iphoneos" / app.name, app)
    # The device supplies XCTest from its mounted DDI. Never redistribute Apple
    # developer frameworks; never run Xcode's iOS 17+ prebuilt host on iOS 16.
    for path in (app / "Frameworks").glob("*"):
        if path.name.startswith(("XC", "libXCTest")) or path.name == "Testing.framework":
            shutil.rmtree(path) if path.is_dir() else path.unlink()
    for path in app.rglob("*.dSYM"):
        shutil.rmtree(path)
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    run("xcrun", "--sdk", "iphoneos", "clang", "-target", "arm64-apple-ios" + HOST_MINIMUM,
        "-isysroot", sdk, "-fobjc-arc", "-fblocks", "-O2", "-F", str(legacy),
        "-F", str(legacy.parent / "PrivateFrameworks"), "-weak_framework", "XCTest",
        "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreFoundation",
        "-Wl,-rpath,@executable_path/Frameworks", "-Wl,-rpath,/Developer/Library/Frameworks",
        "-Wl,-rpath,/Developer/Library/PrivateFrameworks", "-Wl,-rpath,/Developer/usr/lib",
        "-Wl,-rpath,/System/Developer/Library/Frameworks", "-Wl,-rpath,/System/Developer/usr/lib",
        "-o", str(app / RUNNER), str(ROOT / "iCTRLCompat/RunnerIOS16.m"), log=output / "runner-build.log")
    plist_path = app / "Info.plist"
    info = plistlib.loads(plist_path.read_bytes())
    for key in ("UIApplicationSceneManifest", "UIBackgroundModes"):
        info.pop(key, None)
    info.update(MinimumOSVersion=HOST_MINIMUM, ICTRLKeepForegroundDuringBootstrap=True,
                CFBundleDisplayName="iCTRL iOS16",
                NSLocalNetworkUsageDescription="iCTRL needs local network access to serve the automation API on your LAN.",
                NSBonjourServices=["_ictrl._tcp"], CFBundleURLTypes=[{
                    "CFBundleURLName": "com.openminis.ictrl", "CFBundleURLSchemes": ["ictrl"]}])
    for path in (ROOT / "Config/RunnerIcon").glob("*.png"):
        shutil.copy2(path, app / path.name)
    for key, sizes in (("CFBundleIcons", ("20x20", "29x29", "40x40", "60x60")),
                       ("CFBundleIcons~ipad", ("20x20", "29x29", "40x40", "76x76", "83.5x83.5"))):
        info[key] = {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon" + size for size in sizes]}}
    plist_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    test = app / "PlugIns" / XCTEST
    test_info_path = test / "Info.plist"
    test_info = plistlib.loads(test_info_path.read_bytes())
    test_info["CFBundleIdentifier"] = info["CFBundleIdentifier"]  # Same convention as make ipa.
    test_info_path.write_bytes(plistlib.dumps(test_info, fmt=plistlib.FMT_BINARY))
    entitlements = stage / "host-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"get-task-allow": True}))
    for path in sorted((app / "Frameworks").rglob("*.dylib")):
        run("codesign", "--force", "--sign", "-", "--timestamp=none", str(path))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", str(test))
    run("codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements", str(entitlements), str(app))
    report = verify_app(app)
    ipa = output / (RUNNER + "-iOS16.ipa")
    # Write only after all checks, then replace atomically. A failed build must
    # not leave a new incomplete IPA that looks like a successful result.
    temporary = ipa.with_suffix(".ipa.tmp")
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted((stage / "Payload").rglob("*")):
                archive.write(path, path.relative_to(stage))
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA ZIP integrity check failed")
        temporary.replace(ipa)
    finally:
        temporary.unlink(missing_ok=True)
    report["ipaSHA256"] = hashlib.sha256(ipa.read_bytes()).hexdigest()
    (output / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(ipa)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--legacy-frameworks", type=Path, help="Library/Frameworks from a compatible iOS 16 DDI")
    mode.add_argument("--verify-app", type=Path, help="only check an existing signed runner app; no rebuild")
    parser.add_argument("--xcodegen", default=os.environ.get("XCODEGEN"))
    parser.add_argument("--output-dir", type=Path, default=ROOT / "release/ios16")
    args = parser.parse_args()
    try:
        if args.verify_app:
            print(json.dumps(verify_app(args.verify_app.resolve()), indent=2))
        else:
            build(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"iOS 16 build/check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
