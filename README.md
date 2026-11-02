# DiskTwin — macOS SSD & MicroSD Chameleon Mirror

**DiskTwin** is a native macOS Menu Bar utility (`Swift` / `AppKit` + `Python 3`) that keeps a low-wear mirror of your primary External SSD on an internal MicroSD card and switches APFS volume labels by hardware UUID so all your projects, IDEs, Antigravity workspaces, and scripts resolve `/Volumes/Main 1TB` automatically when traveling.

## Download & Installation

- **Installer (`.dmg`)**: [`dist/DiskTwin-v1.1.0-macOS-arm64.dmg`](dist/DiskTwin-v1.1.0-macOS-arm64.dmg)
- Drag **`DiskTwin.app`** to `/Applications` and launch it.
- **Self-Bootstrapping First Launch**: On first launch, `DiskTwin.app` automatically extracts its core engine to `~/.disk-twin/`, configures macOS flash anti-wear flags (`.metadata_never_index` and `.fseventsd/no_log`), and installs the `launchd` background schedule and login startup agents.

---

## Key Features

1. **UUID-Bound Chameleon Mount (`Desk Mode` ↔ `Road Mode`)**:
   - **Desk Mode**: External SSD is mounted at `/Volumes/Main 1TB`, and the internal MicroSD is mounted at `/Volumes/MicroSD 1TB`.
   - **Road Mode**: In one click, DiskTwin optionally runs an incremental sync, safely ejects the External SSD, and renames/mounts the MicroSD as `/Volumes/Main 1TB` using `diskutil rename <UUID>`. Every app on macOS finds your files at `/Volumes/Main 1TB` with zero reconfiguration.
2. **Hardware Block-Level Thermal & SLC Cache Pacing**:
   - Monitors actual physical megabytes written to the SDXC device via `iostat -Id`.
   - Every **35 GB** written (configurable `15–100 GB`), DiskTwin pauses `rsync` via `SIGSTOP`, flushes kernel buffers (`sync`), and lets the MicroSD fold its pseudo-SLC cache and cool down for **60 seconds** (`30–120s` configurable) before resuming with `SIGCONT`.
3. **Road-Work Safety Lock**:
   - Switching to Road Mode activates a persistent lock that prevents scheduled background syncs from overwriting files modified on the MicroSD while traveling.
   - Switching back to Desk Mode prompts you to sync newer Road Mode files back to the External SSD (`--update`, never deleting SSD files).
4. **Native macOS HIG Monochromatic UI**:
   - Uses 17 monochromatic vector template icons (`NSImage.isTemplate = true`) from [21st.dev Community Icons](https://21st.dev/community/icons) that automatically adapt to Light Mode, Dark Mode, and menu hover states.

---

## Building from Source

```bash
chmod +x ./build_dmg.sh
./build_dmg.sh
```
This compiles `DiskTwin.swift`, bundles `disk_twin.py` and `icons/*.svg` into `DiskTwin.app`, signs the bundle, and generates `dist/DiskTwin-v1.1.0-macOS-arm64.dmg`.
