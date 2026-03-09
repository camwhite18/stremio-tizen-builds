# stremio-tizen-builds

The purpose of this repository is to **automatically build the most up-to-date version** of Stremio for Samsung Tizen TVs.

Every hour, a GitHub Actions workflow checks the upstream [Stremio/stremio-web](https://github.com/Stremio/stremio-web) repository for new releases and commits. When changes are detected, it builds fresh `.wgt` packages and publishes them as a [GitHub Release](../../releases).

> Inspired by [jeppevinkel/jellyfin-tizen-builds](https://github.com/jeppevinkel/jellyfin-tizen-builds), which does the same for Jellyfin.

---

## Versions

Each release includes multiple `.wgt` variants:

| File | Description |
|---|---|
| `Stremio.wgt` | Built with the latest **stable release** of stremio-web |
| `Stremio-main.wgt` | Built from the latest **main branch** (bleeding edge, may be unstable) |
| `Stremio-secondary.wgt` | Stable build with a **different app ID** — allows having two Stremio installs with separate accounts |
| `Stremio-main-secondary.wgt` | Main branch build with a **different app ID** for dual installs |
| `Stremio-WebWrapper.wgt` | Lightweight **iframe wrapper** pointing to Stremio's hosted web app (no build step, always up to date) |
| `Stremio-Legacy.wgt` | Web wrapper targeting older Stremio URL for **Tizen 2.x–4.x TVs** (2015–2018 models) |

### Which one should I use?

- **2019+ TV?** → Use `Stremio.wgt` (stable) or check the Samsung App Store first — Stremio is officially available for 2019+ models.
- **2015–2018 TV?** → Try `Stremio-Legacy.wgt` or `Stremio-WebWrapper.wgt`
- **Want latest features?** → `Stremio-main.wgt`
- **Two accounts?** → Install both `Stremio.wgt` and `Stremio-secondary.wgt`

---

## Compatibility

See [COMPATIBILITY.md](COMPATIBILITY.md) for a community-maintained list of TVs that are known to work or not work.

This list is community-maintained — anyone is welcome to add entries via Pull Request.

---

## Installation

### Option A: Stremio2Samsung GUI Installer (Recommended)

For a GUI installer that automates the entire process, use **[Stremio2Samsung](https://github.com/stremio2samsung/stremio2samsung)**.

It downloads builds from this repository and installs them on your TV with a few clicks.

### Option B: Manual Install with Tizen Studio

#### Prerequisites

- [Tizen Studio with CLI](https://developer.tizen.org/development/tizen-studio/download)
- One of the `.wgt` files from a [Release](../../releases)

#### Steps

1. **Enable Developer Mode on your TV:**
   - Open **Apps** → Enter PIN **12345** → Set **Developer Mode** to **ON**
   - Enter your computer's IP address → **OK** → **Restart** your TV

2. **Connect to your TV via SDB:**

   ```bash
   # Find SDB in your Tizen Studio installation
   ~/tizen-studio/tools/sdb connect <TV_IP_ADDRESS>

   # Verify connection
   ~/tizen-studio/tools/sdb devices
   ```

3. **Install the `.wgt` package:**

   ```bash
   ~/tizen-studio/tools/ide/bin/tizen install -n Stremio.wgt -t <TV_NAME>
   ```

   > You can find your TV name from `sdb devices`.

### Option C: Docker One-Liner

```bash
docker run --rm -it \
  -v $(pwd)/Stremio.wgt:/app/Stremio.wgt \
  ghcr.io/georift/install-jellyfin-tizen \
  <TV_IP_ADDRESS>
```

> This uses the Georift Docker image (originally for Jellyfin) which provides `sdb` and `tizen` CLI in a container. It works for any `.wgt` file.

---

## Common Issues

### Certificate error on install

This happens if you already have a version installed that was signed with a different certificate. **Uninstall the existing app first** (from Settings → Apps → Downloaded, not just removing from the home bar), then install the new one.

### `sdb devices` shows no devices

- Ensure Developer Mode is **ON** on your TV
- Your PC and TV must be on the **same network**
- Run `sdb connect <TV_IP>` first
- **Restart** your TV after enabling Developer Mode

### Install says "failed" but app appears

This is a **known Tizen bug** — the install command reports failure even when it succeeds. Check your TV's app list under **Apps → Downloaded**.

### Where is `sdb`?

| OS | Default Path |
|---|---|
| **Windows** | `C:\tizen-studio\tools\sdb.exe` |
| **macOS** | `~/tizen-studio/tools/sdb` |
| **Linux** | `~/tizen-studio/tools/sdb` |

---

## How the Build Pipeline Works

The build system uses two workflows connected in a pipeline, modeled after [jellyfin-tizen-builds](https://github.com/jeppevinkel/jellyfin-tizen-builds):

### 1. Get Latest Versions (hourly)

Runs every hour (and on push to main). Checks the GitHub API for new commits and releases on [Stremio/stremio-web](https://github.com/Stremio/stremio-web). If changes are found, it updates `versions.json`, regenerates `matrix.json`, commits both, and triggers the build workflow.

### 2. Build New Release (triggered by above, or manually)

Uses a **matrix strategy** to build all variants in **parallel**:

```
┌──────────────────────────────────────────────────────────────┐
│  Get Latest Versions (hourly / on push / manual)             │
│  → checks upstream for new commits/releases                  │
│  → updates versions.json & matrix.json                       │
│  → triggers Build New Release if changes found               │
└─────────────────────────┬────────────────────────────────────┘
                          │
┌─────────────────────────▼────────────────────────────────────┐
│  Build New Release (matrix strategy — parallel jobs)         │
│                                                              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │
│  │ Stremio      │ │ Stremio-main │ │ Stremio-     │  ...    │
│  │ (stable)     │ │ (bleeding    │ │ secondary    │         │
│  │              │ │  edge)       │ │              │         │
│  └──────┬───────┘ └──────┬───────┘ └──────┬───────┘         │
│         │                │                │                  │
│  Each job:                                                   │
│   1. Install Tizen Studio CLI                                │
│   2. Generate signing certificate                            │
│   3. Clone stremio-web (source builds only)                  │
│   4. npm ci && npm build (source builds only)                │
│   5. Apply Tizen config template                             │
│   6. tizen build-web && tizen package                        │
│   7. Upload .wgt artifact                                    │
│                                                              │
│  ┌──────────────────────────────────────────────────┐        │
│  │ Release job: collect all artifacts → GitHub Release│       │
│  └──────────────────────────────────────────────────┘        │
└──────────────────────────────────────────────────────────────┘
```

### Manually triggering a build

From the GitHub Actions UI: **Actions** → **Build New Release** → **Run workflow**.

Or via the GitHub CLI:

```bash
gh workflow run build-new-release.yml
```

### Adding a new variant

1. Add variation entries to `matrix-definition.json` (for source build variations) or add wrapper entries for non-source builds
2. Create a config template in `tizen/templates/` if needed
3. Push to `main` — the update-check workflow will regenerate `matrix.json` automatically

### Applying patches

Drop `.patch` files into `patches/stremio-web/` and they will be applied to the stremio-web source before building. Useful for TV-specific fixes.

---

## Project Structure

```
stremio-tizen-builds/
├── .github/
│   ├── dependabot.yaml                # Weekly GitHub Actions dependency updates
│   └── workflows/
│       ├── get-latest-versions.yml    # Hourly check → update versions → trigger build
│       └── build-new-release.yml      # Matrix build → package .wgt → GitHub Release
├── scripts/
│   ├── build-all.sh                   # Local build script (not used in CI)
│   └── check-updates.sh              # Checks upstream, updates versions & matrix
├── tizen/
│   ├── icons/
│   │   └── icon.png                   # App icon for the Tizen package
│   └── templates/
│       ├── config-standard.xml        # Tizen manifest for source builds
│       ├── config-secondary.xml       # Manifest with alternate app ID
│       ├── config-web-wrapper.xml     # Manifest for web wrapper
│       ├── config-legacy-wrapper.xml  # Manifest for legacy wrapper
│       ├── index-web-wrapper.html     # Hosted Stremio web app wrapper
│       ├── index-legacy-wrapper.html  # Legacy Stremio web app wrapper
│       └── tizen-inject.js           # TV remote handler for source builds
├── patches/
│   └── stremio-web/                   # Optional .patch files applied before build
├── matrix.json                        # Build matrix (auto-generated, do not edit)
├── matrix-definition.json             # Variation definitions (secondary, wrappers)
├── versions.json                      # Tracked versions (auto-updated by CI)
├── package.exp                        # Expect script for Tizen CLI signing
├── COMPATIBILITY.md                   # Community TV compatibility list
├── LICENSE
└── README.md
```

---

## License

MPL-2.0 — see [LICENSE](LICENSE) for details.

Stremio is copyright Smart Code and available under the GPLv2 license. This repository only provides build automation and Tizen packaging for the open-source stremio-web project.

---

## Credits

- [Stremio](https://www.stremio.com/) for the streaming platform and open-source web client
- [jeppevinkel/jellyfin-tizen-builds](https://github.com/jeppevinkel/jellyfin-tizen-builds) for the build pipeline inspiration
- [movizon/stremio-webapp-tizenos](https://github.com/movizon/stremio-webapp-tizenos) for pioneering Stremio on Tizen
- [ItsAkilesh/StremioTizenInator](https://github.com/ItsAkilesh/StremioTizenInator) for Tizen 7.0+ builds
- [Stremio2Samsung](https://github.com/stremio2samsung/stremio2samsung) for the GUI installer
