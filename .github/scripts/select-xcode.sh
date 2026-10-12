#!/bin/bash
# Point DEVELOPER_DIR at an Xcode that can build this checkout, so CI follows
# the sources' SDK requirement instead of a pinned version. The requirement
# is the highest iOS version in a Swift availability check: with a
# deployment target older than the SDK, every newer API sits behind one.
#
# Picks the newest release Xcode whose iOS SDK meets it. A beta or release
# candidate is used only when no release does, with a warning. With none,
# the job fails here instead of minutes into the build.
#
# Usage: select-xcode.sh
# XCODE_APPS_DIR overrides /Applications. Without GITHUB_ENV, the selection
# is printed instead of exported.
set -euo pipefail

apps_dir=${XCODE_APPS_DIR:-/Applications}

# ver_ge A B: whether dotted version A is at least B.
ver_ge() {
    local IFS=.
    local -a a=($1) b=($2)
    local i
    for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
        if ((10#${a[i]:-0} != 10#${b[i]:-0})); then
            ((10#${a[i]:-0} > 10#${b[i]:-0}))
            return
        fi
    done
}

required=0
while read -r version; do
    ver_ge "$required" "$version" || required=$version
done < <(git ls-files -z '*.swift' |
    xargs -0 grep -hoE '[#@]available\(iOS [0-9]+(\.[0-9]+)*' |
    grep -oE '[0-9]+(\.[0-9]+)*$' || true)
echo "Sources require the iOS $required SDK"

# The image links several names (Xcode.app, Xcode_27.app, Xcode_27.0.app)
# to one install; each install is considered once, by its real path.
seen=$'\n'
release= release_sdk= prerelease= prerelease_sdk=
for app in "$apps_dir"/Xcode*.app; do
    [ -d "$app" ] || continue
    real=$(cd -P "$app" && pwd -P)
    case $seen in *$'\n'"$real"$'\n'*) continue ;; esac
    seen+="$real"$'\n'

    sdk=$(ls "$real/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs" 2>/dev/null |
        sed -nE 's/^iPhoneOS([0-9.]+)\.sdk$/\1/p' | head -n 1)
    [ -n "$sdk" ] || continue
    echo "$real: iOS $sdk SDK"
    ver_ge "$sdk" "$required" || continue

    # The install's own folder name is the only pre-release marker the
    # image keeps; its symlinks carry the bare version either way.
    case ${real##*/} in
        *[Bb]eta* | *Release_Candidate*)
            if [ -z "$prerelease" ] || ver_ge "$prerelease_sdk" "$sdk"; then
                prerelease=$real prerelease_sdk=$sdk
            fi ;;
        *)
            if [ -z "$release" ] || ver_ge "$sdk" "$release_sdk"; then
                release=$real release_sdk=$sdk
            fi ;;
    esac
done

if [ -n "$release" ]; then
    selected=$release
elif [ -n "$prerelease" ]; then
    selected=$prerelease
    echo "::warning::No release Xcode has the iOS $required SDK; using ${prerelease##*/}"
else
    echo "::error::No Xcode in $apps_dir has the iOS $required SDK the sources require"
    exit 1
fi

echo "Selected $selected"
echo "DEVELOPER_DIR=$selected/Contents/Developer" >> "${GITHUB_ENV:-/dev/stdout}"
