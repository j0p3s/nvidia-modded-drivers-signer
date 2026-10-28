# NVIDIA Modded Drivers Signer

A single-file GUI (`.cmd`) that re-signs the modified `.inf` files of **NVCleanstall-modded NVIDIA drivers** that you already have on your own PC, so the package can be installed again. It focuses on **the INF files that contain your GPU** to keep the process fast.

No installation required: the tool downloads what it needs (Microsoft's Inf2Cat) automatically.

> **Important:** please read the [Disclaimer and legal notices](#disclaimer-and-legal-notices) before using this tool.

## Table of contents

- [Why?](#why)
- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
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
- **Fast mode:** each GPU INF gets its own catalog (`<name>_nvsigner.cat`) and Inf2Cat runs once per INF, in parallel, in tiny temporary packages (the multi-GB driver folder is not hashed)
- Option to target only the Windows version running on this PC (much faster)
- Downloads **Inf2Cat** automatically (Windows Driver Kit NuGet package from nuget.org, only once)
- Creates a self-signed code-signing certificate (10 years) and can trust it in *Trusted Root* and *Trusted Publishers*
- Signs the catalogs (PowerShell `Set-AuthenticodeSignature`, falls back to `signtool`, also downloaded automatically)
- **Sign ALL INF packages** mode for several packages at once
- Drag and drop a folder onto the path box
- Exports the certificate as `.cer`
- Live log, elapsed timer, percentage and estimated time remaining (ETA); the estimate learns from previous runs

## Requirements

- Windows 10 / 11 x64
- Windows PowerShell 5.1 (included in Windows)
- Administrator rights (the tool asks for UAC on start)
- Internet connection on first run (Inf2Cat download, a large package that is cached afterwards)
- A driver package that **you** legitimately obtained and are allowed to modify and use (see the legal notices)

## Usage

> **Want to run the NVIDIA `setup.exe`?** Leave "Keep only my GPU INF" **off**. The installer needs every INF/CAT of the package and shows "Required files are missing" otherwise.

1. Download `nvidia modded drivers signer (v1.5.0).cmd`.
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
| Fast: own catalog per GPU INF, in parallel | On | Each INF that contains your GPU is copied into its own tiny temp package, its `CatalogFile=` line is pointed to a new unique catalog (`<name>_nvsigner.cat`), and one Inf2Cat runs per INF in parallel. The original shared catalog (for example `nv_dispi.cat`) is not touched. The original INFs are backed up first (see below). If an INF needs other driver files, it falls back to the full folder (slower). |
| Target only this PC's Windows version | On | Inf2Cat checks each INF once per target OS. Using only the Windows version running on this PC makes it much faster. Turn it off if you will install the driver on other Windows versions. |
| Keep only my GPU INF | Off | Moves every other `.inf` and its `.cat` to `<folder>_removed_INF_backup` (nothing is deleted). **The NVIDIA `setup.exe` will not work afterwards**; install with `pnputil` / Device Manager instead. |
| Trust certificate on this PC | On | Adds the certificate to the LocalMachine *Root* and *TrustedPublisher* stores. See the security notes. |
| Sign ALL INF packages (parallel) | Off | Signs every INF package found in the folder instead of only your GPU INFs. Slower. Disables "Fast" and "Keep only my GPU INF" and does not need a GPU device ID. |
| Parallel jobs | min(8, CPU cores) | How many Inf2Cat processes run at the same time. Set it to 1 if you ever see odd Inf2Cat errors. |

## What the tool changes on your PC

| Item | Location / effect |
|---|---|
| Driver folder you select | In Fast mode the GPU INFs get a changed `CatalogFile=` line and a new `<name>_nvsigner.cat` file is added. Original INFs are backed up first. No NVIDIA binaries (`.sys`, `.dll`, `.exe`) are modified. |
| INF backups | `C:\ProgramData\NvidiaModdedDriversSigner\inf_backup\<date>` |
| Downloaded tools (Inf2Cat, optional signtool) | `C:\ProgramData\NvidiaModdedDriversSigner\tools` |
| Learned Inf2Cat speed (for the ETA) | `C:\ProgramData\NvidiaModdedDriversSigner\stats.json` |
| Exported certificate | `C:\ProgramData\NvidiaModdedDriversSigner\NvidiaModdedDriversSigner.cer` |
| Signing certificate (with private key) | `Cert:\LocalMachine\My`, subject `CN=NVIDIA Modded Drivers Signer` |
| Trusted certificate (if enabled) | `Cert:\LocalMachine\Root` and `Cert:\LocalMachine\TrustedPublisher` |
| Temporary files | `%TEMP%\nvsigner_stage_*` (removed automatically after each run) |

**Network:** the tool only connects to `api.nuget.org` to download Microsoft tool packages. It has no telemetry and sends no data about you or your files.

## Troubleshooting

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

**Third-party software.** The tool downloads Microsoft's Inf2Cat (and, if needed, SignTool) from the official NuGet packages `Microsoft.Windows.WDK.x64` and `Microsoft.Windows.SDK.BuildTools` on nuget.org. These tools are **not** redistributed in this repository; they are downloaded to your PC and are subject to Microsoft's own license terms (Windows Driver Kit / Windows SDK). NVCleanstall is a separate product by TechPowerUp and is not included.

**Your responsibility.** You are responsible for making sure your use is lawful and complies with the licenses and terms that apply to the software you handle, including the NVIDIA driver license agreement (EULA) and the terms of NVCleanstall and Windows. Use this tool only on hardware and software you own or are authorized to modify, for personal use. The tool is intended for compatibility and personal customization; it does not remove licensing checks, activate software, or circumvent copy protection, and must not be used for malicious purposes or to distribute unsigned or tampered software.

**Contributions.** By contributing, you confirm that you have the right to submit your contribution under the project's license.

## Version

Current version: **v1.5.0** (the version is part of the file name). See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). The license applies only to the code and documentation in this repository, not to third-party software mentioned above.
