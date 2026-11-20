#!/usr/bin/env bash
#
# Re-sign an iCTRL .ipa with your own (paid) Apple Developer identity.
#
#   Scripts/sign-ipa.sh -i iCTRLUITests-Runner.ipa [-o out.ipa]
#       [-t TEAMID]          team; default: $DEVELOPMENT_TEAM, then
#                            Config/Local.xcconfig, then the Xcode project
#       [-p PROFILE]         .mobileprovision path, profile UUID or profile name;
#                            default: the best installed development profile
#                            for the team that covers the package's bundle id
#       [-s IDENTITY]        signing identity name or SHA-1; default: the
#                            keychain identity whose certificate is in the profile
#
# Works for both packages (the runner and the iCTRL host app). macOS only — it
# uses Apple's `codesign`.
#
# Why a script and not "any signing tool": the runner is an XCUITest host with a
# nested test bundle, PlugIns/iCTRLUITests.xctest. That bundle needs its OWN
# signature, applied before the app around it (inside out), and it must carry
# an identifier under the runner's (<runner id>.tests). Most signing tools only
# recurse into .framework/.appex, so they leave the .xctest with the original signature: the
# package installs fine and then crashes the moment it launches, because the
# test bundle's signature belongs to a different team than the app loading it.
#
# The provisioning profile must be a DEVELOPMENT profile (get-task-allow = true)
# whose App ID matches the package — a wildcard `TEAMID.*` profile covers both
# packages — and must include the device you are installing on.

set -euo pipefail

usage() {
    sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

IPA="" IDENTITY="" PROFILE="" OUT="" TEAM=""
while getopts "i:s:p:o:t:h" opt; do
    case "$opt" in
        i) IPA="$OPTARG" ;;
        s) IDENTITY="$OPTARG" ;;
        p) PROFILE="$OPTARG" ;;
        o) OUT="$OPTARG" ;;
        t) TEAM="$OPTARG" ;;
        *) usage ;;
    esac
done
[[ -n "$IPA" ]] || usage
[[ -f "$IPA" ]] || { echo "❌ No such ipa: $IPA" >&2; exit 1; }
OUT="${OUT:-${IPA%.ipa}-signed.ipa}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PB=/usr/libexec/PlistBuddy
PROFILE_DIRS=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"   # Xcode 16+
    "$HOME/Library/MobileDevice/Provisioning Profiles"               # older Xcode
)

# ── Unpack ────────────────────────────────────────────────────────────────
unzip -q "$IPA" -d "$WORK"
APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' -type d | head -1)"
[[ -n "$APP" ]] || { echo "❌ No Payload/*.app inside $IPA" >&2; exit 1; }
BUNDLE_ID="$($PB -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

# ── Team: flag → env → Config/Local.xcconfig → Xcode build settings ─────
if [[ -z "$TEAM" ]]; then TEAM="${DEVELOPMENT_TEAM:-}"; fi
if [[ -z "$TEAM" && -f "$REPO/Config/Local.xcconfig" ]]; then
    TEAM="$(awk -F' *= *' '$1 == "DEVELOPMENT_TEAM" { print $2; exit }' "$REPO/Config/Local.xcconfig")"
fi
if [[ -z "$TEAM" && -d "$REPO/iCTRL.xcodeproj" ]]; then
    TEAM="$(xcodebuild -project "$REPO/iCTRL.xcodeproj" -target iCTRLUITests -showBuildSettings 2>/dev/null \
            | awk '$1 == "DEVELOPMENT_TEAM" { print $3; exit }')"
fi

# ── Profile helpers ───────────────────────────────────────────────────────
decode() { security cms -D -i "$1" 2>/dev/null; }
field()  { plutil -extract "$2" raw -o - "$1" 2>/dev/null; }

