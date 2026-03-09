#!/usr/bin/env bash
#
# check-updates.sh — Check for upstream updates and regenerate matrix.json
#
# Modeled after jellyfin-tizen-builds/scripts/Check-Updates.ps1
# This script:
#   1. Reads versions.json for tracked commits and releases
#   2. Queries GitHub API for latest commit SHAs and release tags
#   3. Updates versions.json with new values
#   4. Regenerates matrix.json from versions.json + matrix-definition.json
#   5. Outputs GitHub Actions outputs for triggering builds
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSIONS_FILE="$ROOT_DIR/versions.json"
MATRIX_DEF_FILE="$ROOT_DIR/matrix-definition.json"
MATRIX_FILE="$ROOT_DIR/matrix.json"

GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

trigger_build=false
cause_of_update="### Cause of the update\n"
updates=()

# ─── Check commits ─────────────────────────────────────────────────────────

commit_count=$(jq '.commits | length' "$VERSIONS_FILE")
for i in $(seq 0 $((commit_count - 1))); do
    owner=$(jq -r ".commits[$i].owner" "$VERSIONS_FILE")
    repo=$(jq -r ".commits[$i].repo" "$VERSIONS_FILE")
    ref=$(jq -r ".commits[$i].ref" "$VERSIONS_FILE")
    latest=$(jq -r ".commits[$i].latest" "$VERSIONS_FILE")

    echo "Checking: $owner/$repo@$ref"

    response=$(curl -sL \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$owner/$repo/commits/$ref")

    new_sha=$(echo "$response" | jq -r '.sha // empty')
    commit_msg=$(echo "$response" | jq -r '.commit.message // empty' | head -1)

    if [[ -n "$new_sha" && "$latest" != "$new_sha" ]]; then
        echo "Updates:  true"
        updates+=("New commit to $ref https://github.com/$owner/$repo/commit/$new_sha")
        trigger_build=true

        # Update versions.json in place
        jq ".commits[$i].latest = \"$new_sha\"" "$VERSIONS_FILE" > "${VERSIONS_FILE}.tmp"
        mv "${VERSIONS_FILE}.tmp" "$VERSIONS_FILE"
    else
        echo "Updates:  false"
    fi
    echo ""
done

# ─── Check releases ────────────────────────────────────────────────────────

release_count=$(jq '.releases | length' "$VERSIONS_FILE")
for i in $(seq 0 $((release_count - 1))); do
    owner=$(jq -r ".releases[$i].owner" "$VERSIONS_FILE")
    repo=$(jq -r ".releases[$i].repo" "$VERSIONS_FILE")
    latest=$(jq -r ".releases[$i].latest" "$VERSIONS_FILE")

    echo "Checking: $owner/$repo@latest"

    response=$(curl -sL \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/$owner/$repo/releases/latest")

    new_tag=$(echo "$response" | jq -r '.tag_name // empty')

    if [[ -n "$new_tag" && "$latest" != "$new_tag" ]]; then
        echo "Updates:  true"
        updates+=("New $repo release: $new_tag")
        trigger_build=true

        jq ".releases[$i].latest = \"$new_tag\"" "$VERSIONS_FILE" > "${VERSIONS_FILE}.tmp"
        mv "${VERSIONS_FILE}.tmp" "$VERSIONS_FILE"
    else
        echo "Updates:  false"
    fi
    echo ""
done

# ─── Output trigger decision ───────────────────────────────────────────────

if [[ "$trigger_build" == "true" ]]; then
    cause_of_update+=$(printf '%s\\n' "${updates[@]}")
    echo "triggerBuild=true" >> "$GITHUB_OUTPUT"
    echo "causeOfUpdateLabel=$cause_of_update" >> "$GITHUB_OUTPUT"
else
    echo "triggerBuild=false" >> "$GITHUB_OUTPUT"
fi

# ─── Regenerate matrix.json ────────────────────────────────────────────────

echo "Regenerating matrix.json..."

matrix='{"include":[]}'

# Add source builds from releases (default = stable release)
for i in $(seq 0 $((release_count - 1))); do
    owner=$(jq -r ".releases[$i].owner" "$VERSIONS_FILE")
    repo=$(jq -r ".releases[$i].repo" "$VERSIONS_FILE")
    tag=$(jq -r ".releases[$i].latest" "$VERSIONS_FILE")
    is_default=$(jq -r ".releases[$i].default // false" "$VERSIONS_FILE")

    if [[ "$(jq -r ".releases[$i].matrix" "$VERSIONS_FILE")" != "true" ]]; then
        continue
    fi

    if [[ "$is_default" == "true" ]]; then
        artifact_name="Stremio"
    else
        artifact_name="Stremio-${tag}"
    fi

    matrix=$(echo "$matrix" | jq \
        --arg tag "$tag" \
        --arg repo "$owner/$repo" \
        --arg name "$artifact_name" \
        '.include += [{
            tag: $tag,
            repository: $repo,
            artifact_name: $name,
            tizen_template: "standard",
            app_id: "StrTzBuild.Stremio",
            package_id: "StrTzBuild",
            source_build: true
        }]')

    # Output release tag for the build workflow
    if [[ "$is_default" == "true" ]]; then
        echo "webReleaseTagName=$tag" >> "$GITHUB_OUTPUT"
    fi
done

# Add source builds from tracked commits (e.g., main branch)
for i in $(seq 0 $((commit_count - 1))); do
    owner=$(jq -r ".commits[$i].owner" "$VERSIONS_FILE")
    repo=$(jq -r ".commits[$i].repo" "$VERSIONS_FILE")
    ref=$(jq -r ".commits[$i].ref" "$VERSIONS_FILE")
    name=$(jq -r ".commits[$i].name" "$VERSIONS_FILE")

    if [[ "$(jq -r ".commits[$i].matrix" "$VERSIONS_FILE")" != "true" ]]; then
        continue
    fi

    matrix=$(echo "$matrix" | jq \
        --arg tag "$ref" \
        --arg repo "$owner/$repo" \
        --arg name "Stremio-$name" \
        '.include += [{
            tag: $tag,
            repository: $repo,
            artifact_name: $name,
            tizen_template: "standard",
            app_id: "StrTzBuild.Stremio",
            package_id: "StrTzBuild",
            source_build: true
        }]')
