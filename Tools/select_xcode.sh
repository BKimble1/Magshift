#!/usr/bin/env bash
#
# Choose an installed Xcode that meets the project's minimum, verify the iOS SDK
# it carries, and print the `DEVELOPER_DIR` that selects it.
#
# GitHub's macOS runner images ship several Xcode versions side by side and
# change which one is the default without notice. Pinning a version here would
# break every time the image is updated; pinning the *floor* and discovering the
# rest is stable, and it fails in seconds with a list of what the machine has
# rather than at the archive or upload step.
#
# Usage:
#     MINIMUM_XCODE_VERSION=26.0 MINIMUM_IOS_SDK_VERSION=26.0 Tools/select_xcode.sh
#
# Prints one shell-assignable line on stdout, and its diagnostics on stderr, so
# the line can be appended straight to `$GITHUB_ENV`:
#     DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer
#
# Exits non-zero with an actionable message when nothing qualifies.
set -euo pipefail

minimum="${MINIMUM_XCODE_VERSION:?MINIMUM_XCODE_VERSION is not set}"
minimum_sdk="${MINIMUM_IOS_SDK_VERSION:?MINIMUM_IOS_SDK_VERSION is not set}"

# Version comparison in Python rather than `sort -V`, so the guard cannot itself
# become the reason a build fails on a version string it did not expect.
version_of() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$1/Contents/version.plist" 2>/dev/null || true
}

at_least() {
    python3 -c 'import sys
parse = lambda v: tuple(int(x) for x in v.split(".") if x.isdigit())
sys.exit(0 if parse(sys.argv[1]) >= parse(sys.argv[2]) else 1)' "$1" "$2"
}

best_path=""
best_version=""
found_any=""

for candidate in /Applications/Xcode*.app; do
    [ -d "$candidate" ] || continue
    version="$(version_of "$candidate")"
    [ -n "$version" ] || continue
    found_any="${found_any}  ${version}  ${candidate}"$'\n'
    at_least "$version" "$minimum" || continue
    if [ -z "$best_version" ] || at_least "$version" "$best_version"; then
        best_version="$version"
        best_path="$candidate"
    fi
done

if [ -z "$best_path" ]; then
    {
        echo "ERROR: no installed Xcode is at least $minimum."
        echo
        if [ -n "$found_any" ]; then
            echo "Installed:"
            printf '%s' "$found_any"
        else
            echo "No Xcode was found in /Applications at all."
        fi
        echo
        echo "Apple requires App Store uploads to be built with the iOS 26 SDK or"
        echo "later, which is why this floor exists. Change 'runs-on:' in the"
        echo "workflow to a runner image that carries a new enough Xcode."
    } >&2
    exit 1
fi

developer_dir="$best_path/Contents/Developer"
export DEVELOPER_DIR="$developer_dir"

# Everything below reports to stderr, so stdout carries only the assignment.
{
    echo "--- Build machine ---"
    sw_vers
    xcodebuild -version
    echo
    echo "--- Installed SDKs ---"
    xcodebuild -showsdks
    echo
} >&2

# `-sdk iphonesimulator26.0` cannot match this pattern, so only device SDKs are
# considered: an app is uploaded against the device SDK, not the simulator one.
ios_sdk_version="$(xcodebuild -showsdks \
    | sed -n 's/.*-sdk iphoneos\([0-9][0-9.]*\).*/\1/p' \
    | python3 -c 'import sys
values = [line.strip() for line in sys.stdin if line.strip()]
key = lambda s: tuple(int(x) for x in s.split(".") if x.isdigit())
print(max(values, key=key) if values else "")')"

if [ -z "$ios_sdk_version" ]; then
    echo "ERROR: $best_path carries no iOS device SDK." >&2
    exit 1
fi

# Apple requires apps uploaded since 28 April 2026 to be built with the iOS 26
# SDK or later. Catching that here costs seconds; catching it at upload costs a
# whole build.
if ! at_least "$ios_sdk_version" "$minimum_sdk"; then
    {
        echo "ERROR: the newest installed iOS SDK is $ios_sdk_version, but App Store"
        echo "uploads require at least $minimum_sdk."
    } >&2
    exit 1
fi

echo "Selected Xcode $best_version with iOS SDK $ios_sdk_version." >&2
echo "DEVELOPER_DIR=$developer_dir"
