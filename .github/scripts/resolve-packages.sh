#!/bin/bash
# Resolve Swift packages for one scheme, with authenticated, retried
# downloads. Several jobs fetching release assets anonymously at once hit
# api.github.com's unauthenticated rate limit (403), and github.com release
# downloads occasionally return 500.
#
# Usage: resolve-packages.sh SCHEME [xcodebuild options...]
# Requires GH_TOKEN (the job's GITHUB_TOKEN).
set -euo pipefail

scheme=$1
shift

umask 077
{
    printf 'machine api.github.com login x-access-token password %s\n' "$GH_TOKEN"
    printf 'machine github.com login x-access-token password %s\n' "$GH_TOKEN"
} > "$HOME/.netrc"

auth=()
if xcodebuild -help 2>&1 | grep -q -- -packageAuthorizationProvider; then
    auth=(-packageAuthorizationProvider netrc)
fi

for attempt in 1 2 3; do
    if xcodebuild -resolvePackageDependencies \
        -project rootshell.xcodeproj \
        -scheme "$scheme" \
        ${auth[@]+"${auth[@]}"} \
        "$@"; then
        exit 0
    fi
    echo "Package resolution failed (attempt $attempt of 3)" >&2
    sleep $((attempt * 30))
done
exit 1
