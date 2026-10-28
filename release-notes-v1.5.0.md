## NVIDIA Modded Drivers Signer v1.5.0

Single-file GUI that re-signs the modified `.inf` files of NVCleanstall-modded NVIDIA drivers that you already have, so they can be installed again. Download the `.cmd`, double-click, accept UAC, pick the driver folder, press **SIGN DRIVER**.

### Highlights

- **Fast mode:** every INF that contains your GPU gets its own catalog (`<name>_nvsigner.cat`) and one Inf2Cat runs per INF, in parallel, in tiny temporary packages. The multi-GB driver folder is no longer hashed, and the original shared catalog (for example `nv_dispi.cat`) is not touched.
- **Target only this PC's Windows version:** much faster Inf2Cat runs.
- **Sign ALL INF packages** mode, adjustable parallel jobs (1-8, default min(8, CPU cores)).
- Elapsed timer, percentage and ETA that learns from previous runs.
- Automatic download of Microsoft's Inf2Cat (and SignTool if needed) from the official NuGet packages.
- "Keep only my GPU INF" now moves files to a backup folder instead of deleting them (off by default).
- Original INFs are backed up before being modified.
- README with security notes, undo instructions and legal notices.

### Requirements

Windows 10 / 11 x64, Windows PowerShell 5.1 (included), administrator rights, internet on first run.

### Notes

- Use at your own risk. Back up your data and create a restore point before installing a modified driver.
- The NVIDIA `setup.exe` needs every INF/CAT of the package: keep "Keep only my GPU INF" off if you use it.
- Not affiliated with NVIDIA, Microsoft or TechPowerUp. No NVIDIA drivers or third-party tools are included in this release. See the README for the full disclaimer.
- Versions 1.3.0 and 1.4.0 were never released: their Fast mode could overwrite the original shared catalog. Fixed in this version.

### Asset

`nvidia modded drivers signer (v1.5.0).cmd`

SHA-256: `8bdcf4c93caf4609daff0571f8589a280a680450f4090a33183106713b4b05c5`

Full changelog: [CHANGELOG.md](https://github.com/j0p3s/nvidia-modded-drivers-signer/blob/main/CHANGELOG.md)
