#!/usr/bin/env bash
#
# check-updates.sh — Check if upstream stremio-web has new commits/releases
# Returns 0 (with output "true") if a rebuild is needed, 1 otherwise.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="$ROOT_DIR/versions.json"

get_latest_release_tag() {
    curl -sL "https://api.github.com/repos/$1/releases/latest" \
        | jq -r '.tag_name // empty'
}

get_branch_head() {
    curl -sL "https://api.github.com/repos/$1/commits/$2" \
        | jq -r '.sha // empty' | head -c 12
}

needs_rebuild=false

# Check stable (latest release)
stable_current=$(jq -r '.stable.stremio_web_version // ""' "$VERSIONS_FILE")
stable_latest=$(get_latest_release_tag "Stremio/stremio-web")

if [[ -n "$stable_latest" && "$stable_current" != "$stable_latest" ]]; then
    echo "stable: $stable_current → $stable_latest"
    needs_rebuild=true
fi

# Check main branch
main_current=$(jq -r '.main.stremio_web_commit // ""' "$VERSIONS_FILE")
main_latest=$(get_branch_head "Stremio/stremio-web" "main")

if [[ -n "$main_latest" && "$main_current" != "$main_latest" ]]; then
    echo "main: $main_current → $main_latest"
    needs_rebuild=true
fi

if [[ "$needs_rebuild" == "true" ]]; then
    echo "NEEDS_REBUILD=true"
    exit 0
else
    echo "NEEDS_REBUILD=false"
    echo "All versions up to date."
    exit 0
fi
