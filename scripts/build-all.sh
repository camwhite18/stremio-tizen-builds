#!/usr/bin/env bash
#
# build-all.sh — Build all Stremio Tizen .wgt variants
#
# This script:
#   1. Reads matrix.json for variant definitions
#   2. For source-built variants: clones stremio-web, builds it, wraps in Tizen app
#   3. For wrapper variants: generates a lightweight iframe-based Tizen app
#   4. Packages each as a signed .wgt using Tizen CLI
#   5. Outputs all .wgt files to ./output/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/output"
WORK_DIR="$ROOT_DIR/.build"
TIZEN_DIR="$ROOT_DIR/tizen"
PATCHES_DIR="$ROOT_DIR/patches"

STREMIO_WEB_HOSTED_URL="https://app.strem.io/shell-v4.4/"
STREMIO_WEB_LEGACY_URL="https://app.strem.io/"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log()   { echo -e "\033[92m[BUILD]\033[0m $*"; }
warn()  { echo -e "\033[93m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[91m[ERROR]\033[0m $*" >&2; }

cleanup() {
    log "Cleaning work directory..."
    rm -rf "$WORK_DIR"
}

ensure_deps() {
    for cmd in node npm jq zip; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Required command not found: $cmd"
            exit 1
        fi
    done

    # Tizen CLI is optional — we can still build unsigned .wgt without it
    if command -v tizen &>/dev/null; then
        log "Tizen CLI found: $(which tizen)"
        HAVE_TIZEN_CLI=true
    else
        warn "Tizen CLI not found — .wgt files will be unsigned"
        HAVE_TIZEN_CLI=false
    fi
}

get_latest_release_tag() {
    local repo="$1"
    curl -sL "https://api.github.com/repos/$repo/releases/latest" \
        | jq -r '.tag_name // empty'
}

get_branch_head() {
    local repo="$1" branch="$2"
    curl -sL "https://api.github.com/repos/$repo/commits/$branch" \
        | jq -r '.sha // empty' | head -c 12
}

# ─── Build stremio-web ───────────────────────────────────────────────────────