# How well an App ID covers the bundle id: 2 exact, 1 prefix wildcard,
# 0 full wildcard, nothing (exit 1) if it doesn't cover it at all. The profile
# has to cover the bundle id, or iOS refuses the install with an error that
# never mentions the profile.
covers() {   # appid team
    case "$1" in
        "$2.$BUNDLE_ID") echo 2 ;;
        "$2.*") echo 0 ;;
        "$2."*'*') local p="${1#"$2."}"; p="${p%\*}"
                   [[ "$BUNDLE_ID" == "$p"* ]] && echo 1 || return 1 ;;
        *) return 1 ;;
    esac
}

# Prints "<score> <expiry> <path>" for a profile that can sign this package.
# A test runner has to be debuggable (testmanagerd attaches to it), so a
# distribution profile — get-task-allow false — is never eligible.
eligible() {   # path
    local plist="$WORK/candidate.plist"
    decode "$1" > "$plist" || return 1
    local team appid allow exp score
    team="$(field "$plist" TeamIdentifier.0)" || return 1
    [[ -z "$TEAM" || "$team" == "$TEAM" ]] || return 1
    appid="$(field "$plist" Entitlements.application-identifier)" || return 1
    allow="$(field "$plist" Entitlements.get-task-allow || echo false)"
    [[ "$allow" == "true" ]] || return 1
    exp="$(field "$plist" ExpirationDate)" || return 1
    [[ "$exp" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || return 1
    score="$(covers "$appid" "$team")" || return 1
    echo "$score $exp $1"
}

installed_profiles() {
    for d in "${PROFILE_DIRS[@]}"; do
        [[ -d "$d" ]] && find "$d" -maxdepth 1 -name '*.mobileprovision'
    done
}

# ── Profile: path → UUID/name lookup → best installed match ──────────────
if [[ -n "$PROFILE" && ! -f "$PROFILE" ]]; then
    wanted="$PROFILE"; PROFILE=""
    while IFS= read -r p; do
        decode "$p" > "$WORK/lookup.plist" || continue
        if [[ "$(field "$WORK/lookup.plist" UUID)" == "$wanted" || "$(field "$WORK/lookup.plist" Name)" == "$wanted" ]]; then
            PROFILE="$p"; break
        fi
    done < <(installed_profiles)
    [[ -n "$PROFILE" ]] || { echo "❌ No installed profile with UUID or name '$wanted'" >&2; exit 1; }
fi
if [[ -z "$PROFILE" ]]; then
    # Exact App ID beats a wildcard; among equals, the one that expires last.
    PROFILE="$(installed_profiles | while IFS= read -r p; do eligible "$p" || true; done \
               | sort -k1,1nr -k2,2r | head -1 | cut -d' ' -f3-)"
    [[ -n "$PROFILE" ]] || {
        echo "❌ No installed development profile${TEAM:+ for team $TEAM} covers $BUNDLE_ID." >&2
        echo "   Open the project in Xcode once with automatic signing (it downloads one), or pass -p." >&2
        exit 1; }
fi

decode "$PROFILE" > "$WORK/profile.plist" || { echo "❌ Can't read profile: $PROFILE" >&2; exit 1; }
PROFILE_TEAM="$(field "$WORK/profile.plist" TeamIdentifier.0)"
[[ -z "$TEAM" || "$TEAM" == "$PROFILE_TEAM" ]] || {
    echo "❌ Profile belongs to team $PROFILE_TEAM, not $TEAM" >&2; exit 1; }
TEAM="$PROFILE_TEAM"
eligible "$PROFILE" > /dev/null || {
    echo "❌ $(field "$WORK/profile.plist" Name) can't sign $BUNDLE_ID: it must be an unexpired DEVELOPMENT" >&2
    echo "   profile (get-task-allow) whose App ID covers the bundle id." >&2
    exit 1; }

# ── Identity: must be one of the profile's certificates ──────────────────
# Matching by name doesn't work — the id in "Apple Development: Name (XXXX)"
# is the certificate holder's, not the team's. Match certificate hashes.
PROFILE_CERTS=""
i=0
while cert="$(field "$WORK/profile.plist" "DeveloperCertificates.$i")"; do
    PROFILE_CERTS+="$(echo "$cert" | base64 -D | shasum -a 1 | awk '{ print toupper($1) }') "
    i=$((i + 1))
done
IDENTITIES="$(security find-identity -v -p codesigning | awk '/\)/ { print $2 }')"

if [[ -z "$IDENTITY" ]]; then
    for sha in $IDENTITIES; do
        if [[ " $PROFILE_CERTS" == *" $sha "* ]]; then IDENTITY="$sha"; break; fi
    done
    [[ -n "$IDENTITY" ]] || {
        echo "❌ None of the signing identities in your keychain is in profile" >&2
        echo "   '$(field "$WORK/profile.plist" Name)'. Install its certificate, or pass -s." >&2
        exit 1; }
else
    # `|| true`: under pipefail a grep miss would end the script silently,
    # before the message below could say what was wrong.
    sha="$(security find-identity -v -p codesigning | grep -F "$IDENTITY" | awk '{ print $2; exit }' || true)"
    [[ -n "$sha" ]] || { echo "❌ No signing identity matching '$IDENTITY' in the keychain" >&2; exit 1; }
    [[ " $PROFILE_CERTS" == *" $sha "* ]] || {
        echo "❌ '$IDENTITY' is not one of the certificates in the profile — iOS would reject the install." >&2
        exit 1; }
    IDENTITY="$sha"
fi
IDENTITY_NAME="$(security find-identity -v -p codesigning | grep -F "$IDENTITY" | sed -E 's/.*"(.*)"/\1/' | head -1 || true)"

echo "🔏 Signing $BUNDLE_ID for team $TEAM"
echo "   profile  $(field "$WORK/profile.plist" Name) ($(field "$WORK/profile.plist" UUID))"
echo "   identity $IDENTITY_NAME"
cp "$PROFILE" "$APP/embedded.mobileprovision"

# ── Entitlements for the outer app ────────────────────────────────────────
ENT="$WORK/entitlements.plist"
cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>$TEAM.$BUNDLE_ID</string>
    <key>com.apple.developer.team-identifier</key>
    <string>$TEAM</string>
    <key>get-task-allow</key>
    <true/>
    <key>keychain-access-groups</key>
    <array>
        <string>$TEAM.$BUNDLE_ID</string>
    </array>
</dict>
</plist>
EOF

# Quiet on success ("replacing existing signature" for every file is noise);
# the full codesign output on failure.
sign() {
    local out
    out="$(codesign --force --timestamp=none --sign "$IDENTITY" "$@" 2>&1)" || {
        echo "$out" >&2; return 1; }
}

# ── 1. The .xctest takes an id under the runner's ─────────────────────────
# Must happen BEFORE signing so the edited Info.plist is sealed by the
# signature. It extends the host's id the way an .appex does: iLoader refuses
# a nested bundle whose id equals the main app's.
for xctest in "$APP"/PlugIns/*.xctest; do
    [[ -d "$xctest" ]] || continue
    $PB -c "Set :CFBundleIdentifier $BUNDLE_ID.tests" "$xctest/Info.plist"
    echo "   aligned $(basename "$xctest") → $BUNDLE_ID.tests"
done

# ── 2. Inside out: loose dylibs, frameworks, plug-ins, then the app ───────
# Deepest paths first, so nothing is signed before what it contains.
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

# ── 3. Verify every nested binary ─────────────────────────────────────────
# An unsigned dylib fails at launch with "mapped file has no cdhash", which
# looks nothing like a signing problem — catch it here instead.
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
echo "   Install with: Xcode → Devices and Simulators → Installed Apps → +,"
echo "   Apple Configurator, or \`ideviceinstaller -i $(basename "$OUT")\`."
