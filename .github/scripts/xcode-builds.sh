#!/bin/bash
# Run several xcodebuild invocations in one job. They share one DerivedData,
# so modules that several schemes compile are built once. Every invocation
# runs even after one fails; the script fails if any did.
#
# Usage: xcode-builds.sh PLATFORM
# BUILDS holds one invocation per line: the scheme, actions and options,
# e.g. "-scheme rootshell-AppStore -configuration ReleaseAppStore build".
# OS picks the simulator runtime. PACKAGES_DIR and DERIVED_DATA are paths.
set -euo pipefail

platform=$1
common=(-project rootshell.xcodeproj -clonedSourcePackagesDirPath "$PACKAGES_DIR"
    -skipPackagePluginValidation -skipMacroValidation)

# Simulators come from xcodebuild's own destination list, so the device is
# always one the scheme accepts. The generic iOS Simulator destination also
# builds x86_64, which fails in MainThreadStackSampler.swift (see AGENTS.md).
simulator() {
    xcodebuild -showdestinations "${common[@]}" -scheme "$1" |
        grep -F "platform:$2 Simulator," | grep -F "name:$3" | grep -v 'Designed for' |
        grep -F "OS:${OS:-}" | sed -n 's/.* id:\([^,]*\),.*/\1/p' | head -n 1
}

destination() {
    local udid
    case "$platform" in
        ios) udid=$(simulator "$1" iOS iPhone) ;;
        visionos) udid=$(simulator "$1" visionOS "Apple Vision Pro") ;;
        ios-device) echo "generic/platform=iOS"; return ;;
        visionos-device) echo "generic/platform=visionOS"; return ;;
        catalyst) echo "platform=macOS,arch=arm64,variant=Mac Catalyst"; return ;;
        macos) echo "platform=macOS,arch=arm64"; return ;;
        *) echo "Unknown platform $platform" >&2; return 1 ;;
    esac
    if [ -z "$udid" ]; then
        echo "xcodebuild lists no $platform simulator with OS ${OS:-} for $1" >&2
        xcodebuild -showdestinations "${common[@]}" -scheme "$1" >&2 || true
        return 1
    fi
    echo "id=$udid"
}

status=0
n=0
while read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    read -ra args <<< "$line"
    scheme=$(sed -n 's/.*-scheme \([^ ]*\).*/\1/p' <<< "$line")
    bundle="$RUNNER_TEMP/result-$n.xcresult"

    echo "::group::xcodebuild $line"
    if dest=$(destination "$scheme") && xcodebuild "${common[@]}" \
        -destination "$dest" \
        -derivedDataPath "$DERIVED_DATA" \
        -disableAutomaticPackageResolution \
        -resultBundlePath "$bundle" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        "${args[@]}"; then
        echo "::endgroup::"
        continue
    fi
    echo "::endgroup::"
    status=1
    echo "::error::xcodebuild $line failed"
    # -quiet drops assertion messages from the log; read them back from the
    # result bundle.
    if [[ " $line " == *" test "* ]] && [ -d "$bundle" ]; then
        xcrun xcresulttool get test-results summary --path "$bundle" |
            jq -r '.testFailures[]? | "\(.testIdentifierString // .testName): \(.failureText)"'
    fi
done <<< "$BUILDS"

du -sh "${CAS_PATH:-/nonexistent}" 2>/dev/null | sed 's/^/Compilation cache size: /' || true
exit "$status"
