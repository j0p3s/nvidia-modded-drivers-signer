## NVIDIA Modded Drivers Signer v2.3.0

Single-file GUI that re-signs the modified `.inf` files of NVCleanstall-modded NVIDIA drivers that you already have, so they can be installed again. Download the `.cmd`, double-click, accept UAC, pick the driver folder, press **SIGN DRIVER**.

### What is new

- **v2.3.0:** MakeCat is now the default catalog engine (ACCEPTED by Windows in the v2.2.2 engine test, about 20 s instead of minutes). Inf2Cat stays in the dropdown as the fallback.
- **v2.3.0 - expanded files.** With the compressed `nvngx_dlssd.dl_` hashed as stored, Windows still found no hash: it checks the expanded file. The tool now expands such files with `expand.exe` (temporary folder only) and hashes the result under the name the INF uses.
- **v2.2.1 - compressed files.** The file Windows kept failing on, `nvngx_dlssd.dll`, is not missing: the folder has `ngx-builtins\nvngx_dlssd.dl_` (compressed; the INF names the expanded file and Windows setup finds the compressed one). The tool treated it as missing and left it out of the catalog. Files stored as `name.dl_` / `.sy_` / `.ex_` are now recognised and hashed as stored, under the name the INF uses.
- **v2.2.0 - fixes a wrong verdict.** In v2.1.2 every pnputil line said ACCEPTED while Windows had opened the *"Windows can't verify the publisher of this driver software"* prompt (pnputil only returned 0 because the prompt was answered with *Install anyway*). The result is now read from `setupapi.dev.log`: a catalog that does not cover every file is **NOT TRUSTED**, with the file Windows stopped at. The "INF + files" scope of the experimental engines now hashes **all files of the driver folder** (new option **Hash all driver files**), not only the ones listed in `[SourceDisksFiles]`. INF-only catalogs are no longer sent to Windows in the engine test. Corrects my earlier claim that a missing file makes Windows answer "file not found".
- **v2.1.2:** fixes a slowdown of the Inf2Cat scopes in "Test all engines" (v2.1.0 ran one single-threaded Inf2Cat for all INFs of a folder; it is back to one process per INF, in parallel, at most 4 at once when files are read). New **Stop step** button: skips the running step (Inf2Cat, MakeCat, generate-cat-file) without touching your driver folder.
- **v2.1.1:** the scan tells you whether a file that is named in `[SourceDisksFiles]` but missing from the folder is also **copied by the INF**. If it is, no catalog can hold a hash for that file (corrected in v2.2.1: Windows does not say "file not found", it shows the "can't verify the publisher" prompt). MakeCat's per-member chatter is no longer written to the log and the report when the catalog succeeds.
- **v2.1.0 - one shared catalog per driver folder** for the experimental engines (MakeCat, libwdi-style, generate-cat-file). The 8 GPU INFs of NVIDIA's `Display.Driver` list the same ~219 files (2.9 GB); they were hashed once per INF, now once in total (MakeCat and libwdi-style "INF + files" take about 20 s on a test machine). The Inf2Cat scope of "Test all engines" also builds one catalog per folder.
- **pnputil test explains itself:** when Windows rejects a package, the error lines Windows wrote to `setupapi.dev.log` during that call are shown in the log and saved in the engine report. The package handed to Windows is a hard-linked copy of the whole driver folder; the original files are never written to.
- Progress for long runs ("still running" lines, members and MB per run). Normal Inf2Cat flow unchanged (one catalog per INF, in parallel).

### Requirements

Windows 10 / 11 x64, Windows PowerShell 5.1 (included), administrator rights, internet on first run. The generate-cat-file engine also needs WSL with a Linux distribution that has `gcc` and `make`.

### Notes

- Use at your own risk. Back up your data and create a restore point before installing a modified driver.
- **The MakeCat, libwdi-style and generate-cat-file engines are experimental.** They were not verified on a real Windows system by the author; use the "Test all engines" button (with the pnputil test) before relying on them, and use Inf2Cat if Windows rejects them.
- The pnputil test imports the package into the driver store (about 3 GB for the NVIDIA display package) and removes it again; keep enough free space on the system drive. If the Windows Security prompt opens during it, choose *Don't install this driver software*: the result is read from the log either way.
- The NVIDIA `setup.exe` needs every INF/CAT of the package: keep "Keep only my GPU INF" off if you use it.
- Not affiliated with NVIDIA, Microsoft or TechPowerUp. No NVIDIA drivers or third-party tools are included in this release. See the README for the full disclaimer.

### Asset

`nvidia modded drivers signer (v2.3.0).cmd`

SHA-256: `b4c3d71d0b13da5947196fb96427f26b5ea0548fda3930ec66d46527e9d06290`

Full changelog: [CHANGELOG.md](https://github.com/j0p3s/nvidia-modded-drivers-signer/blob/main/CHANGELOG.md)
