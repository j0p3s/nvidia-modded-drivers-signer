# Changelog

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
