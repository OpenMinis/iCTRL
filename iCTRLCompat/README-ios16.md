# Source-built iOS 16.3 runner (experimental)

The project's test target already deploys to iOS 16.0, but `build-for-testing`
copies a prebuilt XCTRunner executable out of Xcode. In the tested Xcode 27.2
(27B52) installation, that executable and its Info.plist require iOS 17.0.
`IPHONEOS_DEPLOYMENT_TARGET=16.0` only recompiles the test bundle. Lowering the
host's plist or patching its Mach-O minimum cannot prove binary compatibility.

This optional path compiles `RunnerIOS16.m` as an arm64 **iOS 16.3** application
and packages the existing test target compiled for **iOS 16.0**. It does not
build the optional companion app, modify the ordinary generated Xcode project,
or require its IDevice download. No version load command is patched.

## Prerequisites

- macOS with Xcode command-line tools, Python 3.9+ and XcodeGen (tested: 2.48.0).
- A compatible iOS 16 Developer Disk Image from your development setup. Mount
  its filesystem read-only on the Mac so the linker can read its
  `Library/Frameworks/XCTest.framework/XCTest`. The script rejects framework
  binaries whose recorded minimum exceeds 16.3.
- A compatible DDI **also mounted on the actual device**. Mounting its filesystem
  on the Mac only supplies linker input; it does not prepare the device. The
  device needs its DDI again after reboot. This build adds no DDI downloader or
  device mounter and does not change the companion app's mounting support.
- Developer Mode, UI Automation authorization, and a development signing route
  that handles the nested `.xctest`, such as current SideStore. The build uses
  ad-hoc signatures, not an Apple development identity or provisioning profile;
  re-signing is required for installation on a stock device.

Do not add Apple's frameworks, disk images, pairing records, or signed device
artifacts to the repository. The DDI is linker input only: Apple's developer
frameworks are not embedded in the resulting IPA.

## Build

From the repository root, with the DDI filesystem already mounted on the Mac:

```sh
python3 Scripts/build-ios16.py \
  --legacy-frameworks /path/to/mounted-DDI/Library/Frameworks
```

Use `--xcodegen /path/to/xcodegen` if it is not on PATH and `--output-dir PATH`
to change the default `release/ios16/`. Generated specs, derived data and staging
files live under `build/ios16/`; the separate ignored project is
`iCTRL-iOS16.xcodeproj`. The runner sources and resources
come from `project.yml` via `xcodegen dump`, not a duplicate project spec.
Like the normal build, this updates `iCTRLKit/BuildStamp.swift`; do not commit
that generated timestamp as part of a source change.

Outputs:

- `iCTRLUITests-Runner-iOS16.ipa`: ad-hoc package for subsequent re-signing.
- `verification.json`: host/test Info.plist minima, minima read from every
  packaged Mach-O, and the IPA SHA-256.
- `xctest-build.log` and `runner-build.log`: local compiler output, which may
  contain local filesystem paths and should be reviewed before sharing.

The host weak-links the legacy XCTest **at link time**, so dyld initializes it
before UIKit starts. It loads the test bundle, uses the classic application
delegate lifecycle, and schedules `_XCTestMain(nil)` once on the main run loop.
The nil configuration follows the device XCTest runtime's default/configured
launch path; no fake replacement XCTest implementation is provided. This uses
private XCTest interfaces and may need changes for other runtimes.

Only this host opts out of `EarlyURLHook`'s pre-bootstrap auto-backgrounding.
Keep it unlocked and in front while authorizing automation. It shows readiness
after the configured local port answers `GET /schema`; it never infers the UI
Automation setting from a timeout, retries `_XCTestMain` in the same process, or
automatically unmounts an active DDI.

## Verify and install

The script checks the host and test plist minima separately, inspects the actual
version load commands in **all packaged Mach-O files**, verifies signatures
inside out, rejects provisioning-profile leftovers, and tests ZIP integrity.
A plist at 16.3 cannot make a binary requiring 17.0 pass these checks.
You can repeat the app checks independently before packaging:

```sh
python3 Scripts/build-ios16.py --verify-app \
  build/ios16/package/Payload/iCTRLUITests-Runner.app
```

The version-gate regression checks use real, small clang-built Mach-O fixtures
and ad-hoc signatures; no DDI, account or device is needed:

```sh
python3 Scripts/test-ios16-verification.py -v
```

They check a compatible package, a newer host hidden behind a low plist, a
newer test binary hidden behind a low plist, and a newer test plist.

Install with a signer that re-signs the nested test bundle first, followed by
the host. See [the main installation instructions](../README.md#installation).
The same bundle-id alignment as `make ipa` is retained; this does not address
the separate iLoader naming proposal in PR #12. Do not treat ad-hoc signature
verification as proof of a valid device provisioning profile after re-signing.

## Device evidence and remaining scope

The earlier development version of this host was built with Xcode 27.2 / iOS
27.2 SDK and installed through SideStore on one iPad13,11 running iPadOS 16.3.1.
After stopping a failing runner and unmounting/remounting the device DDI, a fresh
launch reached `testStartServer`; `GET /schema` through USB returned HTTP 200
with 67,247 response-body bytes. The user also confirmed successful startup.
Host Mach-O/Info.plist minima were 16.3, and test minima were 16.0.

Earlier attempts, including a computer-driven test session, timed out after
about 60 seconds while enabling automation despite UI Automation being enabled.
The successful launch followed the source-host changes, authorization and a
fresh DDI/testmanagerd session. The ordering does **not** establish remounting
as the sole cause or justify automatic remounting on every timeout.

The contribution refactors the build entry point and adds English fallback and
configured-port status display. Its compilation/package checks are separate
from that earlier device result. Encrypted pairing, screen reading, taps,
long-running stability, the companion app and other iOS versions have not been
independently validated here. In particular, neither iOS 16.0 support nor
complete iOS 16 automation coverage is claimed by this experiment.
