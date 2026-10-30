# NVIDIA Modded Drivers Signer

A single-file GUI (`.cmd`) that re-signs the modified `.inf` files of **NVCleanstall-modded NVIDIA drivers** that you already have on your own PC, so the package can be installed again. It focuses on **the INF files that contain your GPU** to keep the process fast.

No installation required: the tool downloads what it needs (Microsoft's Inf2Cat, or the tools of the engine you choose) automatically.

> **Important:** please read the [Disclaimer and legal notices](#disclaimer-and-legal-notices) before using this tool.

## Table of contents

- [Why?](#why)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
- [Catalog engines and how to test them](#catalog-engines-and-how-to-test-them)
- [What the tool changes on your PC](#what-the-tool-changes-on-your-pc)
- [Troubleshooting](#troubleshooting)
- [Security notes and how to undo everything](#security-notes-and-how-to-undo-everything)
- [Disclaimer and legal notices](#disclaimer-and-legal-notices)
- [Version](#version)
- [License](#license)

## Why?

NVCleanstall (and manual edits, for example adding a laptop GPU hardware ID) change the driver `.inf` files. That invalidates the original catalog (`.cat`), so Windows treats the modified package as unsigned. This tool rebuilds catalogs for the modified INFs and signs them with a local, self-signed certificate that it can also trust on your PC.

## Features

- Dark, simple GUI (batch + PowerShell WinForms, one `.cmd` file)
- Detects your NVIDIA GPU (`VEN_10DE&DEV_xxxx`) or lets you type the device ID
- Finds the `.inf` files that contain your GPU
- **Fast mode:** only the GPU INFs are processed, in tiny temporary packages. Inf2Cat: one catalog per INF (`<name>_nvsigner.cat`), run in parallel. Experimental engines: **one shared catalog per driver folder** (`<folder>_nvsigner.cat`), so a file that several INFs list is hashed only once
- Option to target only the Windows version running on this PC (much faster)
- Four selectable **catalog engines**, listed in this order: **MakeCat**, **libwdi-style** (native CryptCAT API), **generate-cat-file** (via WSL) and **Inf2Cat** (Microsoft's standard tool, the default selection). The first three are experimental alternatives that do not parse the INF
- **Test all engines** button: builds, signs and checks the catalogs with every engine on your own files, times them, and (optionally) asks Windows itself whether it accepts each one; when Windows says no, the matching lines of `setupapi.dev.log` explain why
- Downloads what the chosen engine needs automatically (Inf2Cat / MakeCat / SignTool from the official NuGet packages on nuget.org, only once)
- Creates a self-signed code-signing certificate (10 years) and can trust it in *Trusted Root* and *Trusted Publishers*
- Signs the catalogs (PowerShell `Set-AuthenticodeSignature`, falls back to `signtool`, also downloaded automatically)
- **Sign ALL INF packages** mode for several packages at once
- Drag and drop a folder onto the path box
- Exports the certificate as `.cer`
- Live log, elapsed timer, percentage and estimated time remaining (ETA); the estimate learns from previous runs
- **Stop step** button: stops the step that is running (Inf2Cat, MakeCat, generate-cat-file). In *Test all engines* it skips that test and goes on with the next one; in a normal run it stops cleanly without touching your driver folder

## Requirements

- Windows 10 / 11 x64
- Windows PowerShell 5.1 (included in Windows)
- Administrator rights (the tool asks for UAC on start)
- Internet connection on first run (Inf2Cat download, a large package that is cached afterwards)
- Only for the *generate-cat-file* engine: WSL with a Linux distribution that has `gcc`, `make`, `bash` and `sha1sum` (`sudo apt install build-essential`)
- A driver package that **you** legitimately obtained and are allowed to modify and use (see the legal notices)

## Usage

> **Want to run the NVIDIA `setup.exe`?** Leave "Keep only my GPU INF" **off**. The installer needs every INF/CAT of the package and shows "Required files are missing" otherwise.

1. Download `nvidia modded drivers signer (v2.2.2).cmd`.
2. Double-click it and accept the UAC prompt.
3. Select (or drop) the extracted modded driver folder, the one NVCleanstall produced, containing `Display.Driver\nv_dispi.inf`.
4. Press **Detect GPU** (or type your device ID, for example `DEV_2518`).
5. Choose your options and press **SIGN DRIVER**.
6. Install the signed driver, for example:

```
pnputil /add-driver "C:\path\to\Display.Driver\nv_dispi.inf" /install
```

Before installing a modified driver, create a Windows restore point and keep a copy of the original package.

## Options

| Option | Default | What it does |
|---|---|---|
| Catalog engine | Inf2Cat | Dropdown order: **MakeCat**, **libwdi-style**, **generate-cat-file (WSL)**, **Inf2Cat**. **Inf2Cat** is the standard Microsoft tool and stays selected by default. The other three are experimental alternatives that build each catalog without parsing the INF (see [Catalog engines](#catalog-engines-and-how-to-test-them)) and only work with the GPU INFs (Fast mode). Their catalogs are checked with `signtool verify /pa /c` afterwards, but you should still test with `pnputil` or the **Test all engines** button before relying on them. |
| Hash all driver files | On | Experimental engines only. The shared catalog also gets the hash of **every file of the driver folder** (the files the INFs list and the ones they copy as whole directories, such as `ngx-builtins` or `Display.NvContainer\plugins`; `.inf` and `.cat` files are left out). Windows checks every file it copies against the catalog, and one missing hash is enough for it to show the *"Windows can't verify the publisher of this driver software"* prompt. Off = INF hash only: faster, but Windows rejects it whenever the INF copies files (it did in every test so far). |
| Fast: only the GPU INFs, in tiny temp packages | On | Only the INFs that contain your GPU are copied into tiny temp packages and their `CatalogFile=` line is pointed to a new catalog. **Inf2Cat:** one catalog per INF (`<name>_nvsigner.cat`), one Inf2Cat per INF in parallel; if an INF needs other driver files it is retried with only the files it lists, then with the full folder (slower). **Other engines:** the INFs of one folder share one catalog (`<folder>_nvsigner.cat`, for example `display.driver_nvsigner.cat`). The original shared catalog (for example `nv_dispi.cat`) is never touched. The original INFs are backed up first (see below). |
| Target only this PC's Windows version | On | Inf2Cat checks each INF once per target OS. Using only the Windows version running on this PC makes it much faster. Turn it off if you will install the driver on other Windows versions. |
| Keep only my GPU INF | Off | Moves every other `.inf` and its `.cat` to `<folder>_removed_INF_backup` (nothing is deleted). **The NVIDIA `setup.exe` will not work afterwards**; install with `pnputil` / Device Manager instead. |
| Trust certificate on this PC | On | Adds the certificate to the LocalMachine *Root* and *TrustedPublisher* stores. See the security notes. |
| Sign ALL INF packages (parallel) | Off | Signs every INF package found in the folder instead of only your GPU INFs. Slower. Disables "Fast" and "Keep only my GPU INF" and does not need a GPU device ID. |
| Parallel jobs | min(8, CPU cores) | How many Inf2Cat processes run at the same time. Set it to 1 if you ever see odd Inf2Cat errors. When Inf2Cat also has to read the driver files ("INF + files" in the engine test, and the retry in a normal run) at most 4 run at once, because each one maps more than 1 GB of memory. |

## Catalog engines and how to test them

A catalog (`.cat`) lists the hash of the INF (and of the files the INF installs) and is signed. Inf2Cat is Microsoft's tool for this, but it parses the whole INF and checks it once per target Windows version, which can be very slow for NVIDIA's huge INFs. The other engines skip that step. **They are experimental: whether Windows accepts what they produce depends on your files and your Windows version, and was not verified by the author on a real system. Test before you rely on them.**

| Engine (dropdown order) | How it works | Needs |
|---|---|---|
| **MakeCat** | Generates a `.cdf` (SHA256 hashes, OS attributes) and runs Microsoft's `makecat.exe`. | `makecat.exe` is searched in an installed Windows Kit, then in the SDK BuildTools / WDK NuGet packages. |
| **libwdi-style** | Builds the catalog with the native `CryptCAT*` API of `wintrust.dll`, called from a small C# class compiled on the fly (SHA1 member hashes, PE images with `SPC_PE_IMAGE_DATA`, INF/flat files with `SPC_LINK`, `HWID1` and `OS` attributes). It follows the approach used by the [libwdi](https://github.com/pbatard/libwdi) project (`pki.c`); no libwdi code is included. | Nothing to download. |
| **generate-cat-file** | The Linux C tool [LINBIT/generate-cat-file](https://github.com/LINBIT/generate-cat-file) (SHA1, unsigned output), built and run **inside WSL**; the catalog is then signed on Windows. | WSL with `gcc`, `make`, `bash`, `sha1sum`. The source is downloaded from GitHub at a pinned commit and verified with SHA-256 before it is built in `~/.nvsigner-gencat` inside WSL. |
| **Inf2Cat** (standard) | Microsoft's WDK tool. Reference behaviour. | Downloaded automatically (large package, once). |

With **Hash all driver files** on (default), the experimental engines hash the INFs plus every other file under the driver folder (`.inf` / `.cat` excluded; a file stored compressed, for example `nvngx_dlssd.dl_`, is expanded with `expand.exe` and hashed under the name the INF uses, and also hashed as stored under its own name; a file name that occurs in more than one sub-folder is hashed once, the first one wins). Up to v2.1.2 only the files listed in `[SourceDisksFiles]` were hashed, which is not enough: the NVIDIA INFs also copy whole directories (`ngx-builtins`, `NvCamera`, `Display.NvContainer\plugins`, ...) whose files are not listed there, and Windows refused such a catalog. With the option off, only the INFs are hashed.

**One catalog per folder (v2.1.0).** NVIDIA's display package has several GPU INFs (`nvaci.inf`, `nvami.inf`, ...) in the same folder, and they all list the same ~200 files (about 3 GB). Up to v2.0.0 every INF got its own catalog, so those files were hashed once per INF. Now the experimental engines put all the INFs of a folder into a single catalog and hash each file once (the same layout as the original `nv_dispi.cat`). Inf2Cat is the exception: it works on one core per process, so it keeps one catalog and one process per INF and the processes run in parallel. If a file name occurs in more than one sub-folder, the first one is used and the log says so.

### Test all engines

1. Pick the driver folder and your GPU, then press **Test all engines...**.
2. Choose which engine and scope combinations to run (listed in the same order as the dropdown; the quick ones are preselected). Optionally tick the `pnputil` test.
3. Everything is built in a temporary folder: your driver folder is not changed. Each result is signed, then verified with `signtool verify /pa /c`.
4. At the end you get a table in the log (and a report file in `C:\ProgramData\NvidiaModdedDriversSigner\engine_test_<date>.txt`) with the catalog time, how many catalogs were signed, how many passed `signtool verify`, and, if enabled, what Windows said.

How to read it:

| Column | Meaning |
|---|---|
| Catalog time | Time to build the catalogs for all your GPU INFs with that engine. |
| Signed | Catalogs whose signature is `Valid` on this PC (needs *Trust certificate*). |
| Verify | `signtool verify /pa /c` says the INF hash is in the catalog and the signature is trusted. |
| Windows (pnputil) | Optional. A throw-away copy of the driver folder (NTFS hard links, so it takes no extra space on the same drive) with the new INF(s) and catalog is added to the driver store with `pnputil /add-driver` (no device is touched) and the entry it created is removed again with `/delete-driver` (never with `/force`). **The verdict is read from `C:\Windows\INF\setupapi.dev.log`, not from the exit code.** **ACCEPTED** = the package was imported and the log shows no signature or hash error. **NOT TRUSTED** = Windows found a file whose hash is not in the catalog (the report names the file and says whether it is in the package); pnputil returns 0 in that case only if you click *Install this driver software anyway* on the Windows Security prompt, which does not make the catalog good. **REJECTED** = pnputil failed for another reason (the log lines are shown and saved in the report). **not run (INF-only)** = catalogs with only the INF hash are never sent to Windows because it rejects them whenever the INF copies files, and it would only open the prompt. |

Use the fastest engine that is **ACCEPTED**. If an experimental engine says `NOT TRUSTED` or `REJECTED`, read the `setupapi.dev.log` lines first (they are in the report): they name the file Windows stopped at. If that file is not in the driver folder, no catalog can fix it: restore it from the original NVIDIA package. Otherwise use Inf2Cat. If the Windows Security prompt opens during the test, choose *Don't install this driver software*; the result is read from the log either way. Windows copies all the files of the package into its driver store for this test (about 3 GB for the NVIDIA display package), so each pnputil check takes a while and needs that free space on the system drive.

Manual check of a single result (same idea as the button):

```
pnputil /add-driver "C:\path\to\package\nvcvi.inf"
pnputil /enum-drivers
pnputil /delete-driver oemNN.inf
```

(`oemNN.inf` is the name `/enum-drivers` shows for the package you just added.)

## What the tool changes on your PC

| Item | Location / effect |
|---|---|
| Driver folder you select | In Fast mode the GPU INFs get a changed `CatalogFile=` line and a new `<name>_nvsigner.cat` (Inf2Cat) or `<folder>_nvsigner.cat` (other engines) file is added. Original INFs are backed up first. `*_nvsigner.cat` files left by older versions are no longer used and can be deleted. No NVIDIA binaries (`.sys`, `.dll`, `.exe`) are modified. |
| INF backups | `C:\ProgramData\NvidiaModdedDriversSigner\inf_backup\<date>` |
| Downloaded tools (Inf2Cat, MakeCat, signtool, generate-cat-file sources) | `C:\ProgramData\NvidiaModdedDriversSigner\tools` |
| generate-cat-file build (only if you use that engine) | `~/.nvsigner-gencat` inside your WSL distribution |
| Engine test reports | `C:\ProgramData\NvidiaModdedDriversSigner\engine_test_<date>.txt` |
| Learned Inf2Cat speed (for the ETA) | `C:\ProgramData\NvidiaModdedDriversSigner\stats.json` |
| Exported certificate | `C:\ProgramData\NvidiaModdedDriversSigner\NvidiaModdedDriversSigner.cer` |
| Signing certificate (with private key) | `Cert:\LocalMachine\My`, subject `CN=NVIDIA Modded Drivers Signer` |
| Trusted certificate (if enabled) | `Cert:\LocalMachine\Root` and `Cert:\LocalMachine\TrustedPublisher` |
| Temporary files | `%TEMP%\nvsigner_stage_*` and `%TEMP%\nvsigner_test_*` (removed automatically after each run) |
| Windows driver store (only during the optional pnputil test) | One package is added and removed again right after |

**Network:** the tool connects to `api.nuget.org` to download Microsoft tool packages and, only if you use the generate-cat-file engine, to `github.com` to download its source code. It has no telemetry and sends no data about you or your files.

## Troubleshooting

- **"WSL is not available" / "missing tool inside WSL":** install WSL (`wsl --install`) and in the distribution run `sudo apt install build-essential`, or pick another engine.
- **"Windows can't verify the publisher of this driver software" opens during the pnputil test or when you install:** Windows found at least one file whose hash is not in the catalog (`setupapi.dev.log`: *Failed to verify file ... Catalog did not contain file hash ... Driver package appears to be tampered*). The certificate itself is fine (the same log says *The INF was signed with an Authenticode(tm) catalog from a trusted publisher*). Use the **all files** scope; if it still happens, the report names the file and says whether it is in the package. Typical causes: a file that the INF names but that is not in the folder (restore it from the original NVIDIA package), or a file that is stored compressed (see the next point). Do not click *Install anyway* for a package you are testing.
- **A file named in the INF shows up as "missing" but exists as `name.dl_` / `name.sy_` / `name.ex_`:** it is stored compressed. The INF names the expanded file (for example `nvngx_dlssd.dll`) and Windows setup finds the compressed one by itself. Up to v2.2.0 the tool treated such a file as missing and left it out of the catalog. v2.2.1 hashed the compressed file under the INF name, which Windows still did not find (*Catalog did not contain file hash*): Windows checks the **expanded** file. Since v2.2.2 the tool expands it with `expand.exe` into the temporary stage folder and hashes that, under the name the INF uses (the compressed file is also a member under its own name). The scan and the member summary say how many files are stored compressed.
- **An experimental engine is `REJECTED` by pnputil, or `signtool verify` fails:** Windows does not accept that catalog layout for your files. Use the Inf2Cat engine (try it with *Target only this PC's Windows version* on).
- **pnputil says "The system cannot find the file specified" (0x00000002):** Windows could not find a file it needed while importing the package. Read the `setupapi.dev.log` lines the test prints: they should name the file. The scan step of the test lists files named in `[SourceDisksFiles]` that are not in the folder (NVCleanstall removes components) and says whether the INF also copies them. If it does, no catalog can contain a hash for that file, so Windows may refuse the package whatever the engine is; restore the file from the original NVIDIA package. If it does not, the missing file is harmless.
- **A step has been running for many minutes:** Inf2Cat uses one core per process (about 8 % of a 12-thread CPU) and several GB of RAM for the "INF + files" scope; the log prints "still running" every 60 s and Task Manager's *Analyze wait chain* shows "running normally". Press **Stop step** to skip it; in the engine test the next combination starts.
- **Inf2Cat failed:** the INF lists files that are not in the folder (often removed by NVCleanstall). The log shows the missing file.
- **Signature status is not `Valid`:** make sure *Trust certificate on this PC* is enabled.
- **No .inf contains the device ID:** check the ID in Device Manager > your GPU > Details > Hardware Ids.
- **Using the driver on another PC:** import the exported `.cer` into *Trusted Root Certification Authorities* and *Trusted Publishers* there first, and turn off "Target only this PC's Windows version".
- **`setup.exe` says "Required files are missing":** you used "Keep only my GPU INF". Restore the files from `<folder>_removed_INF_backup` or regenerate the driver folder.

## Security notes and how to undo everything

- The certificate is self-signed. When you enable *Trust certificate*, **anything signed with that certificate is trusted by this PC**. The private key stays in the LocalMachine store of your PC; anyone with administrator access to it could use the key. Do not export or share the private key.
- Only trust the certificate on machines you control, and remove it when you no longer need it.
- Self-signing does **not** bypass Secure Boot, kernel-mode code signing, or Memory Integrity (HVCI). The NVIDIA binaries keep their original signatures.

To remove the certificate (run in an administrator PowerShell):

```powershell
Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher, Cert:\LocalMachine\My |
  Where-Object { $_.Subject -eq 'CN=NVIDIA Modded Drivers Signer' } | Remove-Item
```

To remove everything else, delete `C:\ProgramData\NvidiaModdedDriversSigner`. To remove an installed driver package, use `pnputil /enum-drivers` and `pnputil /delete-driver oemXX.inf /uninstall`.

## Disclaimer and legal notices

*This section is general information, not legal advice.*

**No warranty / use at your own risk.** This software is provided "as is", without warranty of any kind. Modifying, re-signing, and installing drivers can cause system instability, crashes (BSOD), data loss, or unusable displays, and may affect your hardware warranty or vendor support. The author is not liable for any damage, loss, or consequences arising from the use of this tool (see the [LICENSE](LICENSE)). Back up your data and create a restore point first.

**No affiliation / trademarks.** This is an independent, unofficial project. It is **not affiliated with, endorsed by, or sponsored by** NVIDIA Corporation, Microsoft Corporation, or TechPowerUp (NVCleanstall). NVIDIA, GeForce, RTX, Windows, and other product names are trademarks of their respective owners and are used here only to describe compatibility.

**No driver files are distributed.** This repository contains only the signing tool and documentation. It does **not** include, and you must not upload to its issues or releases, NVIDIA drivers, NVCleanstall packages, modified drivers, certificates, or private keys. Obtain the driver yourself from official sources.

**Third-party software.** The tool downloads Microsoft's Inf2Cat, MakeCat and SignTool from the official NuGet packages `Microsoft.Windows.WDK.x64` and `Microsoft.Windows.SDK.BuildTools` on nuget.org. These tools are **not** redistributed in this repository; they are downloaded to your PC and are subject to Microsoft's own license terms (Windows Driver Kit / Windows SDK). If you choose the generate-cat-file engine, its source code (LINBIT/generate-cat-file, GPL-2.0) is downloaded from GitHub at a pinned commit and compiled on your own machine inside WSL; it is not redistributed here and keeps its own license. The *libwdi-style* engine is an independent implementation of the catalog-building approach used by the LGPL-licensed libwdi project; it contains no libwdi code. NVCleanstall is a separate product by TechPowerUp and is not included.

**Your responsibility.** You are responsible for making sure your use is lawful and complies with the licenses and terms that apply to the software you handle, including the NVIDIA driver license agreement (EULA) and the terms of NVCleanstall and Windows. Use this tool only on hardware and software you own or are authorized to modify, for personal use. The tool is intended for compatibility and personal customization; it does not remove licensing checks, activate software, or circumvent copy protection, and must not be used for malicious purposes or to distribute unsigned or tampered software.

**Contributions.** By contributing, you confirm that you have the right to submit your contribution under the project's license.

## Version

Current version: **v2.2.2** (the version is part of the file name). See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). The license applies only to the code and documentation in this repository, not to third-party software mentioned above.
