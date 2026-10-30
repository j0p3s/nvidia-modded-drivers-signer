# Changelog

## v2.3.0 - 2026-10-30

- **MakeCat is now the default catalog engine** (was Inf2Cat). Reason: in the v2.2.2 engine test MakeCat "all files" (20.9 s) and libwdi "all files" were ACCEPTED by Windows (pnputil, no signature errors in setupapi.dev.log), while Inf2Cat takes minutes. Inf2Cat stays available in the dropdown as the fallback.
- No other change.

## v2.2.2 - 2026-10-30

Found with the v2.2.1 report: with `nvngx_dlssd.dl_` hashed as stored under the name `nvngx_dlssd.dll`, Windows still said *Catalog did not contain file hash* for `nvngx_dlssd.dll`. Windows checks a compressed file as the **expanded** file.

- **Fix:** compressed files are expanded with `expand.exe` into the temporary stage folder (`_expanded`, never in your driver folder) and the catalog member `nvngx_dlssd.dll` is the hash of the expanded file. If expand.exe fails, the compressed file is hashed as before and the member summary says so. The compressed file is still a member under its own name.
- Scan, member summary and verdict texts updated.

## v2.2.1 - 2026-10-30

Found with `dir /s /b *nvngx_dlss*` on the driver folder after the v2.2.0 report: the file that Windows kept failing on, `nvngx_dlssd.dll`, is not missing. The folder contains `ngx-builtins\nvngx_dlssd.dl_`, the **compressed** form. The INF names the expanded file and Windows setup finds the compressed one by itself.

- **Fix:** files that are stored compressed (`name.dl_`, `name.sy_`, `name.ex_`, ...) are now recognised. Before, they were reported as "missing" and left out of the catalog, so Windows found no hash for them. They are now catalog members: the hash of the compressed file under the name the INF uses (`nvngx_dlssd.dll`), and, because the "all files" scope covers the folder, also under their own name (`nvngx_dlssd.dl_`). The scan and the member summary say how many files are stored compressed.
- **Correction:** the v2.2.0 notes called `nvngx_dlssd.dll` a file that was probably missing from the folder. It is present, compressed.
- When Windows still names a file in the pnputil test, the report says whether the file is in the package, only in compressed form, or not at all. If a compressed file is still named after this version, Windows checks the expanded file instead of the compressed one; that would be the next thing to implement.

## v2.2.0 - 2026-10-30

Found with the "Test all engines" report of v2.1.2: every pnputil line said ACCEPTED, but Windows had opened the *"Windows can't verify the publisher of this driver software"* prompt and `setupapi.dev.log` said *Failed to verify file ... Catalog did not contain file hash ... Driver package appears to be tampered*. pnputil had only returned 0 because the prompt was answered with *Install this driver software anyway*.

