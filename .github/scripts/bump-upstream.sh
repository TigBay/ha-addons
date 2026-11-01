#!/usr/bin/env bash
# =============================================================================
# Looks for a newer upstream SilverBullet release. If there is one, this script
# bumps the pinned image in silverbullet/Dockerfile, the add-on version in
# silverbullet/config.yaml and adds an entry to silverbullet/CHANGELOG.md.
#
# Usage: bump-upstream.sh [target-version]
#   Without an argument the latest (non-prerelease) upstream release is used.
#   Needs: gh (authenticated) unless a target version is given, docker, git.
#
# Output (printed and appended to $GITHUB_OUTPUT when set):
#   changed=true|false, upstream, previous, addon_version
#
# Add-on version scheme (CalVer): YYYY.M.PATCH. A new month starts at PATCH 0,
# otherwise PATCH is raised by one.
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DOCKERFILE="silverbullet/Dockerfile"
CONFIG="silverbullet/config.yaml"
CHANGELOG="silverbullet/CHANGELOG.md"
UPSTREAM_IMAGE="ghcr.io/silverbulletmd/silverbullet"

out() {
    echo "$1"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "$1" >> "${GITHUB_OUTPUT}"
    fi
}

CURRENT=$(sed -nE "s#^FROM ${UPSTREAM_IMAGE}:([0-9]+\.[0-9]+\.[0-9]+) AS .*#\1#p" "${DOCKERFILE}")
if [[ -z "${CURRENT}" ]]; then
    echo "::error::Could not find the pinned SilverBullet image in ${DOCKERFILE}."
    exit 1
fi

LATEST="${1:-}"
if [[ -z "${LATEST}" ]]; then
    LATEST=$(gh api repos/silverbulletmd/silverbullet/releases/latest --jq .tag_name)
fi
if [[ ! "${LATEST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error::Unexpected upstream version format: '${LATEST}'"
    exit 1
fi

echo "Pinned: ${CURRENT}, upstream: ${LATEST}"

# Only move forward: nothing to do when the target is the same or older.
NEWEST=$(printf '%s\n%s\n' "${CURRENT}" "${LATEST}" | sort -V | tail -n 1)
if [[ "${LATEST}" == "${CURRENT}" || "${NEWEST}" != "${LATEST}" ]]; then
    echo "No newer upstream release."
    out "changed=false"
    exit 0
fi

# A release may be published before its image. Try again on the next run.
if ! docker manifest inspect "${UPSTREAM_IMAGE}:${LATEST}" > /dev/null 2>&1; then
    echo "::warning::Image ${UPSTREAM_IMAGE}:${LATEST} is not available yet."
    out "changed=false"
    exit 0
fi

CONFIG_VERSION=$(sed -nE 's/^version: "?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/p' "${CONFIG}")
if [[ -z "${CONFIG_VERSION}" ]]; then
    echo "::error::Could not read the version from ${CONFIG}."
    exit 1
fi
PERIOD=$(date -u +%Y.%-m)
if [[ "${CONFIG_VERSION%.*}" == "${PERIOD}" ]]; then
    ADDON_VERSION="${PERIOD}.$(( ${CONFIG_VERSION##*.} + 1 ))"
else
    ADDON_VERSION="${PERIOD}.0"
fi

# 1. Dockerfile
sed -i -E "s#^(FROM ${UPSTREAM_IMAGE}:)[0-9]+\.[0-9]+\.[0-9]+( AS )#\1${LATEST}\2#" "${DOCKERFILE}"

# 2. Add-on version
sed -i -E "s/^version: .*/version: \"${ADDON_VERSION}\"/" "${CONFIG}"

# 3. Changelog: new entry above the newest one
ENTRY_FILE=$(mktemp)
cat > "${ENTRY_FILE}" <<EOF
## [${ADDON_VERSION}] – $(date -u +%F)

### Changed
- Updated SilverBullet from ${CURRENT} to ${LATEST} ([release notes](https://github.com/silverbulletmd/silverbullet/releases/tag/${LATEST}))

EOF
CHANGELOG_NEW=$(mktemp)
awk -v f="${ENTRY_FILE}" '!done && /^## \[/ { while ((getline line < f) > 0) print line; done = 1 } { print }' \
    "${CHANGELOG}" > "${CHANGELOG_NEW}"
cat "${CHANGELOG_NEW}" > "${CHANGELOG}"
rm -f "${ENTRY_FILE}" "${CHANGELOG_NEW}"

# Check the result before reporting success
grep -q "^FROM ${UPSTREAM_IMAGE}:${LATEST} AS " "${DOCKERFILE}" || { echo "::error::Dockerfile was not updated."; exit 1; }
grep -q "^version: \"${ADDON_VERSION}\"" "${CONFIG}" || { echo "::error::config.yaml was not updated."; exit 1; }
grep -q "^## \[${ADDON_VERSION}\]" "${CHANGELOG}" || { echo "::error::CHANGELOG.md was not updated."; exit 1; }

echo "Bumped SilverBullet ${CURRENT} -> ${LATEST}, add-on version ${CONFIG_VERSION} -> ${ADDON_VERSION}"
out "changed=true"
out "upstream=${LATEST}"
out "previous=${CURRENT}"
out "addon_version=${ADDON_VERSION}"
