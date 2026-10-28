# Changelog

## v1.5.0 - 2026-10-28

- **Fix (important):** Fast mode in v1.3.0/v1.4.0 grouped INFs that share one catalog name and copied the small resulting `.cat` back,
  which could overwrite the original shared catalog (for example `nv_dispi.cat`). Do not use those versions.
- Fast mode now gives every GPU INF its own catalog (`<name>_nvsigner.cat`, by changing only the `CatalogFile=` line)
  and runs one Inf2Cat per INF in parallel. The shared original catalog is never touched.
- The original INFs are backed up to `C:\ProgramData\NvidiaModdedDriversSigner\inf_backup\<date>` before being replaced.
- "Parallel jobs" default is now min(8, CPU cores).

## v1.4.0 - 2026-10-28

- New option "Target only this PC's Windows version" (on by default): Inf2Cat is told to check the INFs for the running Windows version only, instead of 7 targets.
- The ETA now has a separate speed model for INF-heavy packages (large INFs are slow to parse), learned per OS target.
- Window layout adjusted for the new option.

## v1.3.0 - 2026-10-28

- New "Fast" mode (on by default): only the INF(s) that contain your GPU are catalogued, in isolated temporary packages.
  Before, Inf2Cat processed the whole driver folder (3+ GB) even for a single INF, which made the run very slow.
- INFs that share the same catalog name are grouped, so catalogs never overwrite each other.
- If an isolated INF needs other driver files, only that INF falls back to the full-folder method.

## v1.2.1 - 2026-10-28

- "Keep only my GPU INF" no longer deletes anything: other `.inf` / `.cat` files are moved to `<folder>_removed_INF_backup`.
- The option is now off by default and the confirmation warns that the NVIDIA `setup.exe` will not work with it
  (it needs all packages and fails with "Required files are missing").

## v1.2.0 - 2026-10-28

- Live elapsed timer, progress percentage and estimated time remaining (ETA) next to the progress bar.
- The progress bar is now determinate (it was an endless animation).
- ETA covers every phase: scan, tool download (uses the real download speed), cleanup, certificate, Inf2Cat and signing.
- Inf2Cat time is estimated from the driver size and the speed measured in previous runs (saved in `stats.json`), so it gets more accurate over time.
- "Finished in mm:ss" / "Stopped after mm:ss" shown when the run ends.

## v1.1.0 - 2026-10-27

- New "Sign ALL INF packages (parallel)" mode.
- Inf2Cat now runs on several package folders at the same time (adjustable "Parallel jobs", 1-8).
- All new `.cat` files are signed in one call (SignTool fallback signs in batches).
- Nested package folders are merged so nothing is processed twice.
- If some packages fail Inf2Cat, the others are still signed (with a warning).
- Total run time is shown in the log.

## v1.0.0 - 2026-10-27

- First release.
- GUI to re-sign NVCleanstall-modded NVIDIA driver INF files.
- GPU detection and "keep only my GPU INF" cleanup.
- Automatic download of Inf2Cat (and signtool as fallback).
- Self-signed certificate creation, trust installation and `.cer` export.
