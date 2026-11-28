#!/usr/bin/env bash
#
# Ad-hoc sign an iCTRL .ipa for a JAILBROKEN device — no Apple ID, no profile,
# no 7-day expiry.
#
#   Scripts/sign-adhoc.sh -i iCTRLUITests-Runner.ipa [-o out.ipa]
#       [-b BUNDLE_ID]       override the package's bundle id (default: keep it)
#       [-m MIN_IOS]         lower the package's minimum iOS version, e.g. 16.0
#       [-u]                 install the result with ideviceinstaller
#       [-d UDID]            device for -u; default: the first connected one
#
# Requires: macOS `codesign`, a jailbreak with AppSync Unified (installd/amfid
# patched to accept any signature), and libimobiledevice for -u.
#
# Why this works and TrollStore doesn't: the runner is an XCUITest host with a
# nested test bundle, PlugIns/iCTRLUITests.xctest. That bundle needs its OWN
# signature, applied before the app around it (inside out), and it has to carry
# the runner's bundle identifier. TrollStore re-signs packages with `ldid`,
# which only recurses into .framework/.appex and leaves the .xctest behind: the
# package installs and then dies at launch with "mapped file has no cdhash".
# `codesign` recurses where we tell it to, so the nested bundle is signed too.
#
# Entitlements: get-task-allow is what lets idevicedebug attach and launch the
# runner. The team identifier below is a placeholder — with AppSync nothing
# compares it against a certificate.
#
# -m is a compatibility escape hatch, not a supported build. The release runner
# is built against the iOS 17 SDK; lowering both the plist minimum and every
# packaged Mach-O's LC_BUILD_VERSION lets it start on iOS 16, and the calls it
# uses resolve against the 16.x XCTest that ships on the device. Verify on your
# own device before relying on it — for a proper iOS 16 host, see #15.

set -euo pipefail

usage() {
    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

IPA="" OUT="" BID="" MINIOS="" INSTALL=0 UDID=""
while getopts "i:o:b:m:d:uh" opt; do
    case "$opt" in
        i) IPA="$OPTARG" ;;
        o) OUT="$OPTARG" ;;
        b) BID="$OPTARG" ;;
        m) MINIOS="$OPTARG" ;;
        u) INSTALL=1 ;;
        d) UDID="$OPTARG" ;;
        *) usage ;;
    esac
done
[[ -n "$IPA" ]] || usage
[[ -f "$IPA" ]] || { echo "❌ No such ipa: $IPA" >&2; exit 1; }
OUT="${OUT:-${IPA%.ipa}-adhoc.ipa}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PB=/usr/libexec/PlistBuddy
TEAM="AAAAAAAAAA"   # placeholder; not checked against any certificate

# ── Unpack ────────────────────────────────────────────────────────────────
echo "📦 Unpacking $(basename "$IPA")"
unzip -q "$IPA" -d "$WORK"
APP="$(ls -d "$WORK"/Payload/*.app | head -1)"
[[ -d "$APP" ]] || { echo "❌ No Payload/*.app in $IPA" >&2; exit 1; }

BID="${BID:-$($PB -c 'Print :CFBundleIdentifier' "$APP/Info.plist")}"
echo "🔏 Ad-hoc signing $BID"

# ── Bundle id / minimum version ───────────────────────────────────────────
# The nested .xctest shares the host's bundle id instead of extending it the
# way an .appex does, so both plists have to agree before anything is sealed.
$PB -c "Set :CFBundleIdentifier $BID" "$APP/Info.plist"
[[ -n "$MINIOS" ]] && $PB -c "Set :MinimumOSVersion $MINIOS" "$APP/Info.plist"

