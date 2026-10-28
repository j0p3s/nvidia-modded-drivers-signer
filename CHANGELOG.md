# Changelog

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