done

# Add variations (e.g., secondary) for each source build
variation_count=$(jq '.variations | length' "$MATRIX_DEF_FILE")
base_count=$(echo "$matrix" | jq '.include | length')

for v in $(seq 0 $((variation_count - 1))); do
    var_name=$(jq -r ".variations[$v].name" "$MATRIX_DEF_FILE")
    extra_values=$(jq -c ".variations[$v].extra_values" "$MATRIX_DEF_FILE")

    for b in $(seq 0 $((base_count - 1))); do
        base=$(echo "$matrix" | jq -c ".include[$b]")
        base_artifact=$(echo "$base" | jq -r '.artifact_name')

        # Create variation entry
        variant=$(echo "$base" | jq --arg name "${base_artifact}-${var_name}" '.artifact_name = $name')

        # Apply extra values
        ev_count=$(echo "$extra_values" | jq 'length')
        for e in $(seq 0 $((ev_count - 1))); do
            key=$(echo "$extra_values" | jq -r ".[$e].key")
            value=$(echo "$extra_values" | jq -c ".[$e].value")
            variant=$(echo "$variant" | jq --arg k "$key" --argjson v "$value" '.[$k] = $v')
        done

        matrix=$(echo "$matrix" | jq --argjson entry "$variant" '.include += [$entry]')
    done
done

# Add wrapper builds (not source-dependent)
wrapper_count=$(jq '.wrappers | length' "$MATRIX_DEF_FILE")
for w in $(seq 0 $((wrapper_count - 1))); do
    wrapper=$(jq -c ".wrappers[$w]" "$MATRIX_DEF_FILE")

    matrix=$(echo "$matrix" | jq --argjson w "$wrapper" \
        '.include += [$w + {source_build: false, tag: "", repository: ""}]')
done

# Write matrix.json
echo "$matrix" | jq '.' > "$MATRIX_FILE"
echo "Generated matrix with $(echo "$matrix" | jq '.include | length') entries:"
echo "$matrix" | jq -r '.include[].artifact_name'