- **Fix: wrong verdict.** The pnputil result is now read from `setupapi.dev.log`. A package whose files are not all covered by the catalog is reported as **NOT TRUSTED (file: hash not in the catalog)** even when pnputil returns 0. The report says whether that file is in the package or not, and explains the exit code. Before, this case was shown as ACCEPTED.
- **Fix: the "INF + files" scope was not enough.** It hashed only the files listed in `[SourceDisksFiles]` (219 files, while the folder holds 263 files including the INF and CAT ones). The NVIDIA INFs also copy whole directories, so Windows stopped at files that had no hash. The scope is now **all files of the driver folder** (`.inf` and `.cat` excluded): option renamed to **Hash all driver files**, test entries to "MakeCat all files", "libwdi all files", "gencat all files". The member summary says how many files come from outside the INF lists. The Inf2Cat entry keeps Inf2Cat's own definition ("INF+files").
- **INF-only catalogs are no longer sent to Windows in the engine test.** They hold no file hashes, so Windows rejects them (it did in every test) and opens the prompt for nothing. The row shows `not run (INF-only)`.
- **Correction:** v2.1.1 / v2.1.2 said that a file named in the INF but missing from the folder makes Windows answer "file not found" and that this caused pnputil's exit code 2. That was wrong: the exit code 2 came from the minimal package used before v2.1.0, and a missing file shows up as a missing hash. The scan note, the member note, the README and the dialog texts were corrected.
- The engine report ends the table with a legend for the Windows column. The engine test dialog explains the prompt (choose *Don't install*; the result is read from the log either way).
- No change to the catalog engines themselves and to the normal signing flow, except that the experimental engines now hash the whole driver folder when **Hash all driver files** is on.

## v2.1.2 - 2026-10-30

- **Fix:** since v2.1.0 the Inf2Cat scopes of "Test all engines" ran ONE Inf2Cat process for all INFs of a folder. Inf2Cat is single-threaded, so the 8 INFs were processed one after the other (one core busy, 1.3 GB of RAM, minutes without progress). Inf2Cat is back to one catalog and one process per INF, run in parallel; only the MakeCat, libwdi-style and generate-cat-file engines share one catalog per folder.
- When Inf2Cat has to read the driver files (engine test "INF + files", retry in a normal run) at most 4 processes run at once, because each one maps more than 1 GB.
- New **Stop step** button (enabled while something runs). It stops the running Inf2Cat / MakeCat / generate-cat-file process tree. In *Test all engines* the test is shown as STOPPED and the next one starts; in a normal run the run ends with "Stopped by user. Nothing was changed in the driver folder." The Inf2Cat "still running" line says the button exists.

## v2.1.1 - 2026-10-30

Found with the first "Test all engines" report of v2.1.0 (MakeCat INF+files 21.0 s and libwdi INF+files 19.2 s for 8 INFs and 219 files, down from many minutes; every result verified 8/8).

- The scan now says whether a file that is named in `[SourceDisksFiles]` but missing from the folder is also **copied by the INF** (named in any other section). If it is, no catalog can hold a hash for it; if it is not, the missing file is harmless. (v2.2.0 correction: the first version of this note said Windows answers "file not found"; the real Windows behaviour is the "can't verify the publisher" prompt, see v2.2.0.) The same information is added to the member summary of each catalog.
- MakeCat: the one-line-per-member output ("processing", "attribute", "opened") is dropped from the log and the report when the catalog was built successfully (about 1 900 lines for 227 members); failures keep the full output. The setupapi.dev.log excerpt of the pnputil test is no longer buried in it.

## v2.1.0 - 2026-10-30

Found with the log of a "Test all engines" run on a GeForce RTX 3080 Laptop GPU (8 GPU INFs in `Display.Driver`, each listing the same 219 files, 2 918 MB).

- **One shared catalog per driver folder** for MakeCat, libwdi-style and generate-cat-file (`<folder>_nvsigner.cat`, for example `display.driver_nvsigner.cat`). The INFs of a folder are members of the same catalog, like the original `nv_dispi.cat`, and each listed file is hashed once. Before, every INF got its own catalog and the same 2.9 GB were hashed eight times, which made "INF + files" very slow. In the test, the Inf2Cat "INF + files" scope also builds one catalog per folder now (one run instead of eight).
- Inf2Cat in the normal (non-test) flow is unchanged: one catalog per INF, in parallel.
- **pnputil test:** the package given to Windows is now a throw-away copy of the whole driver folder (NTFS hard links; the original files are never written to) with the new INF(s) and catalog. Before, only the files the INF lists were included, which could leave out files Windows needs (for example a same-named file in another sub-folder).
- **pnputil diagnostics:** when Windows rejects a package, the error lines that it wrote to `C:\Windows\INF\setupapi.dev.log` during that call are shown in the log and saved in the engine report. This turns "The system cannot find the file specified" into the name of the file or the signature problem.
- The scan now warns about files named in `[SourceDisksFiles]` that are not in the folder (for example after components were removed) and about file names that occur in more than one sub-folder.
- Long catalog runs report progress: MakeCat and generate-cat-file print a "still running" line every 15 s, libwdi-style every 20 s (files hashed so far). Each run first logs how many members and megabytes it is going to hash.
- The "Test all engines" summary counts catalogs for Signed and INFs for Verify, and the header shows how many folders were processed.
- Window text of the Fast option updated.

## v2.0.0 - 2026-10-30

- The four catalog engines are now first-class and listed in this order: **MakeCat**, **libwdi-style**, **generate-cat-file (WSL)** and **Inf2Cat**. The "Test all engines" list follows the same order.
- Inf2Cat stays the default selection (it is the only engine verified by Microsoft's own tooling); the other three are experimental until you have confirmed them with the pnputil test.
- Major version because the engine dropdown changed (the item positions are different from v1.7.0 and earlier); the signing logic is the same as v1.7.0.

## v1.7.0 - 2026-10-30

- **Four selectable catalog engines** so every alternative to Inf2Cat can be tested on your own files:
  - **Inf2Cat** (standard, unchanged behaviour).
  - **MakeCat** (since v1.6.0): generated `.cdf`, Microsoft `makecat.exe`.
  - **libwdi-style**: native `CryptCAT*` API (wintrust.dll) called from a C# class compiled with `Add-Type`; SHA1 member hashes, PE images (`SPC_PE_IMAGE_DATA`) and INF/flat files (`SPC_LINK`), `HWID1`/`OS` attributes; follows the approach of libwdi `pki.c`. Runs on a background thread so the window keeps responding.
  - **generate-cat-file** (LINBIT): built and run inside WSL. The source is downloaded at a pinned commit and verified with SHA-256 before it is built in `~/.nvsigner-gencat`; the catalog is then signed on Windows.
- New option **Hash listed files** (on by default) for the experimental engines: the catalog also contains the hashes of the files listed in the INF's `[SourceDisksFiles]`, like Inf2Cat. Off = INF hash only.
- New **Test all engines...** button: builds, times, signs and verifies (`signtool verify /pa /c`) the catalogs with every selected engine and scope in a temporary folder (the driver folder is not touched), and shows a summary table in the log and in `engine_test_<date>.txt`. Optional `pnputil` acceptance test: adds the package (INF + catalog + listed files) to the driver store, records whether Windows accepted it, and removes only what it added.
- Inf2Cat engine: when the isolated INF fails (it needs the files it lists), the INF is now retried together with only the files it lists (NTFS hard links, copies if on another drive) before falling back to the whole driver folder. This avoids processing every INF of a multi-GB folder.
- All experimental engines are still verified with `signtool verify` and require "Fast" mode (GPU INFs only).

## v1.6.0 - 2026-10-28

- New experimental "Catalog engine" option: **MakeCat**. Each GPU INF gets a generated `.cdf` and a catalog built without parsing the INF
  (Inf2Cat can be very slow with huge INFs). `makecat.exe` is searched in an installed Windows Kit, then downloaded from the SDK BuildTools / WDK NuGet packages.
- With MakeCat, every INF is verified against its catalog with `signtool verify /pa /c`.
- Inf2Cat engine: per-INF timing in the log and a "still running" message every 60 s, to spot a stuck Inf2Cat.

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