for xctest in "$APP"/PlugIns/*.xctest; do
    [[ -d "$xctest" ]] || continue
    $PB -c "Set :CFBundleIdentifier $BID" "$xctest/Info.plist"
    [[ -n "$MINIOS" ]] && $PB -c "Set :MinimumOSVersion $MINIOS" "$xctest/Info.plist"
    echo "   aligned $(basename "$xctest") → $BID"
done

if [[ -n "$MINIOS" ]]; then
    command -v vtool >/dev/null || { echo "❌ -m needs vtool (Xcode command line tools)" >&2; exit 1; }
    echo "   lowering Mach-O minimum to iOS $MINIOS"
    while IFS= read -r bin; do
        file -b "$bin" | grep -q 'Mach-O' || continue
        vtool -set-build-version ios "$MINIOS" "$MINIOS" -replace -output "$bin.new" "$bin" 2>/dev/null \
            && mv "$bin.new" "$bin" \
            || echo "   ⚠️  skipped ${bin#"$APP"/} (no LC_BUILD_VERSION)" >&2
    done < <(find "$APP" -type f \( -perm -111 -o -name '*.dylib' \) -not -path '*_CodeSignature*')
fi

# ── Entitlements ──────────────────────────────────────────────────────────
ENT="$WORK/entitlements.plist"
cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>$TEAM.$BID</string>
    <key>com.apple.developer.team-identifier</key>
    <string>$TEAM</string>
    <key>get-task-allow</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>$TEAM.$BID</string>
    </array>
</dict>
</plist>
EOF

sign() {
    local out
    out="$(codesign --force --timestamp=none --sign - "$@" 2>&1)" || {
        echo "$out" >&2; return 1; }
}

# ── Inside out: loose dylibs, frameworks, plug-ins, then the app ──────────
rm -rf "$APP/_CodeSignature"
while IFS= read -r f; do
    sign "$f"; echo "   signed ${f#"$APP/"}"
done < <(find "$APP" -name '*.dylib' -not -path '*.framework/*' | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

while IFS= read -r f; do
    sign "$f"; echo "   signed ${f#"$APP/"}"
done < <(find "$APP" -name '*.framework' -type d | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

for plugin in "$APP"/PlugIns/*; do
    [[ -d "$plugin" ]] || continue
    sign "$plugin"; echo "   signed ${plugin#"$APP/"}"
done

sign --entitlements "$ENT" "$APP"
echo "   signed $(basename "$APP")"

# ── Verify every nested binary (an unsigned dylib fails at launch, not here) ─
failed=0
while IFS= read -r f; do
    codesign --verify --strict "$f" 2>/dev/null || { echo "❌ not validly signed: ${f#"$APP/"}" >&2; failed=1; }
done < <(find "$APP" \( -name '*.dylib' -o -name '*.framework' -o -name '*.xctest' -o -name '*.appex' \) -not -path '*.framework/*/*')
codesign --verify --deep --strict "$APP" || failed=1
[[ $failed == 0 ]] || { echo "❌ Verification failed — not writing $OUT" >&2; exit 1; }

# ── Repack ────────────────────────────────────────────────────────────────
OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
rm -f "$OUT_ABS"
(cd "$WORK" && zip -qry "$OUT_ABS" Payload)
echo "✅ $OUT"

# ── Optional install ──────────────────────────────────────────────────────
if [[ $INSTALL == 1 ]]; then
    command -v ideviceinstaller >/dev/null || { echo "❌ -u needs libimobiledevice (brew install libimobiledevice)" >&2; exit 1; }
    UDID="${UDID:-$(idevice_id -l | head -1)}"
    [[ -n "$UDID" ]] || { echo "❌ No device found; connect over USB or pass -d" >&2; exit 1; }
    echo "📲 Installing on $UDID"
    ideviceinstaller -u "$UDID" install "$OUT_ABS"
fi

cat <<EOF
   Next: remount the DDI after every reboot, then launch the runner:
     idevicedebug -u ${UDID:-<UDID>} -e ICTRL_ALLOW_AUTH_ONCE=1 --detach run $BID
EOF
