# NVIDIA Modded Drivers Signer

A single-file GUI (`.cmd`) that re-signs the modified `.inf` of **NVCleanstall-modded NVIDIA drivers**, so the package installs cleanly again, keeping **only the INF that contains your GPU** to make the process faster.

No installation required: everything the tool needs is downloaded automatically.

## Why?

NVCleanstall (and manual edits, e.g. adding a laptop GPU hardware ID) change `nv_dispi.inf`. That invalidates the original catalog (`.cat`), so Windows treats the package as unsigned. This tool rebuilds the catalog and signs it with a local self-signed certificate that it also trusts on your PC.

## Features

- Dark, simple GUI (batch + PowerShell WinForms, one `.cmd` file)
- Detects your NVIDIA GPU (`VEN_10DE&DEV_xxxx`) or lets you type the device ID
- Finds the `.inf` that contains your GPU and can delete all the other `.inf` / `.cat` files (faster, smaller package)
- Downloads **Inf2Cat** automatically (WDK NuGet package, only once)
- Creates a self-signed code-signing certificate (10 years) and trusts it in *Trusted Root* and *Trusted Publishers*
- Generates a new `.cat` with Inf2Cat and signs it (PowerShell `Set-AuthenticodeSignature`, falls back to `signtool` downloaded automatically)
- **Sign ALL INF packages** mode: runs several Inf2Cat jobs in parallel (configurable, 1-8) and signs every new `.cat` in a single call
- Drag and drop a folder onto the path box
- Exports the certificate as `.cer` so you can trust it on other PCs
- Live log, **elapsed timer, percentage and estimated time remaining (ETA)**; the estimate learns from your previous runs

## Requirements

- Windows 10 / 11 x64
- Windows PowerShell 5.1 (included in Windows)
- Administrator rights (the tool asks for UAC on start)
- Internet connection on first run (Inf2Cat download, a large package that is cached afterwards)

## Usage

1. Download `nvidia modded drivers signer (v1.2.0).cmd`.
2. Double-click it and accept the UAC prompt.
3. Select (or drop) the extracted modded driver folder, the one NVCleanstall produced, containing `Display.Driver\nv_dispi.inf`.
4. Press **Detect GPU** (or type your device ID, for example `DEV_2518`).
5. Choose your options and press **SIGN DRIVER**.
6. Install the signed driver, for example:

```
pnputil /add-driver "C:\path\to\Display.Driver\nv_dispi.inf" /install
```

### Options

| Option | Default | What it does |
|---|---|---|
| Keep only my GPU INF | On | Deletes every other `.inf` and its `.cat` in the folder. Irreversible, a confirmation is shown first. |
| Trust certificate on this PC | On | Adds the certificate to the LocalMachine *Root* and *TrustedPublisher* stores. |
| Sign ALL INF packages (parallel) | Off | Signs every INF package found in the folder instead of only your GPU INF. Disables "Keep only my GPU INF" and does not need a GPU device ID. |
| Parallel jobs | min(4, CPU cores) | How many Inf2Cat processes run at the same time. Only helps when there are several packages; set it to 1 if you ever see odd Inf2Cat errors. |

> With "Keep only my GPU INF" there is normally a single package, so there is nothing to parallelize: the time is dominated by Inf2Cat hashing the driver files.

## Where things are stored

| Item | Location |
|---|---|
| Downloaded tools (Inf2Cat, optional signtool) | `C:\ProgramData\NvidiaModdedDriversSigner\tools` |
| Learned Inf2Cat speed (for the ETA) | `C:\ProgramData\NvidiaModdedDriversSigner\stats.json` |
| Exported certificate | `C:\ProgramData\NvidiaModdedDriversSigner\NvidiaModdedDriversSigner.cer` |
| Signing certificate (private key) | `Cert:\LocalMachine\My`, subject `CN=NVIDIA Modded Drivers Signer` |

## Troubleshooting

- **Inf2Cat failed**: the INF lists files that are not in the folder (often removed by NVCleanstall). The log shows the missing file.
- **Signature status is not `Valid`**: make sure *Trust certificate on this PC* is enabled.
- **No .inf contains the device ID**: check the ID in Device Manager > your GPU > Details > Hardware Ids.
- **Using the driver on another PC**: import the exported `.cer` into *Trusted Root Certification Authorities* and *Trusted Publishers* there first.

## Security notes

- The certificate is self-signed and only trusted on machines where you install it. Remove it from the *Root* and *TrustedPublisher* stores if you stop using the tool.
- Only the catalog is re-signed. The original NVIDIA binaries are not modified.
- Use at your own risk. This project is not affiliated with NVIDIA or NVCleanstall.

## Version

Current version: **v1.2.0** (the version is part of the file name). See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