build_stremio_web() {
    local repo="$1" ref="$2" work="$3"

    log "Cloning $repo @ $ref..."
    if [[ "$ref" == "latest-release" ]]; then
        local tag
        tag=$(get_latest_release_tag "$repo")
        if [[ -z "$tag" ]]; then
            err "Could not determine latest release for $repo"
            return 1
        fi
        log "Latest release tag: $tag"
        git clone --depth 1 --branch "$tag" "https://github.com/$repo.git" "$work/stremio-web"
    else
        git clone --depth 1 --branch "$ref" "https://github.com/$repo.git" "$work/stremio-web"
    fi

    cd "$work/stremio-web"

    # Apply patches if any exist
    if [[ -d "$PATCHES_DIR/stremio-web" ]]; then
        for patch in "$PATCHES_DIR/stremio-web"/*.patch; do
            [[ -f "$patch" ]] || continue
            log "Applying patch: $(basename "$patch")"
            git apply "$patch" || warn "Patch failed: $(basename "$patch")"
        done
    fi

    log "Installing dependencies..."
    npm ci --no-audit 2>&1 | tail -3

    log "Building stremio-web..."
    npm run build 2>&1 | tail -5

    # The build output is typically in ./build or ./dist
    local build_dir=""
    for candidate in build dist; do
        if [[ -d "$work/stremio-web/$candidate" ]]; then
            build_dir="$work/stremio-web/$candidate"
            break
        fi
    done

    if [[ -z "$build_dir" ]]; then
        err "Could not find stremio-web build output"
        return 1
    fi

    echo "$build_dir"
}

# ─── Package .wgt ────────────────────────────────────────────────────────────

package_wgt() {
    local variant_name="$1"
    local app_dir="$2"      # directory containing the app files (config.xml, index.html, etc.)
    local output_name="$3"

    local wgt_path="$OUTPUT_DIR/$output_name.wgt"

    log "Packaging $output_name.wgt..."

    cd "$app_dir"

    if [[ "$HAVE_TIZEN_CLI" == "true" ]]; then
        # Use Tizen CLI for proper signing
        tizen build-web -e ".*" -e "node_modules/*" -e "package*.json" -e "yarn.lock" -e ".git*" 2>/dev/null || true
        tizen package -t wgt -o "$OUTPUT_DIR" -- "${app_dir}/.buildResult" 2>/dev/null || {
            # Fallback: package as unsigned zip
            warn "Tizen CLI packaging failed — creating unsigned .wgt"
            (cd "$app_dir" && zip -r "$wgt_path" . \
                -x ".*" "node_modules/*" "package*.json" ".buildResult/*")
        }

        # Rename if tizen CLI produced a differently-named file
        local tizen_output
        tizen_output=$(ls "$OUTPUT_DIR"/*.wgt 2>/dev/null | head -1)
        if [[ -n "$tizen_output" && "$tizen_output" != "$wgt_path" ]]; then
            mv "$tizen_output" "$wgt_path"
        fi
    else
        # No Tizen CLI — create unsigned .wgt (it's just a zip)
        (cd "$app_dir" && zip -r "$wgt_path" . \
            -x ".*" "node_modules/*" "package*.json" ".git/*" ".buildResult/*")
    fi

    if [[ -f "$wgt_path" ]]; then
        local size
        size=$(du -h "$wgt_path" | cut -f1)
        log "✓ Created $output_name.wgt ($size)"

        # Generate SHA256
        sha256sum "$wgt_path" | awk '{print $1}' > "$wgt_path.sha256"
    else
        err "Failed to create $output_name.wgt"
        return 1
    fi
}

# ─── Build a source-based variant ────────────────────────────────────────────

build_source_variant() {
    local name="$1" repo="$2" ref="$3" template="$4" app_id="$5" package_id="$6"
    local work="$WORK_DIR/$name"

    mkdir -p "$work/app"

    # Build stremio-web
    local web_build
    web_build=$(build_stremio_web "$repo" "$ref" "$work") || return 1

    # Copy built web assets into the Tizen app directory
    cp -r "$web_build"/* "$work/app/"

    # Apply Tizen template (config.xml + wrapper)
    apply_template "$template" "$work/app" "$app_id" "$package_id" "$name"

    # Package
    package_wgt "$name" "$work/app" "$name"
}

# ─── Build a wrapper variant (no stremio-web build) ─────────────────────────

build_wrapper_variant() {
    local name="$1" template="$2" app_id="$3" package_id="$4"
    local work="$WORK_DIR/$name"

    mkdir -p "$work/app"

    # Apply template (generates config.xml + index.html)
    apply_template "$template" "$work/app" "$app_id" "$package_id" "$name"

    # Package
    package_wgt "$name" "$work/app" "$name"
}

# ─── Apply Tizen template ───────────────────────────────────────────────────

apply_template() {
    local template="$1" app_dir="$2" app_id="$3" package_id="$4" variant="$5"

    # Copy config.xml template
    local config_template="$TIZEN_DIR/templates/config-${template}.xml"
    if [[ ! -f "$config_template" ]]; then
        config_template="$TIZEN_DIR/templates/config-standard.xml"
    fi

    cp "$config_template" "$app_dir/config.xml"

    # Substitute variables in config.xml
    sed -i "s|{{APP_ID}}|$app_id|g" "$app_dir/config.xml"
    sed -i "s|{{PACKAGE_ID}}|$package_id|g" "$app_dir/config.xml"
    sed -i "s|{{APP_NAME}}|Stremio|g" "$app_dir/config.xml"
    sed -i "s|{{VERSION}}|1.0.0|g" "$app_dir/config.xml"

    # Copy wrapper index.html if it's a wrapper variant
    if [[ "$template" == "web-wrapper" || "$template" == "legacy-wrapper" ]]; then
        local index_template="$TIZEN_DIR/templates/index-${template}.html"
        cp "$index_template" "$app_dir/index.html"
    fi

    # Copy icon
    if [[ -f "$TIZEN_DIR/icons/icon.png" ]]; then
        cp "$TIZEN_DIR/icons/icon.png" "$app_dir/icon.png"
    fi

    # Inject TV remote key handler if building from source
    if [[ "$template" == "standard" || "$template" == "secondary" ]]; then
        local inject_script="$TIZEN_DIR/templates/tizen-inject.js"
        if [[ -f "$inject_script" ]]; then
            # Inject the TV remote handler script into index.html
            if [[ -f "$app_dir/index.html" ]]; then
                sed -i "s|</head>|<script src=\"tizen-inject.js\"></script></head>|" "$app_dir/index.html"
                cp "$inject_script" "$app_dir/tizen-inject.js"
            fi
        fi
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    log "Stremio Tizen Builds — Starting build pipeline"
    log "================================================"

    ensure_deps
    mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

    # Parse matrix.json
    local variants
    variants=$(jq -r '.versions | keys[]' "$ROOT_DIR/matrix.json")

    local release_notes=""

    for variant in $variants; do
        log ""
        log "Building variant: $variant"
        log "────────────────────────────────────"

        local name repo ref template app_id package_id description
        name=$(jq -r ".versions[\"$variant\"].name" "$ROOT_DIR/matrix.json")
        repo=$(jq -r ".versions[\"$variant\"].repo // empty" "$ROOT_DIR/matrix.json")
        ref=$(jq -r ".versions[\"$variant\"].ref // empty" "$ROOT_DIR/matrix.json")
        template=$(jq -r ".versions[\"$variant\"].tizen_template" "$ROOT_DIR/matrix.json")
        app_id=$(jq -r ".versions[\"$variant\"].app_id" "$ROOT_DIR/matrix.json")
        package_id=$(jq -r ".versions[\"$variant\"].package_id" "$ROOT_DIR/matrix.json")
        description=$(jq -r ".versions[\"$variant\"].description" "$ROOT_DIR/matrix.json")

        if [[ -n "$repo" && "$repo" != "null" ]]; then
            # Source-based build
            build_source_variant "$name" "$repo" "$ref" "$template" "$app_id" "$package_id" || {
                warn "Failed to build $name — skipping"
                continue
            }

            # Record version info
            local version commit
            if [[ "$ref" == "latest-release" ]]; then
                version=$(get_latest_release_tag "$repo")
            else
                version="$ref"
            fi
            commit=$(get_branch_head "$repo" "${version:-$ref}")

            release_notes+="**$name**: stremio-web $version ($commit)\n"
        else
            # Wrapper build
            build_wrapper_variant "$name" "$template" "$app_id" "$package_id" || {
                warn "Failed to build $name — skipping"
                continue
            }

            release_notes+="**$name**: $description\n"
        fi
    done

    log ""
    log "================================================"
    log "Build complete! Output files:"
    ls -lh "$OUTPUT_DIR"/*.wgt 2>/dev/null || warn "No .wgt files produced"

    # Write release notes
    echo -e "$release_notes" > "$OUTPUT_DIR/RELEASE_NOTES.md"

    log ""
    log "Done!"
}

main "$@"
