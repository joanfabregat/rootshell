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
    -disableAutomaticPackageResolution
    -skipPackagePluginValidation -skipMacroValidation)

# The simulator comes from simctl's device list: asking xcodebuild with
# -showdestinations loads the whole package graph and took over three
# minutes. A concrete device also avoids the generic iOS Simulator
# destination, which builds x86_64 too and fails in
# MainThreadStackSampler.swift (see AGENTS.md).
simulator() {
    local runtime="com.apple.CoreSimulator.SimRuntime.$1-${OS//./-}"
    xcrun simctl list devices available --json |
        jq -r --arg runtime "$runtime" --arg name "$2" \
            '.devices[$runtime][]? | select(.name | startswith($name)) | .udid' |
        head -n 1
}

destination() {
    local udid
    case "$platform" in
        ios) udid=$(simulator iOS iPhone) ;;
        visionos) udid=$(simulator xrOS "Apple Vision Pro") ;;
        ios-device) echo "generic/platform=iOS"; return ;;
        visionos-device) echo "generic/platform=visionOS"; return ;;
        catalyst) echo "platform=macOS,arch=arm64,variant=Mac Catalyst"; return ;;
        macos) echo "platform=macOS,arch=arm64"; return ;;
        *) echo "Unknown platform $platform" >&2; return 1 ;;
    esac
    if [ -z "$udid" ]; then
        echo "simctl lists no $platform simulator with OS ${OS:-}" >&2
        xcrun simctl list devices available >&2 || true
        return 1
    fi
    echo "id=$udid"
}

cas_size() {
    du -sh "${CAS_PATH:-/nonexistent}" 2>/dev/null | sed "s/^/Compilation cache size $1: /" || true
}

status=0
n=0
while read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    read -ra args <<< "$line"
    bundle="$RUNNER_TEMP/result-$n.xcresult"

    cas_size "before $line"
    echo "::group::xcodebuild $line"
    test_args=()
    dest=$(destination) || dest=
    if [[ " $line " == *" test "* ]]; then
        # On the runner, letting xcodebuild boot the simulator waits 120 s on
        # instruments' lockdown service, and its diagnostics collection after
        # the tests times out after 600 s even when they pass.
        test_args=(-collect-test-diagnostics never)
        if [[ "$dest" == id=* ]]; then
            xcrun simctl boot "${dest#id=}" 2>/dev/null || true
            xcrun simctl bootstatus "${dest#id=}" -b ||
                echo "::warning::Simulator ${dest#id=} did not report booted"
        fi
    fi
    if [ -n "$dest" ] && xcodebuild "${common[@]}" \
        -destination "$dest" \
        -derivedDataPath "$DERIVED_DATA" \
        -resultBundlePath "$bundle" \
        -quiet \
        CODE_SIGNING_ALLOWED=NO \
        ${test_args[@]+"${test_args[@]}"} \
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

cas_size after
exit "$status"
