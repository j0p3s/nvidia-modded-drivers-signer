@echo off
rem NVIDIA Modded Drivers Signer - single-file GUI (batch + PowerShell)
set "SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([ScriptBlock]::Create(([IO.File]::ReadAllText($env:SELF) -split '(?m)^#PS_BEGIN#',2)[1]))"
exit /b
#PS_BEGIN#
# ============================================================================
#  NVIDIA Modded Drivers Signer
#  Re-signs the unsigned/modified .inf of NVCleanstall-modded NVIDIA drivers:
#    1. finds the .inf that contains YOUR GPU (and optionally removes the rest)
#    2. downloads Inf2Cat (WDK NuGet package) automatically
#    3. creates a new .cat catalog for the INF(s) (engines: MakeCat, libwdi-style
#       native CryptCAT, generate-cat-file via WSL, Inf2Cat); the experimental
#       engines build ONE shared catalog per driver folder
#    4. signs the .cat with a local self-signed certificate and trusts it
# ============================================================================
$ErrorActionPreference = 'Stop'
$global:AppVersion  = '2.2.2'
$global:AppName     = 'NVIDIA Modded Drivers Signer'
$global:CertSubject = 'CN=NVIDIA Modded Drivers Signer'
$global:WorkDir     = Join-Path $env:ProgramData 'NvidiaModdedDriversSigner'
$global:ToolsDir    = Join-Path $global:WorkDir 'tools'
$global:UA          = 'NvidiaModdedDriversSigner/' + $global:AppVersion
$global:StopRequested = $false

# --- hide the console window ------------------------------------------------
try {
    Add-Type -Namespace NvSigner -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);'
    [void][NvSigner.Native]::ShowWindow([NvSigner.Native]::GetConsoleWindow(), 0)
} catch {}

# --- need admin (certificate store + driver files) --------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try { Start-Process -FilePath $env:SELF -Verb RunAs } catch {}
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $global:ToolsDir | Out-Null

# ============================================================================
#  Helpers
# ============================================================================
function global:Do-Events { [System.Windows.Forms.Application]::DoEvents() }

function global:Write-UiLog($msg) {
    $global:tbLog.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $msg))
    Do-Events
}

function global:Set-Status($msg) { $global:lblStatus.Text = $msg; Do-Events }

function global:Set-Marquee($on) {
    if ($on) { $global:pb.Style = 'Marquee'; $global:pb.MarqueeAnimationSpeed = 30 }
    else     { $global:pb.Style = 'Continuous'; $global:pb.Value = 0 }
    Do-Events
}

function global:Set-Busy($busy) {
    foreach ($c in @($global:btnStart, $global:btnBrowse, $global:btnDetect, $global:btnTools, $global:tbDir, $global:cbGpu, $global:chkKeep, $global:chkTrust, $global:chkAll, $global:nudJobs, $global:chkFast, $global:chkOS, $global:cbEngine, $global:chkFiles, $global:btnTest)) { $c.Enabled = (-not $busy) }
    if (-not $busy -and $global:chkAll.Checked) { $global:chkKeep.Enabled = $false; $global:chkFast.Enabled = $false }
    if ($busy) { $global:StopRequested = $false }
    if ($global:btnStop) { $global:btnStop.Enabled = $busy }
    if ($busy) { $global:pb.Style = 'Continuous'; $global:pb.Value = 0 }
    if (-not $busy) { Set-Status 'Ready.' }
}

# ---------------------------------------------------------------------------
#  Progress plan: every phase has an expected duration (seconds) and a
#  completed fraction. Percentage and ETA are computed from those.
# ---------------------------------------------------------------------------
function global:Format-Span($sec) {
    $t = [TimeSpan]::FromSeconds([Math]::Max(0, [int]$sec))
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds)
}

function global:Test-PlanKey($k) {
    return (($null -ne $global:PlanExp) -and $global:PlanExp.ContainsKey($k) -and ([double]$global:PlanExp[$k] -gt 0))
}

function global:Start-Plan($exp) {
    $global:PlanExp = @{}
    $global:PlanFrac = @{}
    foreach ($k in $exp.Keys) { $global:PlanExp[$k] = [double]$exp[$k]; $global:PlanFrac[$k] = 0.0 }
    $global:InfRunning = $false; $global:InfDone = 0; $global:InfTotal = 1
    $global:PlanOk = $false
    $global:Sw = [Diagnostics.Stopwatch]::StartNew()
    $global:uiTimer.Start()
    Update-Progress
}

function global:Set-PhaseDone($k) {
    if ($null -ne $global:PlanFrac -and $global:PlanFrac.ContainsKey($k)) { $global:PlanFrac[$k] = 1.0 }
    Update-Progress
}

function global:Update-Progress {
    if (($null -eq $global:PlanExp) -or ($null -eq $global:Sw)) { return }
    if ($global:InfRunning -and $global:PlanExp.ContainsKey('inf2cat')) {
        $el = ((Get-Date) - $global:InfStart).TotalSeconds
        $exp = [double]$global:PlanExp['inf2cat']
        if ($el -gt (0.9 * $exp)) { $exp = $el / 0.9; $global:PlanExp['inf2cat'] = $exp }
        $tf = [Math]::Min(0.95, $el / $exp)
        $cf = 0.0
        if ($global:InfTotal -gt 1) { $cf = $global:InfDone / $global:InfTotal }
        $global:PlanFrac['inf2cat'] = [Math]::Max($tf, $cf)
    }
    $total = 0.0; $done = 0.0
    foreach ($k in @($global:PlanExp.Keys)) {
        $e = [double]$global:PlanExp[$k]
        $total += $e
        $done += $e * [double]$global:PlanFrac[$k]
    }
    $pct = 0.0
    if ($total -gt 0) { $pct = 100.0 * $done / $total }
    $pct = [Math]::Min(100.0, $pct)
    $elapsed = $global:Sw.Elapsed.TotalSeconds
    if ($global:Sw.IsRunning) {
        if ($elapsed -lt 4) { $eta = 'estimating...' } else { $eta = '~' + (Format-Span ([Math]::Max(0.0, $total - $done))) }
        $global:lblTimer.Text = ('Elapsed {0}   ETA {1}   {2}%' -f (Format-Span $elapsed), $eta, [int]$pct)
    }
    $global:pb.Value = [int]$pct
}

function global:End-Plan {
    if ($null -eq $global:Sw) { return }
    $global:InfRunning = $false
    $global:Sw.Stop()
    $global:uiTimer.Stop()
    if ($global:PlanOk) {
        $global:pb.Value = 100
        $global:lblTimer.Text = ('Finished in {0}' -f (Format-Span $global:Sw.Elapsed.TotalSeconds))
    } else {
        $global:lblTimer.Text = ('Stopped after {0}' -f (Format-Span $global:Sw.Elapsed.TotalSeconds))
    }
}

# Speeds learned from previous runs (stats.json), used for the ETA
function global:Get-StatSpeed($key, $default) {
    $f = Join-Path $global:WorkDir 'stats.json'
    try {
        if (Test-Path -LiteralPath $f) {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            $v = $j.$key
            if (($null -ne $v) -and ([double]$v -gt 0)) { return [double]$v }
        }
    } catch {}
    return [double]$default
}
function global:Save-StatSpeed($key, $val) {
    $f = Join-Path $global:WorkDir 'stats.json'
    $h = @{}
    try {
        if (Test-Path -LiteralPath $f) {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
        }
    } catch {}
    $new = [double]$val
    if ($h.ContainsKey($key)) { $new = 0.5 * [double]$h[$key] + 0.5 * $new }
    $h[$key] = [Math]::Round([Math]::Max(0.05, [Math]::Min(500.0, $new)), 2)
    try { ($h | ConvertTo-Json) | Set-Content -LiteralPath $f -Encoding ASCII } catch {}
}

# Copies an INF and points its CatalogFile= directive to $newCat (encoding preserved)
function global:Set-InfCatalogName($src, $dst, $newCat) {
    $bytes = [IO.File]::ReadAllBytes($src)
    $off = 0
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = New-Object System.Text.UnicodeEncoding($false, $true); $off = 2
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = New-Object System.Text.UTF8Encoding($true); $off = 3
    } else {
        $enc = [System.Text.Encoding]::GetEncoding(1252)
    }
    $text = $enc.GetString($bytes, $off, $bytes.Length - $off)
    $rx = '(?im)^(\s*CatalogFile(?:\.[A-Za-z0-9]+)?\s*=\s*)[^\s;]+'
    if ([regex]::IsMatch($text, $rx)) {
        $text = [regex]::Replace($text, $rx, ('${1}' + $newCat))
    } else {
        $re = New-Object System.Text.RegularExpressions.Regex('(?im)^\[Version\]\s*$')
        $text = $re.Replace($text, ("[Version]`r`nCatalogFile=" + $newCat), 1)
    }
    [IO.File]::WriteAllBytes($dst, [byte[]]($enc.GetPreamble() + $enc.GetBytes($text)))
}

# Inf2Cat /os token for the Windows version running on this PC
function global:Get-CurrentOsToken {
    $b = 0
    try { $b = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber } catch {}
    if ($b -ge 26100) { return '10_GE_X64' }
    if ($b -ge 22621) { return '10_NI_X64' }
    if ($b -ge 22000) { return '10_CO_X64' }
    if ($b -ge 19041) { return '10_VB_X64' }
    if ($b -ge 18362) { return '10_19H1_X64' }
    if ($b -ge 17763) { return '10_RS5_X64' }
    return '10_X64'
}

function global:Download-File($url, $dest) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = $global:UA
    $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($dest)
    $t0 = Get-Date
    $lastUi = $t0
    try {
        $buf = New-Object byte[] 262144
        $got = 0L
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $got += $n
            $now = Get-Date
            if (($now - $lastUi).TotalMilliseconds -ge 250) {
                $lastUi = $now
                $dl = ($now - $t0).TotalSeconds
                $speed = 0.0
                if ($dl -gt 0.5) { $speed = $got / $dl }
                if ($total -gt 0 -and $speed -gt 0) {
                    Set-Status ('Downloading... {0:N1} / {1:N1} MB ({2:N1} MB/s)' -f ($got / 1MB), ($total / 1MB), ($speed / 1MB))
                    if ((Test-PlanKey 'tools') -and $got -gt 2MB) {
                        $exp = ($total / $speed) + 10
                        $global:PlanExp['tools'] = $exp
                        $global:PlanFrac['tools'] = [Math]::Min(0.95, $dl / $exp)
                    }
                } else {
                    Set-Status ('Downloading... {0:N1} MB' -f ($got / 1MB))
                }
                Update-Progress
                Do-Events
            }
        }
    } finally {
        $global:LastDlSeconds = ((Get-Date) - $t0).TotalSeconds
        $out.Close(); $in.Close(); $resp.Close()
    }
}

function global:Resolve-NuGetVersion($id, $verRegex) {
    $wc = New-Object Net.WebClient
    $wc.Headers['User-Agent'] = $global:UA
    $json = $wc.DownloadString("https://api.nuget.org/v3-flatcontainer/$($id.ToLower())/index.json") | ConvertFrom-Json
    $ver = $json.versions | Where-Object { $_ -match $verRegex } | Select-Object -Last 1
    if (-not $ver) { $ver = $json.versions | Where-Object { $_ -notmatch '-' } | Select-Object -Last 1 }
    if (-not $ver) { throw "No version found for NuGet package $id" }
    return [string]$ver
}

# Downloads a NuGet package and extracts the whole folder that holds $exe into $dest.
function global:Ensure-Tool($id, $exe, $subdir, $verRegex, $pathHint) {
    $dir = Join-Path $global:ToolsDir $subdir
    $found = Get-ChildItem -Path $dir -Filter $exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }

    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ver = Resolve-NuGetVersion $id $verRegex
    $lid = $id.ToLower(); $lver = $ver.ToLower()
    $url = "https://api.nuget.org/v3-flatcontainer/$lid/$lver/$lid.$lver.nupkg"
    $pkg = Join-Path $global:ToolsDir "$lid.$lver.nupkg"
    Write-UiLog "Downloading $id $ver (large package, only needed once)..."
    Download-File $url $pkg
    Write-UiLog "Extracting $exe ..."
    Set-Status 'Extracting...'
    $dlSec = [double]$global:LastDlSeconds
    if (Test-PlanKey 'tools') { $global:PlanExp['tools'] = $dlSec + 10 }
    $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
    try {
        $cands = @($zip.Entries | Where-Object { $_.Name -ieq $exe })
        $e = $cands | Where-Object { $_.FullName -match $pathHint } | Select-Object -First 1
        if (-not $e) { $e = $cands | Select-Object -First 1 }
        if (-not $e) { throw "$exe not found inside $id package" }
        $prefix = $e.FullName.Substring(0, $e.FullName.Length - $e.Name.Length)
        $nEnt = [Math]::Max(1, $zip.Entries.Count); $iEnt = 0
        foreach ($x in $zip.Entries) {
            $iEnt++
            if (($iEnt % 200) -eq 0 -and (Test-PlanKey 'tools')) {
                $global:PlanFrac['tools'] = [Math]::Min(0.99, ($dlSec + 10 * $iEnt / $nEnt) / ($dlSec + 10))
                Update-Progress
            }
            if ($x.Name -ne '' -and $x.FullName.StartsWith($prefix) -and $x.FullName.IndexOf('/', $prefix.Length) -lt 0) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($x, (Join-Path $dir $x.Name), $true)
            }
            Do-Events
        }
    } finally { $zip.Dispose() }
    Remove-Item -LiteralPath $pkg -Force -ErrorAction SilentlyContinue
    $found = Get-ChildItem -Path $dir -Filter $exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw "Could not extract $exe" }
    Write-UiLog "$exe ready."
    return $found.FullName
}

function global:Get-ToolsState {
    $f = Get-ChildItem -Path (Join-Path $global:ToolsDir 'wdk') -Filter 'Inf2Cat.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $global:lblTools.Text = 'Tools: Inf2Cat ready'; $global:lblTools.ForeColor = [Drawing.Color]::FromArgb(118,185,0) }
    else    { $global:lblTools.Text = 'Tools: not downloaded yet (downloaded automatically on first run)'; $global:lblTools.ForeColor = [Drawing.Color]::FromArgb(230,180,60) }
}

function global:Invoke-Tool($exe, $argString) {
    $log = Join-Path $env:TEMP ('nvsigner_' + [guid]::NewGuid().ToString('N') + '.log')
    $cmdline = '/c ""{0}" {1} > "{2}" 2>&1"' -f $exe, $argString, $log
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdline -WindowStyle Hidden -PassThru
    while (-not $p.HasExited) { Do-Events; Start-Sleep -Milliseconds 100 }
    $p.WaitForExit()
    $out = ''
    if (Test-Path -LiteralPath $log) {
        $raw = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
        if ($raw) { $out = $raw }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $out }
}

# Finds a tool from the Windows SDK/WDK: our tools folder first, then an installed Windows Kit
function global:Find-KitTool($exe, $subdirs) {
    foreach ($sd in $subdirs) {
        $f = Get-ChildItem -Path (Join-Path $global:ToolsDir $sd) -Filter $exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    foreach ($base in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")) {
        if (Test-Path -LiteralPath $base) {
            $f = Get-ChildItem -Path $base -Recurse -Filter $exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
            if ($f) { return $f.FullName }
        }
    }
    return $null
}

# MakeCat: installed Windows Kit, our tools folder, SDK BuildTools package, WDK package (in this order)
function global:Ensure-MakeCat {
    $m = Find-KitTool 'makecat.exe' @('signtool', 'makecat-wdk')
    if ($m) { Write-UiLog "MakeCat found: $m"; return $m }
    try {
        return (Ensure-Tool 'Microsoft.Windows.SDK.BuildTools' 'makecat.exe' 'signtool' '^10\.0\.26100\.\d+$' '/x64/')
    } catch { Write-UiLog ('makecat.exe is not in the SDK BuildTools package: ' + $_.Exception.Message) }
    try {
        return (Ensure-Tool 'Microsoft.Windows.WDK.x64' 'makecat.exe' 'makecat-wdk' '^10\.0\.26100\.\d+$' '/x64/')
    } catch { Write-UiLog ('makecat.exe is not in the WDK package either: ' + $_.Exception.Message) }
    throw 'makecat.exe could not be found or downloaded. Install the Windows SDK (Signing Tools) or use the Inf2Cat engine.'
}

$global:NativeCatSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace NvSigner
{
    // Catalog builder that follows libwdi (pki.c): native CryptCAT* API from wintrust.dll,
    // SHA1 member hashes, SPC_PE_IMAGE_DATA for PE files, SPC_LINK (CAB data) for INF/flat files.
    public static class NativeCat
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BLOB { public uint cbData; public IntPtr pbData; }

        [StructLayout(LayoutKind.Sequential)]
        struct SIP_INDIRECT_DATA
        {
            public IntPtr DataObjId;
            public BLOB DataValue;
            public IntPtr AlgObjId;
            public BLOB AlgParams;
            public BLOB Digest;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct PE_IMAGE_DATA
        {
            public uint FlagsCb;
            public IntPtr FlagsPb;
            public uint FlagsUnused;
            public IntPtr pFile;
        }

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CryptAcquireContextW(out IntPtr phProv, string pszContainer, string pszProvider, uint dwProvType, uint dwFlags);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern bool CryptReleaseContext(IntPtr hProv, uint dwFlags);

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATOpen(string pwszFileName, uint fdwOpenFlags, IntPtr hProv, uint dwPublicVersion, uint dwEncodingType);

        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATClose(IntPtr hCatalog);

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutCatAttrInfo(IntPtr hCatalog, string pwszReferenceTag, uint dwAttrTypeAndAction, uint cbData, byte[] pbData);

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutMemberInfo(IntPtr hCatalog, string pwszFileName, string pwszReferenceTag, ref Guid pgSubjectType, uint dwCertVersion, uint cbSIPIndirectData, IntPtr pbSIPIndirectData);

        [DllImport("wintrust.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CryptCATPutAttrInfo(IntPtr hCatalog, IntPtr pCatMember, string pwszReferenceTag, uint dwAttrTypeAndAction, uint cbData, byte[] pbData);

        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATPersistStore(IntPtr hCatalog);

        [DllImport("wintrust.dll", SetLastError = true)]
        static extern bool CryptCATAdminCalcHashFromFileHandle(IntPtr hFile, ref uint pcbHash, byte[] pbHash, uint dwFlags);

        [DllImport("crypt32.dll", SetLastError = true)]
        static extern bool CryptEncodeObject(uint dwCertEncodingType, [MarshalAs(UnmanagedType.LPStr)] string lpszStructType, IntPtr pvStructInfo, byte[] pbEncoded, ref uint pcbEncoded);

        const uint X509_ASN_ENCODING = 1;
        const uint CRYPTCAT_OPEN_CREATENEW = 1;
        const uint CATATTR = 0x10000000 | 0x1 | 0x10000;   // AUTHENTICATED | NAMEASCII | DATAASCII
        const uint PROV_RSA_FULL = 1;
        const uint CRYPT_VERIFYCONTEXT = 0xF0000000;
        const string OID_PE = "1.3.6.1.4.1.311.2.1.15";
        const string OID_CAB = "1.3.6.1.4.1.311.2.1.25";
        const string OID_SHA1 = "1.3.14.3.2.26";

        static readonly Guid FLAT_GUID = new Guid("DE351A42-8E59-11D0-8C47-00C04FC295EE");
        static readonly Guid PE_GUID = new Guid("C689AAB8-8E78-11D0-8C47-00C04FC295EE");

        public static bool IsPE(string path)
        {
            try
            {
                using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    byte[] b = new byte[64];
                    if (f.Read(b, 0, 64) < 64) return false;
                    if (b[0] != 0x4D || b[1] != 0x5A) return false;
                    int off = BitConverter.ToInt32(b, 60);
                    if (off < 0 || off > f.Length - 4) return false;
                    f.Seek(off, SeekOrigin.Begin);
                    byte[] s = new byte[4];
                    if (f.Read(s, 0, 4) < 4) return false;
                    return s[0] == 0x50 && s[1] == 0x45 && s[2] == 0 && s[3] == 0;
                }
            }
            catch (Exception)
            {
                return false;
            }
        }

        static byte[] UniZ(string s)
        {
            return Encoding.Unicode.GetBytes(s + "\0");
        }

        public static string Create(string catPath, string hwid, string osString, string osAttr, string[] names, string[] paths, CatJob job)
        {
            IntPtr hProv = IntPtr.Zero;
            IntPtr hCat = IntPtr.Zero;
            try
            {
                if (File.Exists(catPath)) File.Delete(catPath);
                if (!CryptAcquireContextW(out hProv, null, null, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT))
                    return "CryptAcquireContext failed, Win32 error " + Marshal.GetLastWin32Error();
                hCat = CryptCATOpen(catPath, CRYPTCAT_OPEN_CREATENEW, hProv, 0, 0);
                if (hCat == IntPtr.Zero || hCat == new IntPtr(-1))
                {
                    int e = Marshal.GetLastWin32Error();
                    hCat = IntPtr.Zero;
                    return "CryptCATOpen failed, Win32 error " + e;
                }
                byte[] b;
                if (!String.IsNullOrEmpty(hwid))
                {
                    b = UniZ(hwid);
                    if (CryptCATPutCatAttrInfo(hCat, "HWID1", CATATTR, (uint)b.Length, b) == IntPtr.Zero)
                        return "Setting HWID1 failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                if (!String.IsNullOrEmpty(osString))
                {
                    b = UniZ(osString);
                    if (CryptCATPutCatAttrInfo(hCat, "OS", CATATTR, (uint)b.Length, b) == IntPtr.Zero)
                        return "Setting OS failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                for (int i = 0; i < names.Length; i++)
                {
                    string err = AddMember(hCat, names[i], paths[i], osAttr);
                    if (err != null) return names[i] + ": " + err;
                    if (job != null) job.Processed = i + 1;
                }
                if (!CryptCATPersistStore(hCat))
                    return "CryptCATPersistStore failed, Win32 error " + Marshal.GetLastWin32Error();
                return "";
            }
            finally
            {
                if (hCat != IntPtr.Zero) CryptCATClose(hCat);
                if (hProv != IntPtr.Zero) CryptReleaseContext(hProv, 0);
            }
        }

        static string AddMember(IntPtr hCat, string name, string path, string osAttr)
        {
            byte[] hash = new byte[20];
            uint cb = 20;
            bool pe = IsPE(path);
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                if (!CryptCATAdminCalcHashFromFileHandle(fs.SafeFileHandle.DangerousGetHandle(), ref cb, hash, 0))
                    return "hashing failed, Win32 error " + Marshal.GetLastWin32Error();
            }
            string hex = BitConverter.ToString(hash).Replace("-", "");

            IntPtr pLinkStr = IntPtr.Zero, pLink = IntPtr.Zero, pFlags = IntPtr.Zero, pImg = IntPtr.Zero;
            IntPtr pEnc = IntPtr.Zero, pOidData = IntPtr.Zero, pOidAlg = IntPtr.Zero, pDigest = IntPtr.Zero, pSip = IntPtr.Zero;
            try
            {
                // SPC_LINK { DWORD dwLinkChoice; union { LPWSTR pwszFile; ... } } - the union starts at pointer alignment
                pLinkStr = Marshal.StringToHGlobalUni("<<<Obsolete>>>");
                pLink = Marshal.AllocHGlobal(64);
                for (int i = 0; i < 64; i += 4) Marshal.WriteInt32(pLink, i, 0);
                Marshal.WriteInt32(pLink, 0, 3);                    // SPC_FILE_LINK_CHOICE
                Marshal.WriteIntPtr(pLink, IntPtr.Size, pLinkStr);  // pwszFile

                byte[] enc = new byte[256];
                uint cbEnc = (uint)enc.Length;
                if (pe)
                {
                    pFlags = Marshal.AllocHGlobal(1);
                    Marshal.WriteByte(pFlags, 0xA0);
                    PE_IMAGE_DATA img = new PE_IMAGE_DATA();
                    img.FlagsCb = 1;
                    img.FlagsPb = pFlags;
                    img.FlagsUnused = 0;
                    img.pFile = pLink;
                    pImg = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(PE_IMAGE_DATA)));
                    Marshal.StructureToPtr(img, pImg, false);
                    if (!CryptEncodeObject(X509_ASN_ENCODING, OID_PE, pImg, enc, ref cbEnc))
                        return "encoding SPC_PE_IMAGE_DATA failed, Win32 error " + Marshal.GetLastWin32Error();
                }
                else
                {
                    if (!CryptEncodeObject(X509_ASN_ENCODING, OID_CAB, pLink, enc, ref cbEnc))
                        return "encoding SPC_LINK failed, Win32 error " + Marshal.GetLastWin32Error();
                }

                pEnc = Marshal.AllocHGlobal((int)cbEnc);
                Marshal.Copy(enc, 0, pEnc, (int)cbEnc);
                pOidData = Marshal.StringToHGlobalAnsi(pe ? OID_PE : OID_CAB);
                pOidAlg = Marshal.StringToHGlobalAnsi(OID_SHA1);
                pDigest = Marshal.AllocHGlobal(20);
                Marshal.Copy(hash, 0, pDigest, 20);

                SIP_INDIRECT_DATA sip = new SIP_INDIRECT_DATA();
                sip.DataObjId = pOidData;
                sip.DataValue.cbData = cbEnc;
                sip.DataValue.pbData = pEnc;
                sip.AlgObjId = pOidAlg;
                sip.AlgParams.cbData = 0;
                sip.AlgParams.pbData = IntPtr.Zero;
                sip.Digest.cbData = 20;
                sip.Digest.pbData = pDigest;
                int sipSize = Marshal.SizeOf(typeof(SIP_INDIRECT_DATA));
                pSip = Marshal.AllocHGlobal(sipSize);
                Marshal.StructureToPtr(sip, pSip, false);

                Guid g = pe ? PE_GUID : FLAT_GUID;
                IntPtr member = CryptCATPutMemberInfo(hCat, null, hex, ref g, 0x200, (uint)sipSize, pSip);
                if (member == IntPtr.Zero)
                    return "CryptCATPutMemberInfo failed, Win32 error " + Marshal.GetLastWin32Error();

                byte[] b1 = UniZ(name.ToLowerInvariant());
                if (CryptCATPutAttrInfo(hCat, member, "File", CATATTR, (uint)b1.Length, b1) == IntPtr.Zero)
                    return "Setting File attribute failed, Win32 error " + Marshal.GetLastWin32Error();
                byte[] b2 = UniZ(osAttr);
                if (CryptCATPutAttrInfo(hCat, member, "OSAttr", CATATTR, (uint)b2.Length, b2) == IntPtr.Zero)
                    return "Setting OSAttr attribute failed, Win32 error " + Marshal.GetLastWin32Error();
                return null;
            }
            finally
            {
                if (pSip != IntPtr.Zero) Marshal.FreeHGlobal(pSip);
                if (pDigest != IntPtr.Zero) Marshal.FreeHGlobal(pDigest);
                if (pOidAlg != IntPtr.Zero) Marshal.FreeHGlobal(pOidAlg);
                if (pOidData != IntPtr.Zero) Marshal.FreeHGlobal(pOidData);
                if (pEnc != IntPtr.Zero) Marshal.FreeHGlobal(pEnc);
                if (pImg != IntPtr.Zero) Marshal.FreeHGlobal(pImg);
                if (pFlags != IntPtr.Zero) Marshal.FreeHGlobal(pFlags);
                if (pLink != IntPtr.Zero) Marshal.FreeHGlobal(pLink);
                if (pLinkStr != IntPtr.Zero) Marshal.FreeHGlobal(pLinkStr);
            }
        }
    }

    // Runs NativeCat.Create on a background thread so the GUI keeps responding.
    public class CatJob
    {
        public volatile bool Done;
        public string Error = "";
        public int Processed;
        public int Total;
        string cat, hwid, os, osAttr;
        string[] names, paths;
        Thread th;

        public CatJob(string cat, string hwid, string os, string osAttr, string[] names, string[] paths)
        {
            this.cat = cat;
            this.hwid = hwid;
            this.os = os;
            this.osAttr = osAttr;
            this.names = names;
            this.paths = paths;
            this.Total = names.Length;
        }

        public void Start()
        {
            th = new Thread(new ThreadStart(Run));
            th.IsBackground = true;
            th.Start();
        }

        void Run()
        {
            try { Error = NativeCat.Create(cat, hwid, os, osAttr, names, paths, this); }
            catch (Exception ex) { Error = ex.GetType().Name + ": " + ex.Message; }
            Done = true;
        }
    }
}
'@

# ---------------------------------------------------------------------------
#  Catalog engines (v1.7.0). Inf2Cat is the standard one; the others are EXPERIMENTAL
#  alternatives that do not parse the INF. Every engine returns result objects with
#  Dir, ExitCode, Output and Secs (same shape as Invoke-Inf2CatParallel).
# ---------------------------------------------------------------------------
$global:EngineIds   = @('makecat', 'libwdi', 'gencat', 'inf2cat')
$global:EngineNames = @('MakeCat', 'libwdi-style (native CryptCAT)', 'generate-cat-file (WSL)', 'Inf2Cat')
$global:OsAttrList  = @('6.0', '6.1', '6.2', '6.3', '6.4', '10.0')
$global:OsAttrNative   = '2:6.0,2:6.1,2:6.2,2:6.3,2:6.4,2:10.0'
$global:OsStringNative = '7_X64,8_X64,10_X64,10_RS5_X64,10_19H1_X64,10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64'
$global:OsAttrGenCat   = '2:6.1,2:6.2,2:6.3,2:6.4,2:10.0'
$global:OsStringGenCat = '7X64,8X64,_v100_X64,_v100_X64_RS5,_v100_X64_19H1,_v100_X64_Vb,_v100_X64_21H2,_v100_X64_22H2,_v100_X64_24H2'
$global:GenCatCommit   = '65ebf4de79a42b0a1104fbef37b1c207ff13e1e9'
$global:GenCatSha256   = @{
    'generate-cat-file.c' = '45afc2c933849e5cb4dfd7eadd2300bac993e721dc8f4ac902eed5808845d607'
    'strip-pe-image.c'    = 'b5fe83eecea5d6ef4b6fb185a79069db9a468bda7e92d34f09e70df9ffccb8da'
    'gencat.sh'           = 'b922bd15f7be71ab07e9329ac593176cb37ee2dddefd0e0050e6eae2296882d1'
    'Makefile'            = '198357b8b2c4ecfd5b463fc2266621a9036c8663071c15819903425f182d7ae3'
}

# Runs "cmd /c <cmdInner> > log 2>&1" hidden, keeps the GUI alive, kills the tree after $timeoutSec.
function global:Invoke-CmdLogged($cmdInner, $workDir, $timeoutSec, $label) {
    $log = Join-Path $env:TEMP ('nvsigner_' + [guid]::NewGuid().ToString('N') + '.log')
    $cmdline = '/c "{0} > "{1}" 2>&1"' -f $cmdInner, $log
    if ($workDir) { $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdline -WorkingDirectory $workDir -WindowStyle Hidden -PassThru }
    else { $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdline -WindowStyle Hidden -PassThru }
    $t = Get-Date
    $beat = Get-Date
    $timedOut = $false
    $stopped = $false
    while (-not $p.HasExited) {
        Do-Events
        Start-Sleep -Milliseconds 100
        $now = Get-Date
        if ($global:StopRequested) {
            $stopped = $true
            try { Start-Process -FilePath 'taskkill.exe' -ArgumentList ('/PID {0} /T /F' -f $p.Id) -WindowStyle Hidden -Wait } catch {}
            break
        }
        if (($now - $t).TotalSeconds -gt $timeoutSec) {
            $timedOut = $true
            try { Start-Process -FilePath 'taskkill.exe' -ArgumentList ('/PID {0} /T /F' -f $p.Id) -WindowStyle Hidden -Wait } catch {}
            break
        }
        # long runs (hashing gigabytes) say they are alive: one log line every 15 s
        if ($label -and (($now - $beat).TotalSeconds -ge 15)) {
            $beat = $now
            $span = Format-Span (($now - $t).TotalSeconds)
            Write-UiLog ('  {0} still running ({1})' -f $label, $span)
            Set-Status ('{0} - running for {1}' -f $label, $span)
        }
    }
    $p.WaitForExit()
    $out = ''
    if (Test-Path -LiteralPath $log) {
        $raw = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
        if ($raw) { $out = ($raw -replace "`0", '') }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    if ($timedOut) { $out += ("`r`n(timed out after {0} s)" -f $timeoutSec) }
    if ($stopped) { $out += "`r`n(stopped by user)" }
    return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; Output = $out; TimedOut = $timedOut; Stopped = $stopped }
}

# Name Windows looks for when a file is stored compressed on the media: the last character of the extension
# becomes "_" (nvngx_dlssd.dll -> nvngx_dlssd.dl_); extensions shorter than 3 characters get "_" appended;
# no extension -> "._". The INF names the EXPANDED file; setup finds the compressed one by itself.
function global:Get-PackedName($leaf) {
    $n = [string]$leaf
    if (-not $n) { return '' }
    $dot = $n.LastIndexOf('.')
    if ($dot -lt 0) { return ($n + '._') }
    if (($n.Length - $dot - 1) -ge 3) { return ($n.Substring(0, $n.Length - 1) + '_') }
    return ($n + '_')
}

# Files listed in the INF's [SourceDisksFiles] sections (generic + x64) that exist next to the INF.
# A file that is only present in compressed form (name.dl_) counts as present: Packed = $true, Path / Rel are
# the compressed file, Name is the name the INF uses (that is the name Windows checks against the catalog).
# Returns objects with Name (leaf), Rel (path relative to the INF folder), Path (full path) and Packed.
function global:Get-InfFiles($infPath) {
    $dir = Split-Path -Parent $infPath
    $self = Split-Path -Leaf $infPath
    $bytes = [IO.File]::ReadAllBytes($infPath)
    $off = 0
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = New-Object System.Text.UnicodeEncoding($false, $true); $off = 2
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $enc = New-Object System.Text.UTF8Encoding($true); $off = 3
    } else {
        $enc = [System.Text.Encoding]::GetEncoding(1252)
    }
    $text = $enc.GetString($bytes, $off, $bytes.Length - $off)
    $secs = [regex]::Matches($text, '(?m)^[ \t]*\[([^\]\r\n]+)\]')
    $splitRx = New-Object System.Text.RegularExpressions.Regex(',(?=(?:[^"]*"[^"]*")*[^"]*$)')
    $disks = @{}
    $entries = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $secs.Count; $i++) {
        $sname = $secs[$i].Groups[1].Value.Trim()
        if ($sname -notmatch '^SourceDisks(Names|Files)(\.(amd64|ntamd64|nt))?$') { continue }
        $isNames = ($sname -match '^SourceDisksNames')
        $start = $secs[$i].Index + $secs[$i].Length
        if (($i + 1) -lt $secs.Count) { $end = $secs[$i + 1].Index } else { $end = $text.Length }
        $body = $text.Substring($start, $end - $start)
        foreach ($line in ($body -split "`r?`n")) {
            $l = $line.Trim()
            if ($l.Length -eq 0 -or $l[0] -eq ';') { continue }
            $eq = $l.IndexOf('=')
            if ($eq -lt 1) { continue }
            $key = $l.Substring(0, $eq).Trim().Trim('"')
            $parts = @($splitRx.Split($l.Substring($eq + 1)))
            for ($k = 0; $k -lt $parts.Count; $k++) {
                $pp = $parts[$k].Trim()
                if ($pp -notmatch '"') { $pp = ($pp -replace '\s*;.*$', '').Trim() }
                $parts[$k] = $pp
            }
            if ($isNames) {
                if ($parts.Count -ge 4) { $disks[$key] = $parts[3].Trim('"').Trim('\') }
            } else {
                $diskId = ''; $sub = ''
                if ($parts.Count -ge 1) { $diskId = $parts[0] }
                if ($parts.Count -ge 2) { $sub = $parts[1].Trim('"').Trim('\') }
                [void]$entries.Add([pscustomobject]@{ File = $key; Disk = $diskId; Sub = $sub })
            }
        }
    }
    $seen = @{}
    $list = New-Object System.Collections.ArrayList
    $missing = New-Object System.Collections.ArrayList
    $dups = New-Object System.Collections.ArrayList
    $packedL = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        $fname = $e.File
        if ($fname -match '[%"*?<>|]') { continue }
        $pre = @()
        if ($disks.ContainsKey($e.Disk) -and $disks[$e.Disk]) { $pre += $disks[$e.Disk] }
        if ($e.Sub) { $pre += $e.Sub }
        if ($pre.Count -gt 0) { $rel = (($pre -join '\') + '\' + $fname) } else { $rel = $fname }
        $rel = $rel.TrimStart('\')
        if ($rel -match '\.\.') { continue }
        $leaf = Split-Path -Leaf $rel
        if ($leaf -ieq $self -or $leaf -match '\.cat$') { continue }
        $full = Join-Path $dir $rel
        $isPacked = $false
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $pn = Get-PackedName $leaf
            $pfull = Join-Path (Split-Path -Parent $full) $pn
            if ($pn -and (Test-Path -LiteralPath $pfull -PathType Leaf)) {
                $isPacked = $true
                $relDir = Split-Path -Parent $rel
                if ($relDir) { $rel = $relDir + '\' + $pn } else { $rel = $pn }
                $full = $pfull
            } else {
                if ($missing -notcontains $rel) { [void]$missing.Add($rel) }
                continue
            }
        }
        $lk = $leaf.ToLower()
        if ($seen.ContainsKey($lk)) {
            if ([string]$seen[$lk] -ine $full) { [void]$dups.Add($rel) }
            continue
        }
        $seen[$lk] = $full
        if ($isPacked) { [void]$packedL.Add($rel) }
        [void]$list.Add([pscustomobject]@{ Name = $leaf; Rel = $rel; Path = $full; Packed = $isPacked })
    }
    # A file that is only named in [SourceDisksFiles] is harmless when absent. One that a copy section also
    # names (anything outside SourceDisks*) is a file Windows wants to check, and no catalog can hold a hash
    # for a file that is not there.
    $used = New-Object System.Collections.ArrayList
    if ($missing.Count -gt 0) {
        $other = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $secs.Count; $i++) {
            if ($secs[$i].Groups[1].Value.Trim() -match '^SourceDisks(Names|Files)') { continue }
            $bs = $secs[$i].Index + $secs[$i].Length
            if (($i + 1) -lt $secs.Count) { $be = $secs[$i + 1].Index } else { $be = $text.Length }
            [void]$other.Append($text.Substring($bs, $be - $bs)).Append("`n")
        }
        $otherText = $other.ToString()
        foreach ($mr in $missing) {
            $ml = [string]$mr
            $cut = $ml.LastIndexOfAny([char[]]@([char]92, [char]47))
            if ($cut -ge 0) { $ml = $ml.Substring($cut + 1) }
            $rx = '(?im)^[^;\r\n]*(?<![A-Za-z0-9_.\-])' + [regex]::Escape($ml) + '(?![A-Za-z0-9_.\-])'
            if ([regex]::IsMatch($otherText, $rx)) { [void]$used.Add($mr) }
        }
    }
    # side channel for the callers that want to report problems (files named in the INF but absent, name clashes)
    $global:InfFilesLast = [pscustomobject]@{ Listed = $entries.Count; Missing = $missing.ToArray(); MissingUsed = $used.ToArray(); Dup = $dups.ToArray(); Packed = $packedL.ToArray() }
    return $list.ToArray()
}

function global:Get-FilesMB($files) {
    $s = 0.0
    foreach ($f in @($files)) { try { $s += (New-Object IO.FileInfo $f.Path).Length } catch {} }
    return ($s / 1MB)
}

# Puts the listed files into a staging folder (NTFS hard links when possible, copies otherwise)
function global:Add-StageFiles($sd, $files) {
    $linked = 0; $copied = 0
    foreach ($f in @($files)) {
        $dst = Join-Path $sd $f.Rel
        $dd = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
        if (Test-Path -LiteralPath $dst) { continue }
        $ok = $false
        try { New-Item -ItemType HardLink -Path $dst -Value $f.Path -ErrorAction Stop | Out-Null; $ok = $true; $linked++ } catch {}
        if (-not $ok) { Copy-Item -LiteralPath $f.Path -Destination $dst -Force; $copied++ }
        Do-Events
    }
    return [pscustomobject]@{ Linked = $linked; Copied = $copied }
}

# Hard-links (or copies) EVERY file of a driver folder into $dst, keeping the sub-folders.
# $skipTop = lower-case names (files directly in the folder) that must NOT be linked because the caller
# puts a different version there (never overwrite a hard link: it would change the original file!).
# Stops at the first file that cannot be linked (other volume / file system) and reports it in Failed.
function global:Add-StageTree($dst, $src, $skipTop) {
    $linked = 0; $failed = 0
    $srcFull = (Resolve-Path -LiteralPath $src).Path.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $srcFull -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($srcFull.Length).TrimStart('\')
        if (($rel.IndexOf('\') -lt 0) -and $skipTop.ContainsKey($rel.ToLower())) { continue }
        $to = Join-Path $dst $rel
        $dd = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
        try { New-Item -ItemType HardLink -Path $to -Value $f.FullName -ErrorAction Stop | Out-Null; $linked++ }
        catch { $failed++; break }
        if (($linked % 40) -eq 0) { Do-Events }
    }
    return [pscustomobject]@{ Linked = $linked; Failed = $failed }
}

# Throw-away package for the pnputil test: the whole driver folder (hard links) + the new INF(s) and the
# shared catalog from the staging folder. Falls back to the files the INF lists (copies) when the folder
# cannot be hard-linked. Returns a short text that says what was built.
function global:New-AcceptPackage($apDir, $realDir, $stageDir, $sm, $listedFiles) {
    New-Item -ItemType Directory -Force -Path $apDir | Out-Null
    $skip = @{}
    foreach ($it in @($sm.Items)) { $skip[([string]$it.Name).ToLower()] = $true }
    $skip[([string]$sm.Cat).ToLower()] = $true
    $r = Add-StageTree $apDir $realDir $skip
    if ($r.Failed -eq 0) {
        $what = ('all {0} file(s) of the driver folder as hard links' -f $r.Linked)
    } else {
        $x = Add-StageFiles $apDir $listedFiles
        $what = ('the {0} file(s) the INF lists ({1} linked, {2} copied; the folder cannot be hard-linked)' -f @($listedFiles).Count, $x.Linked, $x.Copied)
    }
    foreach ($it in @($sm.Items)) { Copy-Item -LiteralPath (Join-Path $stageDir $it.Name) -Destination (Join-Path $apDir $it.Name) -Force }
    Copy-Item -LiteralPath (Join-Path $stageDir $sm.Cat) -Destination (Join-Path $apDir $sm.Cat) -Force
    return $what
}

# One catalog per driver folder: every INF of that folder shares it, so the (multi-GB) files are hashed ONCE.
function global:Get-SharedCatName($dir) {
    $leaf = ((Split-Path -Leaf $dir).ToLower()) -replace '[^a-z0-9._\-]', '_'
    if (-not $leaf) { $leaf = 'driver' }
    return ($leaf + '_nvsigner.cat')
}

# Stages the INF(s) of one folder in a temp folder, each with CatalogFile= pointing to $catName.
# Returns the map entry used by the engines: Dir (real folder), Cat, Hwid, Items (Name + InfPath), Name (label for logs).
function global:New-StageGroup($sd, $realDir, $hitList, $catName, $hwid, $bakDir) {
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $items = New-Object System.Collections.ArrayList
    foreach ($h in @($hitList)) {
        Set-InfCatalogName $h.FullName (Join-Path $sd $h.Name) $catName
        [void]$items.Add(@{ Name = $h.Name; InfPath = $h.FullName })
    }
    $label = [string]$items[0].Name
    if ($items.Count -gt 1) { $label = ('{0} (+{1} more INF)' -f $items[0].Name, ($items.Count - 1)) }
    return @{ Dir = $realDir; Cat = $catName; Hwid = $hwid; Items = $items.ToArray(); Name = $label; InfPath = $items[0].InfPath; BakDir = $bakDir }
}

# Every file under the driver folder except .inf / .cat. Windows verifies every file it copies against the
# catalog, also the ones that [SourceDisksFiles] does not name (whole directories copied by a CopyFiles=@dir
# or "Copy Directory" entry: ngx-builtins, NvCamera, Display.NvContainer\plugins ...).
function global:Get-FolderFiles($dir) {
    $out = New-Object System.Collections.ArrayList
    $full = (Resolve-Path -LiteralPath $dir).Path.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $ext = $f.Extension.ToLower()
        if ($ext -eq '.inf' -or $ext -eq '.cat') { continue }
        [void]$out.Add([pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Rel = $f.FullName.Substring($full.Length).TrimStart('\') })
    }
    return $out.ToArray()
}

# Windows checks a compressed file (name.dl_) as the EXPANDED file: hashing the compressed one under the INF
# name was not found in the catalog (setupapi.dev.log, v2.2.1 test). So the member is the expanded file:
# expand.exe writes it to <stage folder>\_expanded\<INF name>. Returns '' when that fails.
function global:Expand-PackedFile($src, $name, $stageDir) {
    try {
        $xd = Join-Path $stageDir '_expanded'
        New-Item -ItemType Directory -Force -Path $xd | Out-Null
        $dst = Join-Path $xd $name
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and ((New-Object IO.FileInfo $dst).Length -gt 0)) { return $dst }
        [void](Invoke-Tool 'expand.exe' ('"{0}" "{1}"' -f $src, $dst))
        if ((Test-Path -LiteralPath $dst -PathType Leaf) -and ((New-Object IO.FileInfo $dst).Length -gt 0)) { return $dst }
        # single-file cabinets: expand every file of it into a folder, take the first one
        $td = Join-Path $xd ('x_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $td | Out-Null
        [void](Invoke-Tool 'expand.exe' ('"{0}" -F:* "{1}"' -f $src, $td))
        $one = Get-ChildItem -LiteralPath $td -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($one -and $one.Length -gt 0) { Move-Item -LiteralPath $one.FullName -Destination $dst -Force; return $dst }
    } catch {}
    return ''
}

# What goes into one catalog: the staged INF(s) + (optionally) the union of the files they list
# + every other file of the driver folder (the "all files" scope).
# $nameRx = file names the engine cannot handle are skipped; $lower = lower-case the member names.
function global:Get-CatMembers($d, $sm, $withFiles, $nameRx, $lower) {
    $mem = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($it in @($sm.Items)) {
        $nm = [string]$it.Name
        if ($lower) { $nm = $nm.ToLower() }
        $seen[$nm.ToLower()] = (Join-Path $d $it.Name)
        [void]$mem.Add([pscustomobject]@{ Name = $nm; Path = (Join-Path $d $it.Name); Kind = 'inf' })
    }
    $nInf = $mem.Count
    $bad = 0; $clash = 0; $nExtra = 0; $nPacked = 0; $nExpFail = 0
    $miss = @{}
    $missUsed = @{}
    if ($withFiles) {
        foreach ($it in @($sm.Items)) {
            if (-not $it.ContainsKey('Files')) {
                $it['Files'] = @(Get-InfFiles $it.InfPath)
                $it['Missing'] = @($global:InfFilesLast.Missing)
                $it['MissingUsed'] = @($global:InfFilesLast.MissingUsed)
            }
            foreach ($mf in @($it['Missing'])) { if ($mf) { $miss[[string]$mf] = $true } }
            foreach ($mu in @($it['MissingUsed'])) { if ($mu) { $missUsed[[string]$mu] = $true } }
            foreach ($f in @($it['Files'])) {
                $nm = [string]$f.Name
                if ($lower) { $nm = $nm.ToLower() }
                if ($nameRx -and ($nm -notmatch $nameRx)) { $bad++; continue }
                $lk = $nm.ToLower()
                if ($seen.ContainsKey($lk)) {
                    if ($seen[$lk] -ine [string]$f.Path) { $clash++ }
                    continue
                }
                $mp = [string]$f.Path
                if ($f.Packed) {
                    $nPacked++
                    $xp = Expand-PackedFile $mp ([string]$f.Name) $d
                    if ($xp) { $mp = $xp } else { $nExpFail++ }
                }
                $seen[$lk] = $mp
                [void]$mem.Add([pscustomobject]@{ Name = $nm; Path = $mp; Kind = 'file' })
            }
        }
        # the rest of the folder: files that the INFs copy as whole directories are not in [SourceDisksFiles]
        if ($sm.Dir -and (Test-Path -LiteralPath $sm.Dir -PathType Container)) {
            if (-not $sm.ContainsKey('Extra')) { $sm['Extra'] = @(Get-FolderFiles $sm.Dir) }
            foreach ($f in @($sm['Extra'])) {
                $nm = [string]$f.Name
                if ($lower) { $nm = $nm.ToLower() }
                if ($nameRx -and ($nm -notmatch $nameRx)) { $bad++; continue }
                $lk = $nm.ToLower()
                if ($seen.ContainsKey($lk)) {
                    if ($seen[$lk] -ine [string]$f.Path) { $clash++ }
                    continue
                }
                $seen[$lk] = [string]$f.Path
                $nExtra++
                [void]$mem.Add([pscustomobject]@{ Name = $nm; Path = [string]$f.Path; Kind = 'file' })
            }
        }
    }
    return [pscustomobject]@{ Members = $mem.ToArray(); InfCount = $nInf; FileCount = ($mem.Count - $nInf); ExtraCount = $nExtra; PackedCount = $nPacked; ExpandFailed = $nExpFail; Skipped = $bad; Clashes = $clash; Missing = $miss.Count; MissingUsed = $missUsed.Count }
}

function global:Get-MemberNote($info) {
    $s = ('members: {0} ({1} INF + {2} listed file(s)' -f $info.Members.Count, $info.InfCount, ($info.FileCount - $info.ExtraCount))
    if ($info.ExtraCount -gt 0) { $s += (' + {0} other file(s) of the folder' -f $info.ExtraCount) }
    if ($info.Skipped -gt 0) { $s += (', {0} skipped: unsupported file name' -f $info.Skipped) }
    if ($info.Clashes -gt 0) { $s += (', {0} name clash(es), first one kept' -f $info.Clashes) }
    $s += ')'
    if ($info.PackedCount -gt 0) {
        $s += (' - {0} listed file(s) are stored compressed (name.dl_): the expanded file is hashed, under the name the INF uses' -f $info.PackedCount)
        if ($info.ExpandFailed -gt 0) { $s += (' ({0} could not be expanded with expand.exe: the compressed file was hashed instead)' -f $info.ExpandFailed) }
    }
    if ($info.Missing -gt 0) {
        $s += (' - {0} file(s) named in [SourceDisksFiles] are not in the folder' -f $info.Missing)
        if ($info.MissingUsed -gt 0) { $s += (' (of these, {0} also copied by the INF: a catalog cannot hold the hash of a file that is not there)' -f $info.MissingUsed) }
    }
    return $s
}

# EXPERIMENTAL engine 1: MakeCat + generated .cdf (the INF is not parsed).
# One catalog per folder: all INFs of the folder are members of the same catalog.
# $withFiles = also hash the files listed in the INFs (read from the real driver folder), each file once.
function global:Invoke-MakeCatBatch($makecat, $dirs, $map, $withFiles) {
    $results = @()
    $total = @($dirs).Count
    $done = 0
    foreach ($d in $dirs) {
        $sm = $map[$d]
        $t = Get-Date
        $cdfName = [IO.Path]::GetFileNameWithoutExtension($sm.Cat) + '.cdf'
        $info = Get-CatMembers $d $sm $withFiles '^[A-Za-z0-9._\-]+$' $false
        $note = Get-MemberNote $info
        $lines = @('[CatalogHeader]', ('Name=' + $sm.Cat), 'ResultDir=.', 'CatalogVersion=2', 'HashAlgorithms=SHA256', 'PageHashes=false', 'EncodingType=0x00010001')
        $i = 0
        foreach ($os in $global:OsAttrList) { $i++; $lines += ('CATATTR{0}=0x10010001:OSAttr:2:{1}' -f $i, $os) }
        $lines += '[CatalogFiles]'
        foreach ($m in $info.Members) {
            $tag = '<HASH>' + $m.Name
            $mp = $m.Path
            if ($m.Kind -eq 'inf') { $mp = $m.Name }
            $lines += ($tag + '=' + $mp)
            $lines += ($tag + 'ATTR1=0x10010001:File:' + $m.Name)
            $k = 1
            foreach ($os in $global:OsAttrList) { $k++; $lines += ('{0}ATTR{1}=0x10010001:OSAttr:2:{2}' -f $tag, $k, $os) }
        }
        [IO.File]::WriteAllText((Join-Path $d $cdfName), (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::Default)

        $to = 300
        if ($withFiles) { $to = 1800 }
        $lbl = ('MakeCat {0}' -f $sm.Name)
        $mb = Get-FilesMB $info.Members
        Write-UiLog ('  MakeCat: hashing {0} member(s), {1:N0} MB, into {2}...' -f $info.Members.Count, $mb, $sm.Cat)
        Set-Status ('MakeCat: {0} member(s), {1:N0} MB...' -f $info.Members.Count, $mb)
        $r = Invoke-CmdLogged ('"{0}" -v "{1}"' -f $makecat, $cdfName) $d $to $lbl
        $code = [int]$r.ExitCode
        if (Test-Path -LiteralPath (Join-Path $d $sm.Cat)) { $code = 0 } elseif ($code -eq 0) { $code = 1 }
        $outText = [string]$r.Output
        if ($code -eq 0) {
            # success: drop the one-line-per-member chatter ("processing", "attribute", "opened"); errors keep everything
            $outText = ((@($outText -split "`r?`n") | Where-Object { $_.Trim() -and ($_ -notmatch '^\s*(attribute|processing|opened):') }) -join "`r`n")
        }
        $results += [pscustomobject]@{ Dir = $d; ExitCode = $code; Output = ($note + "`r`n" + $outText); Secs = ((Get-Date) - $t).TotalSeconds }
        $done++
        $global:InfDone = $done
        Set-Status ('MakeCat: {0} / {1} catalog(s) done' -f $done, $total)
    }
    return $results
}

# EXPERIMENTAL engine 2: libwdi-style. Native CryptCAT* API (wintrust.dll) called from C# (Add-Type),
# following libwdi pki.c: SHA1 member hashes, PE members with SPC_PE_IMAGE_DATA, INF/flat members with SPC_LINK.
function global:Ensure-NativeCat {
    if ('NvSigner.CatJob' -as [type]) { return }
    Add-Type -TypeDefinition $global:NativeCatSource -Language CSharp
}

function global:Invoke-NativeCatBatch($dirs, $map, $withFiles) {
    Ensure-NativeCat
    $results = @()
    $total = @($dirs).Count
    $done = 0
    foreach ($d in $dirs) {
        $sm = $map[$d]
        $t = Get-Date
        $info = Get-CatMembers $d $sm $withFiles '' $false
        $names = New-Object System.Collections.Generic.List[string]
        $paths = New-Object System.Collections.Generic.List[string]
        foreach ($m in $info.Members) { $names.Add([string]$m.Name); $paths.Add([string]$m.Path) }
        $catPath = Join-Path $d $sm.Cat
        $hw = ''
        if ($sm.Hwid) { $hw = ([string]$sm.Hwid).ToLower() }
        $mb = Get-FilesMB $info.Members
        Write-UiLog ('  libwdi-style: hashing {0} member(s), {1:N0} MB, into {2}...' -f $info.Members.Count, $mb, $sm.Cat)
        $job = [NvSigner.CatJob]::new($catPath, $hw, $global:OsStringNative, $global:OsAttrNative, $names.ToArray(), $paths.ToArray())
        $job.Start()
        $beat = Get-Date
        $beatLog = Get-Date
        while (-not $job.Done) {
            Do-Events
            Start-Sleep -Milliseconds 100
            if (((Get-Date) - $beat).TotalSeconds -ge 5) {
                $beat = Get-Date
                Set-Status ('libwdi-style: hashing {0} / {1} file(s) of {2}...' -f $job.Processed, $job.Total, $sm.Name)
            }
            if (((Get-Date) - $beatLog).TotalSeconds -ge 20) {
                $beatLog = Get-Date
                Write-UiLog ('  libwdi-style still running: {0} / {1} file(s) hashed ({2})' -f $job.Processed, $job.Total, (Format-Span (((Get-Date) - $t).TotalSeconds)))
            }
        }
        if ($job.Error) {
            $code = 1; $out = [string]$job.Error
            Remove-Item -LiteralPath $catPath -Force -ErrorAction SilentlyContinue
        } elseif (-not (Test-Path -LiteralPath $catPath)) {
            $code = 1; $out = 'Catalog file was not created.'
        } else {
            $code = 0; $out = (Get-MemberNote $info)
        }
        $results += [pscustomobject]@{ Dir = $d; ExitCode = $code; Output = $out; Secs = ((Get-Date) - $t).TotalSeconds }
        $done++
        $global:InfDone = $done
        Set-Status ('libwdi-style: {0} / {1} catalog(s) done' -f $done, $total)
    }
    return $results
}

# EXPERIMENTAL engine 3: LINBIT generate-cat-file (C tool, SHA1, unsigned output) run inside WSL.
function global:ShQ($s) { return ("'" + ([string]$s).Replace("'", "'\''") + "'") }

function global:Invoke-WslScript($script, $timeoutSec, $label) {
    $f = Join-Path $env:TEMP ('nvsigner_' + [guid]::NewGuid().ToString('N') + '.sh')
    $txt = ([string]$script) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($false)))
    try { return (Invoke-CmdLogged ('"wsl.exe" -e sh < "{0}"' -f $f) $null $timeoutSec $label) }
    finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

function global:Test-GenCatSources($src) {
    foreach ($k in $global:GenCatSha256.Keys) {
        $p = Join-Path $src $k
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() -ne $global:GenCatSha256[$k]) { return $false }
    }
    return $true
}

function global:Ensure-GenCat {
    Set-Status 'Checking WSL...'
    $chk = Invoke-WslScript "echo NVWSL_OK`nuname -a`n" 90
    if ($chk.Output -notmatch 'NVWSL_OK') {
        throw ('WSL is not available or has no Linux distribution installed (run "wsl --install" in an administrator terminal). ' + ([string]$chk.Output).Trim())
    }
    $kern = ($chk.Output -split "`r?`n" | Where-Object { $_ -match 'Linux' } | Select-Object -First 1)
    Write-UiLog ('WSL ready: ' + $kern)
    $src = Join-Path $global:ToolsDir 'gencat\src'
    if (-not (Test-GenCatSources $src)) {
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        $zipPath = Join-Path $global:ToolsDir 'gencat_src.zip'
        $url = 'https://github.com/LINBIT/generate-cat-file/archive/' + $global:GenCatCommit + '.zip'
        Write-UiLog 'Downloading generate-cat-file source (LINBIT, GPL-2.0, pinned commit)...'
        Download-File $url $zipPath
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($x in $zip.Entries) {
                $isRoot = (@($x.FullName.Split('/')).Count -eq 2)
                if ($isRoot -and ($global:GenCatSha256.ContainsKey($x.Name) -or $x.Name -eq 'COPYING')) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($x, (Join-Path $src $x.Name), $true)
                }
            }
        } finally { $zip.Dispose() }
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        if (-not (Test-GenCatSources $src)) { throw 'generate-cat-file sources failed the SHA-256 integrity check (not the pinned commit). Nothing was built.' }
        Write-UiLog 'generate-cat-file sources verified (SHA-256).'
    }
    Set-Status 'Building generate-cat-file inside WSL...'
    $build = @'
set -e
SRC="$(wslpath -a @SRC@)"
DST="$HOME/.nvsigner-gencat"
if [ -x "$DST/generate-cat-file" ] && [ -x "$DST/strip-pe-image" ] && [ -f "$DST/gencat.sh" ] && [ "$(cat "$DST/COMMIT" 2>/dev/null)" = "@COMMIT@" ]; then echo NVGC_BUILD_OK; exit 0; fi
for t in gcc make sha1sum getopt bash sort cut tr basename dirname sed; do
  command -v "$t" >/dev/null 2>&1 || { echo "NVGC_ERR missing tool inside WSL: $t (try: sudo apt install build-essential)"; exit 90; }
done
rm -rf "$DST"
mkdir -p "$DST"
cp "$SRC/generate-cat-file.c" "$SRC/strip-pe-image.c" "$SRC/gencat.sh" "$SRC/Makefile" "$DST/"
cd "$DST"
sed -i 's/\r$//' gencat.sh Makefile generate-cat-file.c strip-pe-image.c
make >build.log 2>&1 || { echo "NVGC_ERR build failed"; tail -n 20 build.log; exit 94; }
chmod +x gencat.sh generate-cat-file strip-pe-image
echo "@COMMIT@" > COMMIT
echo NVGC_BUILD_OK
'@
    $build = $build.Replace('@SRC@', (ShQ $src)).Replace('@COMMIT@', $global:GenCatCommit)
    $r = Invoke-WslScript $build 900
    if ($r.Output -notmatch 'NVGC_BUILD_OK') { throw ('Building generate-cat-file inside WSL failed: ' + ([string]$r.Output).Trim()) }
    Write-UiLog 'generate-cat-file ready (built inside WSL).'
}

function global:Invoke-GenCatBatch($dirs, $map, $withFiles) {
    $results = @()
    $total = @($dirs).Count
    $done = 0
    $tpl = @'
set -e
D="$HOME/.nvsigner-gencat"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
@LINKS@cd "$W"
bash "$D/gencat.sh" -o "$W/out.cat" -h @HWID@ -O @OS@ -A @OSATTR@ @NAMES@ </dev/null
cp "$W/out.cat" "$(wslpath -a @OUTCAT@)"
echo NVGC_RUN_OK
'@
    foreach ($d in $dirs) {
        $sm = $map[$d]
        $t = Get-Date
        $info = Get-CatMembers $d $sm $withFiles '^[a-z0-9._\-]+$' $true
        $names = New-Object System.Collections.ArrayList
        $links = New-Object System.Text.StringBuilder
        foreach ($m in $info.Members) {
            [void]$names.Add([string]$m.Name)
            [void]$links.Append(('ln -s "$(wslpath -a {0})" "$W/{1}"' -f (ShQ $m.Path), $m.Name)).Append("`n")
        }
        $hw = ''
        if ($sm.Hwid) { $hw = ([string]$sm.Hwid).ToLower() }
        $script = $tpl.Replace('@LINKS@', $links.ToString()).Replace('@HWID@', (ShQ $hw)).Replace('@OS@', (ShQ $global:OsStringGenCat)).Replace('@OSATTR@', (ShQ $global:OsAttrGenCat)).Replace('@NAMES@', ($names -join ' ')).Replace('@OUTCAT@', (ShQ (Join-Path $d $sm.Cat)))
        $to = 300
        if ($withFiles) { $to = 1800 }
        $lbl = ('generate-cat-file (WSL) {0}' -f $sm.Name)
        Write-UiLog ('  generate-cat-file: hashing {0} member(s) in WSL into {1}...' -f $names.Count, $sm.Cat)
        Set-Status ('generate-cat-file (WSL): {0} ({1} member(s))...' -f $sm.Name, $names.Count)
        $r = Invoke-WslScript $script $to $lbl
        $code = [int]$r.ExitCode
        if (($r.Output -match 'NVGC_RUN_OK') -and (Test-Path -LiteralPath (Join-Path $d $sm.Cat))) { $code = 0 } elseif ($code -eq 0) { $code = 1 }
        $results += [pscustomobject]@{ Dir = $d; ExitCode = $code; Output = ((Get-MemberNote $info) + "`r`n" + ([string]$r.Output).Trim()); Secs = ((Get-Date) - $t).TotalSeconds }
        $done++
        $global:InfDone = $done
        Set-Status ('generate-cat-file: {0} / {1} catalog(s) done' -f $done, $total)
    }
    return $results
}

# Finds / downloads / compiles what an engine needs. Returns the tool path (Inf2Cat, MakeCat) or a marker.
function global:Prepare-Engine($engine) {
    switch ($engine) {
        'makecat' { return (Ensure-MakeCat) }
        'libwdi'  { Ensure-NativeCat; return 'native' }
        'gencat'  { Ensure-GenCat; return 'wsl' }
        default   { return (Ensure-Tool 'Microsoft.Windows.WDK.x64' 'Inf2Cat.exe' 'wdk' '^10\.0\.26100\.\d+$' '/x86/') }
    }
}

function global:Invoke-CatEngine($engine, $tool, $dirs, $map, $withFiles, $osList, $jobs) {
    switch ($engine) {
        'makecat' { return @(Invoke-MakeCatBatch $tool $dirs $map $withFiles) }
        'libwdi'  { return @(Invoke-NativeCatBatch $dirs $map $withFiles) }
        'gencat'  { return @(Invoke-GenCatBatch $dirs $map $withFiles) }
        default   { return @(Invoke-Inf2CatParallel $tool $dirs $osList $jobs) }
    }
}

# Runs Inf2Cat on several package folders at the same time (max $maxJobs processes).
function global:Invoke-Inf2CatParallel($exe, $dirs, $os, $maxJobs) {
    $queue = New-Object System.Collections.Queue
    foreach ($d in $dirs) { $queue.Enqueue($d) }
    $total = $queue.Count
    $done = 0
    $running = @()
    $results = @()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $maxJobs) {
            $d = $queue.Dequeue()
            $log = Join-Path $env:TEMP ('nvsigner_' + [guid]::NewGuid().ToString('N') + '.log')
            $argStr = '/driver:"{0}" /os:{1} /uselocaltime' -f $d, $os
            $cmdline = '/c ""{0}" {1} > "{2}" 2>&1"' -f $exe, $argStr, $log
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdline -WindowStyle Hidden -PassThru
            $lbl = (@(Get-ChildItem -LiteralPath $d -Filter '*.inf' -File -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')
            if (-not $lbl) { $lbl = Split-Path -Leaf $d }
            $running += [pscustomobject]@{ Proc = $p; Dir = $d; Log = $log; Start = (Get-Date); LastBeat = (Get-Date); Label = $lbl }
            Write-UiLog "Inf2Cat started: $d"
        }
        Do-Events
        Start-Sleep -Milliseconds 150
        if ($global:StopRequested) {
            foreach ($j in $running) {
                try { Start-Process -FilePath 'taskkill.exe' -ArgumentList ('/PID {0} /T /F' -f $j.Proc.Id) -WindowStyle Hidden -Wait } catch {}
                try { [void]$j.Proc.WaitForExit(5000) } catch {}
                Remove-Item -LiteralPath $j.Log -Force -ErrorAction SilentlyContinue
                $results += [pscustomobject]@{ Dir = $j.Dir; ExitCode = -999; Output = '(stopped by user)'; Secs = ((Get-Date) - $j.Start).TotalSeconds }
            }
            while ($queue.Count -gt 0) {
                $dq = $queue.Dequeue()
                $results += [pscustomobject]@{ Dir = $dq; ExitCode = -999; Output = '(stopped by user, not started)'; Secs = 0 }
            }
            $running = @()
            break
        }
        $still = @()
        foreach ($j in $running) {
            if ($j.Proc.HasExited) {
                $j.Proc.WaitForExit()
                $out = ''
                if (Test-Path -LiteralPath $j.Log) {
                    $raw = Get-Content -LiteralPath $j.Log -Raw -ErrorAction SilentlyContinue
                    if ($raw) { $out = $raw }
                    Remove-Item -LiteralPath $j.Log -Force -ErrorAction SilentlyContinue
                }
                $results += [pscustomobject]@{ Dir = $j.Dir; ExitCode = $j.Proc.ExitCode; Output = $out; Secs = ((Get-Date) - $j.Start).TotalSeconds }
                $done++
                $global:InfDone = $done
                Set-Status ('Inf2Cat: {0} / {1} package(s) done' -f $done, $total)
            } else {
                if (((Get-Date) - $j.LastBeat).TotalSeconds -ge 60) {
                    $j.LastBeat = Get-Date
                    Write-UiLog ('  Inf2Cat still running for {0}  ({1}) - the Stop button skips it' -f $j.Label, (Format-Span (((Get-Date) - $j.Start).TotalSeconds)))
                }
                $still += $j
            }
        }
        $running = $still
    }
    return $results
}

function global:Get-NvGpus {
    $list = @()
    try {
        foreach ($v in (Get-CimInstance Win32_VideoController)) {
            if ($v.PNPDeviceID -match 'VEN_10DE&DEV_([0-9A-F]{4})') {
                $list += ('DEV_{0} - {1}' -f $Matches[1], $v.Name)
            }
        }
    } catch {}
    return $list
}

function global:Get-DevId {
    $t = $global:cbGpu.Text
    if ($t -match '(?i)DEV_([0-9A-F]{4})') { return $Matches[1].ToUpper() }
    if ($t -match '^\s*([0-9A-Fa-f]{4})\s*$') { return $Matches[1].ToUpper() }
    return $null
}

function global:Find-GpuInf($root, $dev) {
    $hits = @()
    $infs = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.inf' })
    Write-UiLog ("Scanning {0} .inf file(s) for VEN_10DE&DEV_{1} ..." -f $infs.Count, $dev)
    foreach ($f in $infs) {
        try {
            $txt = [IO.File]::ReadAllText($f.FullName)
            if ($txt -match ('(?i)VEN_10DE&DEV_' + $dev)) { $hits += $f }
        } catch {}
        Do-Events
    }
    return $hits
}

function global:Get-SigningCert {
    $c = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $global:CertSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $c) {
        Write-UiLog 'Creating self-signed code-signing certificate (valid 10 years)...'
        $c = New-SelfSignedCertificate -Type CodeSigningCert -Subject $global:CertSubject -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy Exportable -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(10)
    } else {
        Write-UiLog 'Reusing existing signing certificate.'
    }
    return $c
}

function global:Install-CertTrust($cert) {
    foreach ($name in @('Root', 'TrustedPublisher')) {
        $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
        $st.Open('ReadWrite')
        $has = $st.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
        if (-not $has) {
            $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $cert.RawData)
            $st.Add($pub)
            Write-UiLog "Certificate added to LocalMachine\$name."
        }
        $st.Close()
    }
}

# ============================================================================
#  "Test all engines": builds the catalogs with every selected engine in a temporary
#  folder (your driver folder is never modified), signs them, checks them with
#  signtool and, optionally, asks Windows itself (pnputil) whether it accepts them.
# ============================================================================
$global:TestCombos = @(
    [pscustomobject]@{ Id = 'makecat-inf';   Engine = 'makecat'; Pkg = $false; WithFiles = $false; SkipPnp = $true;  Default = $true;  Short = 'MakeCat INF-only';   Title = 'MakeCat - INF only (Windows rejects it when the INF copies files)' },
    [pscustomobject]@{ Id = 'makecat-files'; Engine = 'makecat'; Pkg = $false; WithFiles = $true;  SkipPnp = $false; Default = $true;  Short = 'MakeCat all files';  Title = 'MakeCat - INF + all files of the driver folder' },
    [pscustomobject]@{ Id = 'libwdi-inf';    Engine = 'libwdi';  Pkg = $false; WithFiles = $false; SkipPnp = $true;  Default = $true;  Short = 'libwdi INF-only';   Title = 'libwdi-style (native CryptCAT) - INF only' },
    [pscustomobject]@{ Id = 'libwdi-files';  Engine = 'libwdi';  Pkg = $false; WithFiles = $true;  SkipPnp = $false; Default = $true;  Short = 'libwdi all files';  Title = 'libwdi-style (native CryptCAT) - INF + all files of the driver folder' },
    [pscustomobject]@{ Id = 'gencat-inf';    Engine = 'gencat';  Pkg = $false; WithFiles = $false; SkipPnp = $true;  Default = $false; Short = 'gencat INF-only';   Title = 'generate-cat-file (needs WSL) - INF only' },
    [pscustomobject]@{ Id = 'gencat-files';  Engine = 'gencat';  Pkg = $false; WithFiles = $true;  SkipPnp = $false; Default = $false; Short = 'gencat all files';  Title = 'generate-cat-file (needs WSL) - INF + all files of the driver folder' },
    [pscustomobject]@{ Id = 'inf2cat-inf';   Engine = 'inf2cat'; Pkg = $false; WithFiles = $false; SkipPnp = $true;  Default = $true;  Short = 'Inf2Cat INF-only';   Title = 'Inf2Cat - INF only (isolated; fails if the INF needs its files)' },
    [pscustomobject]@{ Id = 'inf2cat-pkg';   Engine = 'inf2cat'; Pkg = $true;  WithFiles = $false; SkipPnp = $false; Default = $false; Short = 'Inf2Cat INF+files'; Title = 'Inf2Cat - INF + the files it lists (links/copies; closest to the standard result)' }
)

function global:Show-EngineTestDialog($hits, $infos) {
    $cBg = [Drawing.Color]::FromArgb(30, 30, 33)
    $cPanel = [Drawing.Color]::FromArgb(45, 45, 50)
    $cFg = [Drawing.Color]::FromArgb(235, 235, 235)
    $cDim = [Drawing.Color]::FromArgb(160, 160, 165)
    $cGreen = [Drawing.Color]::FromArgb(118, 185, 0)

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Test all catalog engines'
    $dlg.Size = New-Object Drawing.Size(660, 560)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true
    $dlg.BackColor = $cBg
    $dlg.ForeColor = $cFg
    $dlg.Font = New-Object Drawing.Font('Segoe UI', 9)

    $l1 = New-Object Windows.Forms.Label
    $l1.Text = 'Pick what to test. Each selected engine builds the catalog for your GPU INF(s) in a temporary folder (one shared catalog per driver folder, like the original nv_dispi.cat), signs it and checks it with signtool. Your driver folder is NOT changed. A summary table with the times is shown at the end.'
    $l1.Location = New-Object Drawing.Point(16, 12)
    $l1.Size = New-Object Drawing.Size(615, 50)
    $l1.ForeColor = $cFg
    $dlg.Controls.Add($l1)

    $clb = New-Object Windows.Forms.CheckedListBox
    $clb.Location = New-Object Drawing.Point(16, 66)
    $clb.Size = New-Object Drawing.Size(615, 190)
    $clb.CheckOnClick = $true
    $clb.BackColor = $cPanel
    $clb.ForeColor = $cFg
    $clb.BorderStyle = 'FixedSingle'
    foreach ($c in $global:TestCombos) { [void]$clb.Items.Add($c.Title, $c.Default) }
    $dlg.Controls.Add($clb)

    $l2 = New-Object Windows.Forms.Label
    $l2.Text = '"INF only" hashes just the INF: Windows always rejects such a catalog when the INF copies files, so the pnputil test is not run for it. "all files" hashes every file of the driver folder (the files the INF lists and the ones it copies as whole directories). Inf2Cat INF+files and generate-cat-file are off by default (slower / need extra downloads or WSL).'
    $l2.Location = New-Object Drawing.Point(16, 262)
    $l2.Size = New-Object Drawing.Size(615, 52)
    $l2.ForeColor = $cDim
    $dlg.Controls.Add($l2)

    $chkPnp = New-Object Windows.Forms.CheckBox
    $chkPnp.Text = 'Also ask Windows (pnputil /add-driver, then /delete-driver) if it accepts each result, using this INF:'
    $chkPnp.Location = New-Object Drawing.Point(16, 320)
    $chkPnp.Size = New-Object Drawing.Size(615, 22)
    $chkPnp.ForeColor = $cFg
    $chkPnp.Checked = $false
    $dlg.Controls.Add($chkPnp)

    $cbPnp = New-Object Windows.Forms.ComboBox
    $cbPnp.Location = New-Object Drawing.Point(16, 346)
    $cbPnp.Size = New-Object Drawing.Size(615, 24)
    $cbPnp.DropDownStyle = 'DropDownList'
    $cbPnp.BackColor = $cPanel
    $cbPnp.ForeColor = $cFg
    $cbPnp.FlatStyle = 'Flat'
    $best = 0
    for ($i = 0; $i -lt @($hits).Count; $i++) {
        [void]$cbPnp.Items.Add(('{0}   ({1:N1} MB of listed files)' -f $hits[$i].Name, $infos[$i].MB))
        if ($infos[$i].MB -lt $infos[$best].MB) { $best = $i }
    }
    $cbPnp.SelectedIndex = $best
    $dlg.Controls.Add($cbPnp)

    $l3 = New-Object Windows.Forms.Label
    $l3.Text = 'The pnputil test builds a throw-away copy of the driver folder (hard links, no extra disk space on the same drive) with the new INF and catalog, adds it to the Windows driver store and deletes it again (never with /force). Nothing is installed on a device. The verdict is read from setupapi.dev.log, not from the exit code: if Windows shows the "can''t verify the publisher" prompt, choose "Don''t install" - the result is then NOT TRUSTED and names the file whose hash is missing from the catalog.'
    $l3.Location = New-Object Drawing.Point(16, 376)
    $l3.Size = New-Object Drawing.Size(615, 88)
    $l3.ForeColor = $cDim
    $dlg.Controls.Add($l3)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = 'Run test'
    $btnOk.Location = New-Object Drawing.Point(405, 470)
    $btnOk.Size = New-Object Drawing.Size(120, 34)
    $btnOk.FlatStyle = 'Flat'
    $btnOk.FlatAppearance.BorderSize = 0
    $btnOk.BackColor = $cGreen
    $btnOk.ForeColor = [Drawing.Color]::Black
    $btnOk.DialogResult = [Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object Drawing.Point(531, 470)
    $btnCancel.Size = New-Object Drawing.Size(100, 34)
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.FlatAppearance.BorderSize = 0
    $btnCancel.BackColor = [Drawing.Color]::FromArgb(70, 70, 76)
    $btnCancel.ForeColor = $cFg
    $btnCancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel

    $ret = $null
    $res = $dlg.ShowDialog()
    if ($res -eq [Windows.Forms.DialogResult]::OK) {
        $sel = @()
        for ($i = 0; $i -lt $global:TestCombos.Count; $i++) {
            if ($clb.GetItemChecked($i)) { $sel += $global:TestCombos[$i] }
        }
        $pi = $cbPnp.SelectedIndex
        if ($pi -lt 0) { $pi = 0 }
        $ret = [pscustomobject]@{ Combos = $sel; Pnp = [bool]$chkPnp.Checked; PnpIndex = $pi }
    }
    $dlg.Dispose()
    return $ret
}

# Published names (oemNN.inf) currently in the driver store; works with any Windows language
function global:Get-OemInfs {
    $o = Invoke-Tool 'pnputil.exe' '/enum-drivers'
    $set = @{}
    foreach ($m in [regex]::Matches([string]$o.Output, '(?i)\boem\d+\.inf\b')) { $set[$m.Value.ToLower()] = $true }
    return $set
}

# Position of the end of setupapi.dev.log (Windows writes what it thinks about every driver package there)
function global:Get-SetupApiPos {
    try { return [long](New-Object IO.FileInfo (Join-Path $env:windir 'INF\setupapi.dev.log')).Length } catch { return [long]0 }
}

# Text Windows appended to setupapi.dev.log since $pos (max 3 MB)
function global:Read-SetupApiSince($pos) {
    $p = Join-Path $env:windir 'INF\setupapi.dev.log'
    try {
        $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $start = [long]$pos
            if ($start -gt $fs.Length) { $start = [long]0 }
            $len = [int][Math]::Min([long]($fs.Length - $start), [long]3145728)
            if ($len -le 0) { return '' }
            [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] $len
            $n = $fs.Read($buf, 0, $len)
            return [Text.Encoding]::Default.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch { return '' }
}

# Error/warning lines of that text (what the log says went wrong) + its last lines
function global:Get-SetupApiHints($text) {
    $key = New-Object System.Collections.ArrayList
    $all = @(([string]$text) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    foreach ($l in $all) {
        if ($l -match '!!!|^\s*!\s|\berror\b|\bfailed\b|not found|cannot find|\b0x[0-9A-Fa-f]{8}\b') {
            $c = ($l.TrimEnd() -replace '[^\x20-\x7E]', '?')
            if ($c.Length -gt 230) { $c = $c.Substring(0, 230) }
            if (-not $key.Contains($c)) { [void]$key.Add($c) }
        }
    }
    $tail = New-Object System.Collections.ArrayList
    for ($i = [Math]::Max(0, $all.Count - 40); $i -lt $all.Count; $i++) {
        $c = ($all[$i].TrimEnd() -replace '[^\x20-\x7E]', '?')
        if ($c.Length -gt 230) { $c = $c.Substring(0, 230) }
        [void]$tail.Add($c)
    }
    return [pscustomobject]@{ Key = $key.ToArray(); Tail = $tail.ToArray() }
}

# What setupapi.dev.log says about the signature check of a package. These lines are not localized.
# "Failed to verify file 'X' against catalog 'Y'. Error = 0xE000024B" / "Driver package appears to be tampered"
# means that Windows found a file whose hash is NOT in the catalog. In that case Windows shows the
# "can't verify the publisher" prompt, and pnputil only returns success if the user clicks "Install anyway".
function global:Get-SetupApiTrust($text, $pkgDir) {
    $t = [string]$text
    $files = New-Object System.Collections.ArrayList
    $first = $null
    foreach ($m in [regex]::Matches($t, "(?m)Failed to verify file '([^']+)' against catalog '([^']*)'[^\r\n]*?Error\s*=\s*(0x[0-9A-Fa-f]{8})")) {
        if ($null -eq $first) { $first = $m }
        $fn = $m.Groups[1].Value
        if (-not $files.Contains($fn)) { [void]$files.Add($fn) }
    }
    $tamper = [regex]::IsMatch($t, 'appears to be tampered')
    $where = @()
    $wherePk = @()
    $file = ''; $cat = ''; $err = ''
    if ($first) {
        $file = $first.Groups[1].Value; $cat = $first.Groups[2].Value; $err = $first.Groups[3].Value.ToUpper().Replace('0X', '0x')
        if ($pkgDir -and (Test-Path -LiteralPath $pkgDir -PathType Container)) {
            $base = (Resolve-Path -LiteralPath $pkgDir).Path.TrimEnd('\')
            try { $where = @(Get-ChildItem -LiteralPath $base -Recurse -File -Force -Filter $file -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($base.Length).TrimStart('\') }) } catch {}
            $pkn = Get-PackedName $file
            if ($where.Count -eq 0 -and $pkn) {
                try { $wherePk = @(Get-ChildItem -LiteralPath $base -Recurse -File -Force -Filter $pkn -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($base.Length).TrimStart('\') }) } catch {}
            }
        }
    }
    return [pscustomobject]@{ Bad = ([bool]($first -or $tamper)); File = $file; Catalog = $cat; Error = $err; Files = $files.ToArray(); Tampered = $tamper; Found = $where; FoundPacked = $wherePk }
}

# Asks Windows to import the package into the driver store (no device install), then removes
# only what that call added. Returns a short result text. When Windows says no, the relevant
# lines of setupapi.dev.log are shown (they name the file / signature problem); the same lines
# are kept in $global:LastPnpExcerpt for the report.
function global:Test-PnpAccept($pkgDir, $infName) {
    $global:LastPnpExcerpt = @()
    $before = Get-OemInfs
    $pos = Get-SetupApiPos
    $r = Invoke-Tool 'pnputil.exe' ('/add-driver "{0}"' -f (Join-Path $pkgDir $infName))
    $after = Get-OemInfs
    $setup = Read-SetupApiSince $pos
    $new = @($after.Keys | Where-Object { -not $before.ContainsKey($_) })
    $named = @([regex]::Matches([string]$r.Output, '(?i)\boem\d+\.inf\b') | ForEach-Object { $_.Value.ToLower() })
    $code = [int]$r.ExitCode
    $good = (($code -eq 0 -or $code -eq 3010) -and (($new.Count -gt 0) -or ($named.Count -gt 0)))
    foreach ($o in $new) {
        $d = Invoke-Tool 'pnputil.exe' ('/delete-driver {0}' -f $o)
        Write-UiLog ('    pnputil: removed {0} again (exit {1})' -f $o, $d.ExitCode)
    }
    foreach ($line in (([string]$r.Output) -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('    pnputil> ' + $line.Trim()) } }
    $hints = Get-SetupApiHints $setup
    $ex = New-Object System.Collections.ArrayList
    if ($hints.Key.Count -gt 0) {
        [void]$ex.Add('setupapi.dev.log - error/warning lines written during this pnputil call:')
        foreach ($k in @($hints.Key | Select-Object -First 80)) { [void]$ex.Add('  ' + $k) }
    }
    if ($hints.Tail.Count -gt 0) {
        [void]$ex.Add('setupapi.dev.log - last lines written during this pnputil call:')
        foreach ($k in $hints.Tail) { [void]$ex.Add('  ' + $k) }
    }
    # The exit code is not the verdict: pnputil returns 0 after the user clicks "Install this driver software
    # anyway", even though Windows found files whose hash is not in the catalog.
    $tr = Get-SetupApiTrust $setup $pkgDir
    if ($tr.Bad) {
        $head = New-Object System.Collections.ArrayList
        $short = 'Windows reports a tampered package'
        if ($tr.File) {
            if ($tr.Error -eq '0xE000024B') { $short = ('{0}: hash not in the catalog' -f $tr.File) } else { $short = ('{0}: cannot be verified, {1}' -f $tr.File, $tr.Error) }
            [void]$head.Add(("verdict: NOT TRUSTED - setupapi.dev.log: Failed to verify file '{0}' against catalog '{1}' (error {2}); {3} file(s) named in the log." -f $tr.File, $tr.Catalog, $tr.Error, @($tr.Files).Count))
            if (@($tr.Found).Count -gt 0) {
                [void]$head.Add(("         The file IS in the package ({0}), so the catalog has no hash for it: it was not put into the catalog." -f ((@($tr.Found) | Select-Object -First 3) -join ', ')))
            } elseif (@($tr.FoundPacked).Count -gt 0) {
                [void]$head.Add(("         The file is in the package only in compressed form ({0}). The catalog must hold the hash of the EXPANDED file under the name {1} (the name the INF uses); the tool does that since v2.2.2. If you still see this, expand.exe may have failed (see the member line of the catalog) or the compressed file is not in a format expand.exe reads." -f ((@($tr.FoundPacked) | Select-Object -First 3) -join ', '), $tr.File))
            } else {
                [void]$head.Add('         The file is NOT in the package (not even compressed): a catalog cannot hold the hash of a file that is not there. Restore it from the original NVIDIA package.')
            }
        } else {
            [void]$head.Add('verdict: NOT TRUSTED - setupapi.dev.log says the driver package appears to be tampered.')
        }
        [void]$head.Add(('         pnputil exit code {0}: Windows only gives 0 after the user clicks "Install this driver software anyway" on the Windows Security prompt; that click does not make the catalog good.' -f $code))
        $ex.InsertRange(0, $head)
        $global:LastPnpExcerpt = $ex.ToArray()
        foreach ($hl in $head) { Write-UiLog ('    ' + $hl) }
        return ('NOT TRUSTED ({0})' -f $short)
    }
    $global:LastPnpExcerpt = $ex.ToArray()
    if ($good) {
        if ($new.Count -eq 0) { return 'ACCEPTED (already in store)' }
        return 'ACCEPTED'
    }
    if ($hints.Key.Count -gt 0) {
        Write-UiLog '    setupapi.dev.log - what Windows reports about this package:'
        foreach ($k in @($hints.Key | Select-Object -First 25)) { Write-UiLog ('      ' + $k.Trim()) }
    } else {
        Write-UiLog '    (setupapi.dev.log has no new error lines for this call)'
    }
    return ('REJECTED (0x{0:X8})' -f $code)
}

function global:Start-EngineTest {
    $root = $global:tbDir.Text.Trim().Trim('"')
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('Choose the modded driver folder first.', $global:AppName, 'OK', 'Warning'); return
    }
    $rootFull = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
    if ($rootFull.Length -le 3 -or $rootFull -ieq $env:windir -or $rootFull -ieq $env:ProgramFiles -or $rootFull -ieq $env:USERPROFILE) {
        [void][System.Windows.Forms.MessageBox]::Show('That folder is too broad. Pick the extracted driver folder itself.', $global:AppName, 'OK', 'Warning'); return
    }
    $dev = Get-DevId
    if (-not $dev) {
        [void][System.Windows.Forms.MessageBox]::Show('Enter your GPU device ID (example: DEV_2518) or press Detect.', $global:AppName, 'OK', 'Warning'); return
    }

    $stageRoot = $null
    Set-Busy $true
    try {
        Start-Plan @{ scan = 8; tools = 0; cert = 5; test = 60 }
        Set-Status 'Scanning INF files...'
        $hits = @(Find-GpuInf $rootFull $dev)
        if ($hits.Count -eq 0) { throw "No .inf in that folder contains VEN_10DE&DEV_$dev. Check the device ID and the folder." }
        $infos = @()
        $scanNotes = New-Object System.Collections.ArrayList
        foreach ($h in $hits) {
            Write-UiLog "GPU INF: $($h.FullName)"
            $files = @(Get-InfFiles $h.FullName)
            $st = $global:InfFilesLast
            $infos += [pscustomobject]@{ Files = $files; MB = (Get-FilesMB $files); Missing = @($st.Missing); MissingUsed = @($st.MissingUsed) }
            Write-UiLog ('  lists {0} existing file(s), {1:N1} MB' -f $files.Count, $infos[$infos.Count - 1].MB)
            if (@($st.Missing).Count -gt 0) {
                $exm = (@($st.Missing) | Select-Object -First 4) -join ', '
                if (@($st.MissingUsed).Count -gt 0) {
                    $exu = (@($st.MissingUsed) | Select-Object -First 4) -join ', '
                    $note = ('{0}: {1} file(s) named in [SourceDisksFiles] are NOT in the folder, and {2} of them are also copied by the INF (e.g. {3}). A catalog cannot hold the hash of a file that is not there, so Windows may refuse the package whatever the catalog is (the pnputil test names the file it fails on). Restore the file(s) from the original NVIDIA package.' -f $h.Name, @($st.Missing).Count, @($st.MissingUsed).Count, $exu)
                } else {
                    $note = ('{0}: {1} file(s) named in [SourceDisksFiles] are NOT in the folder (e.g. {2}), but no copy section of the INF uses them, so this is harmless.' -f $h.Name, @($st.Missing).Count, $exm)
                }
                Write-UiLog ('  WARNING: ' + $note)
                [void]$scanNotes.Add($note)
            }
            if (@($st.Packed).Count -gt 0) {
                $exp = (@($st.Packed) | Select-Object -First 4) -join ', '
                $note = ('{0}: {1} listed file(s) are stored compressed in the folder (e.g. {2}). The INF names the expanded file, so they are not missing; the catalog gets the hash of the expanded file (expand.exe) under the name the INF uses.' -f $h.Name, @($st.Packed).Count, $exp)
                Write-UiLog ('  note: ' + $note)
                [void]$scanNotes.Add($note)
            }
            if (@($st.Dup).Count -gt 0) {
                $note = ('{0}: {1} file name(s) occur in more than one sub-folder; a catalog member is identified by file name only, so the first one is used.' -f $h.Name, @($st.Dup).Count)
                Write-UiLog ('  note: ' + $note)
                [void]$scanNotes.Add($note)
            }
        }
        Set-PhaseDone 'scan'

        $sel = Show-EngineTestDialog $hits $infos
        if ((-not $sel) -or (@($sel.Combos).Count -eq 0)) { Write-UiLog 'Engine test cancelled.'; return }
        $combos = @($sel.Combos)
        $global:PlanExp['test'] = 25.0 * $combos.Count
        if ($sel.Pnp) { $global:PlanExp['test'] += 20.0 * $combos.Count }

        # tools for every engine that was selected (an engine that cannot be prepared is skipped)
        $engines = @($combos | ForEach-Object { $_.Engine } | Select-Object -Unique)
        $needDl = $false
        if ($engines -contains 'inf2cat' -and -not (Get-ChildItem -Path (Join-Path $global:ToolsDir 'wdk') -Filter 'Inf2Cat.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)) { $needDl = $true }
        if ($engines -contains 'makecat' -and -not (Find-KitTool 'makecat.exe' @('signtool', 'makecat-wdk'))) { $needDl = $true }
        if ($needDl) { $global:PlanExp['tools'] = 150.0 }
        $tools = @{}
        $unavail = @{}
        foreach ($e in $engines) {
            Set-Status ('Preparing engine: ' + $e)
            try { $tools[$e] = Prepare-Engine $e } catch {
                $unavail[$e] = $_.Exception.Message
                Write-UiLog ('Engine "{0}" is not available: {1}' -f $e, $_.Exception.Message)
            }
        }
        $stool = Find-KitTool 'signtool.exe' @('signtool')
        if (-not $stool) {
            try { $stool = Ensure-Tool 'Microsoft.Windows.SDK.BuildTools' 'signtool.exe' 'signtool' '^10\.0\.26100\.\d+$' '/x64/' } catch { Write-UiLog ('signtool not available, the verify column will be empty: ' + $_.Exception.Message) }
        }
        Set-PhaseDone 'tools'

        Set-Status 'Preparing certificate...'
        $cert = Get-SigningCert
        if ($global:chkTrust.Checked) { Install-CertTrust $cert }
        Set-PhaseDone 'cert'

        $osList = Get-CurrentOsToken
        $jobs = [int]$global:nudJobs.Value
        $stageRoot = Join-Path $env:TEMP ('nvsigner_test_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
        $hw = 'pci\ven_10de&dev_' + $dev.ToLower()
        # INFs that live in the same folder share ONE catalog (hashed once)
        $hitGroups = @()
        $gmap = @{}
        for ($i = 0; $i -lt $hits.Count; $i++) {
            $gk = $hits[$i].DirectoryName.ToLower()
            if (-not $gmap.ContainsKey($gk)) {
                $gmap[$gk] = @{ Dir = $hits[$i].DirectoryName; Idx = (New-Object System.Collections.ArrayList) }
                $hitGroups += $gmap[$gk]
            }
            [void]$gmap[$gk].Idx.Add($i)
        }
        Write-UiLog ('{0} GPU INF(s) in {1} folder(s): MakeCat / libwdi-style / generate-cat-file build one shared catalog per folder, Inf2Cat one per INF.' -f $hits.Count, $hitGroups.Count)
        $rows = @()
        $detail = New-Object System.Collections.ArrayList
        foreach ($sn in $scanNotes) { [void]$detail.Add('scan: ' + $sn) }
        $ci = 0
        foreach ($c in $combos) {
            $ci++
            Set-Status ('Testing {0} / {1}: {2}' -f $ci, $combos.Count, $c.Short)
            Write-UiLog ('--- [{0}/{1}] {2}' -f $ci, $combos.Count, $c.Title)
            $row = [pscustomobject]@{ Short = $c.Short; Build = '-'; Signed = '-'; Verify = '-'; Accept = '-' }
            $rows += $row
            $global:StopRequested = $false
            if (-not $tools.ContainsKey($c.Engine)) {
                $row.Build = 'SKIPPED'
                $row.Accept = 'n/a'
                [void]$detail.Add(('{0}: engine not available: {1}' -f $c.Short, $unavail[$c.Engine]))
            } else {
                $cs = Join-Path $stageRoot $c.Id
                $map = @{}
                $dirs = @()
                $n = 0
                # Inf2Cat uses one core per process: one catalog (and process) per INF, so they run in parallel.
                # The other engines put all the INFs of a folder into one shared catalog (files hashed once).
                $units = @()
                if ($c.Engine -eq 'inf2cat') {
                    foreach ($g in $hitGroups) { foreach ($ix in $g.Idx) { $units += @{ Dir = $g.Dir; Idx = @([int]$ix); Cat = ($hits[[int]$ix].BaseName.ToLower() + '_nvsigner.cat') } } }
                } else {
                    foreach ($g in $hitGroups) { $units += @{ Dir = $g.Dir; Idx = @($g.Idx | ForEach-Object { [int]$_ }); Cat = (Get-SharedCatName $g.Dir) } }
                }
                foreach ($u in $units) {
                    $n++
                    $sd = Join-Path $cs ('g{0:000}' -f $n)
                    $gh = @(); foreach ($ix in $u.Idx) { $gh += $hits[$ix] }
                    $smG = New-StageGroup $sd $u.Dir $gh $u.Cat $hw ''
                    for ($k = 0; $k -lt $u.Idx.Count; $k++) {
                        $ix = [int]$u.Idx[$k]
                        $smG.Items[$k]['Idx'] = $ix
                        $smG.Items[$k]['Files'] = $infos[$ix].Files
                        $smG.Items[$k]['Missing'] = $infos[$ix].Missing
                        $smG.Items[$k]['MissingUsed'] = $infos[$ix].MissingUsed
                        if ($c.Pkg) { [void](Add-StageFiles $sd $infos[$ix].Files) }
                    }
                    $map[$sd] = $smG
                    $dirs += $sd
                }
                $global:InfTotal = $dirs.Count; $global:InfDone = 0; $global:InfStart = Get-Date; $global:InfRunning = $false

                # 1. build the catalogs
                $t0 = Get-Date
                $res = @()
                $jobsC = $jobs
                if ($c.Pkg) { $jobsC = [Math]::Max(1, [Math]::Min($jobs, 4)) }
                try { $res = @(Invoke-CatEngine $c.Engine $tools[$c.Engine] $dirs $map $c.WithFiles $osList $jobsC) }
                catch { Write-UiLog ('  engine error: ' + $_.Exception.Message); [void]$detail.Add(('{0}: engine error: {1}' -f $c.Short, $_.Exception.Message)) }
                $secs = ((Get-Date) - $t0).TotalSeconds
                if ($global:StopRequested) {
                    $global:StopRequested = $false
                    $row.Build = 'STOPPED'
                    $row.Accept = 'n/a'
                    Write-UiLog ('  stopped by user after {0} - going on with the next test' -f (Format-Span $secs))
                    [void]$detail.Add(('{0}: stopped by user after {1:N0} s' -f $c.Short, $secs))
                    $global:PlanFrac['test'] = [double]$ci / [double]$combos.Count
                    Update-Progress
                    continue
                }
                $okRes = @($res | Where-Object { $_.ExitCode -eq 0 })
                $row.Build = ('{0:N1} s' -f $secs)
                if ($okRes.Count -lt $dirs.Count) { $row.Build += (' {0}/{1}ok' -f $okRes.Count, $dirs.Count) }
                foreach ($r in $res) {
                    $nm = $map[$r.Dir].Name
                    if ($r.ExitCode -eq 0) { $st = 'ok' } else { $st = ('FAILED (exit {0})' -f $r.ExitCode) }
                    Write-UiLog ('  {0}: {1} ({2:N1} s)' -f $nm, $st, [double]$r.Secs)
                    [void]$detail.Add(('{0} / {1}: {2} in {3:N1} s' -f $c.Short, $nm, $st, [double]$r.Secs))
                    foreach ($line in (([string]$r.Output) -split "`r?`n")) {
                        if ($line.Trim()) {
                            [void]$detail.Add('    ' + $line.Trim())
                            if ($r.ExitCode -ne 0) { Write-UiLog ('    ' + $line.Trim()) }
                        }
                    }
                }

                # 2. sign
                $cats = @()
                foreach ($r in $okRes) {
                    $p = Join-Path $r.Dir $map[$r.Dir].Cat
                    if (Test-Path -LiteralPath $p) { $cats += $p }
                }
                if ($cats.Count -gt 0) {
                    $valid = 0
                    try {
                        [void](Set-AuthenticodeSignature -FilePath $cats -Certificate $cert -HashAlgorithm SHA256 -ErrorAction Stop)
                        foreach ($p in $cats) { if ((Get-AuthenticodeSignature -FilePath $p).Status -eq 'Valid') { $valid++ } }
                    } catch { Write-UiLog ('  signing failed: ' + $_.Exception.Message) }
                    $row.Signed = ('{0}/{1}' -f $valid, $dirs.Count)

                    # 3. signtool verify: does the INF hash match the catalog and is the signature trusted?
                    if ($stool) {
                        $vOk = 0; $vTot = 0
                        foreach ($sdv in $dirs) { $vTot += @($map[$sdv].Items).Count }
                        foreach ($r in $okRes) {
                            $sm = $map[$r.Dir]
                            foreach ($it in @($sm.Items)) {
                                $v = Invoke-Tool $stool ('verify /pa /c "{0}" "{1}"' -f (Join-Path $r.Dir $sm.Cat), (Join-Path $r.Dir $it.Name))
                                if ($v.ExitCode -eq 0) { $vOk++ } else {
                                    Write-UiLog ('  verify FAILED for {0}' -f $it.Name)
                                    foreach ($line in (([string]$v.Output) -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('    ' + $line.Trim()); [void]$detail.Add(('    verify {0}: {1}' -f $it.Name, $line.Trim())) } }
                                }
                            }
                        }
                        $row.Verify = ('{0}/{1}' -f $vOk, $vTot)
                    }

                    # 4. let Windows decide (optional)
                    if ($sel.Pnp -and $c.SkipPnp) {
                        $row.Accept = 'not run (INF-only)'
                        Write-UiLog '    pnputil not run: a catalog with only the INF hash cannot cover the files the INF copies, Windows would show the "can''t verify the publisher" prompt.'
                        [void]$detail.Add(('{0}: pnputil not run - the catalog has only the INF hash; Windows rejects that when the INF copies files (see the "all files" results)' -f $c.Short))
                    } elseif ($sel.Pnp) {
                        $hi = [int]$sel.PnpIndex
                        $infP = $hits[$hi].Name
                        $sdp = $null
                        foreach ($sdx in $dirs) { foreach ($itx in @($map[$sdx].Items)) { if ([int]$itx.Idx -eq $hi) { $sdp = $sdx } } }
                        $built = @()
                        if ($sdp) { $built = @($okRes | Where-Object { $_.Dir -eq $sdp }) }
                        if ($built.Count -eq 0) { $row.Accept = 'n/a (no catalog)' }
                        else {
                            $smP = $map[$sdp]
                            Set-Status ('pnputil test: {0} / {1}' -f $c.Short, $infP)
                            $apDir = Join-Path $stageRoot ('accept_' + $c.Id)
                            $what = New-AcceptPackage $apDir $smP.Dir $sdp $smP $infos[$hi].Files
                            Write-UiLog ('    pnputil package: {0}, plus the new INF(s) and {1}' -f $what, $smP.Cat)
                            $row.Accept = Test-PnpAccept $apDir $infP
                            [void]$detail.Add(('{0} / {1}: pnputil -> {2}  (package: {3})' -f $c.Short, $infP, $row.Accept, $what))
                            foreach ($xl in @($global:LastPnpExcerpt)) { [void]$detail.Add('    ' + $xl) }
                            Remove-Item -LiteralPath $apDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                } elseif ($sel.Pnp) { $row.Accept = 'n/a (no catalog)' }
                Write-UiLog ('  => catalog {0}, signed {1}, verify {2}, Windows {3}' -f $row.Build, $row.Signed, $row.Verify, $row.Accept)
            }
            $global:PlanFrac['test'] = [double]$ci / [double]$combos.Count
            Update-Progress
        }

        # summary table
        $pnpTxt = 'not tested'
        if ($sel.Pnp) { $pnpTxt = $infos[[int]$sel.PnpIndex].Files.Count.ToString() + ' listed files, INF ' + $hits[[int]$sel.PnpIndex].Name }
        $lines = @()
        $lines += ('Engine test - NVIDIA Modded Drivers Signer v{0} - {1}' -f $global:AppVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
        $lines += ('GPU INFs: {0} in {1} folder(s) | OS target: {2} | pnputil: {3}' -f $hits.Count, $hitGroups.Count, $osList, $pnpTxt)
        $lines += ('{0,-20} {1,-16} {2,-6} {3,-6} {4}' -f 'Engine / scope', 'Catalog time', 'Signed', 'Verify', 'Windows (pnputil)')
        foreach ($r in $rows) { $lines += ('{0,-20} {1,-16} {2,-6} {3,-6} {4}' -f $r.Short, $r.Build, $r.Signed, $r.Verify, $r.Accept) }
        Write-UiLog '============================================================'
        foreach ($l in $lines) { Write-UiLog $l }
        Write-UiLog '============================================================'
        $rep = Join-Path $global:WorkDir ('engine_test_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
        try {
            $legend = @('Windows column:',
                '  ACCEPTED         pnputil imported the package AND setupapi.dev.log shows no signature / hash error.',
                '  NOT TRUSTED      Windows found a file whose hash is not in the catalog (it shows the "can''t verify the publisher" prompt;',
                '                   pnputil only returns 0 if you click "Install anyway"). The file is named in the details.',
                '  REJECTED         pnputil failed for another reason; the setupapi.dev.log lines are in the details.',
                '  not run          INF-only catalogs: they hold no file hashes, so Windows rejects them when the INF copies files.')
            Set-Content -LiteralPath $rep -Value ((($lines + '' + $legend + '' + 'Details:' + $detail.ToArray()) -join "`r`n")) -Encoding ASCII
            Write-UiLog ('Report saved: ' + $rep)
        } catch {}
        $global:PlanOk = $true
        [void][System.Windows.Forms.MessageBox]::Show(("Engine test finished.`n`n" + ($lines -join "`n") + "`n`nThe same table is in the log and in:`n" + $rep), $global:AppName, 'OK', 'Information')
    } catch {
        Write-UiLog ('ERROR: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $global:AppName, 'OK', 'Error')
    } finally {
        if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
        End-Plan
        Set-Busy $false
    }
}

# ============================================================================
#  Main action
# ============================================================================
function global:Start-Signing {
    $root = $global:tbDir.Text.Trim().Trim('"')
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('Choose the modded driver folder first.', $global:AppName, 'OK', 'Warning'); return
    }
    $rootFull = (Resolve-Path -LiteralPath $root).Path.TrimEnd('\')
    if ($rootFull.Length -le 3 -or $rootFull -ieq $env:windir -or $rootFull -ieq $env:ProgramFiles -or $rootFull -ieq $env:USERPROFILE) {
        [void][System.Windows.Forms.MessageBox]::Show('That folder is too broad. Pick the extracted driver folder itself.', $global:AppName, 'OK', 'Warning'); return
    }
    $all = $global:chkAll.Checked
    $dev = Get-DevId
    if (-not $all -and -not $dev) {
        [void][System.Windows.Forms.MessageBox]::Show('Enter your GPU device ID (example: DEV_2518) or press Detect.', $global:AppName, 'OK', 'Warning'); return
    }
    $keepOnly = ($global:chkKeep.Checked -and (-not $all))
    $fast = ($global:chkFast.Checked -and (-not $all))
    $jobs = [int]$global:nudJobs.Value
    $eIdx = $global:cbEngine.SelectedIndex
    if ($eIdx -lt 0 -or $eIdx -ge $global:EngineIds.Count) { $eIdx = [array]::IndexOf($global:EngineIds, 'inf2cat') }
    $engine = $global:EngineIds[$eIdx]
    $engineName = $global:EngineNames[$eIdx]
    $custom = ($engine -ne 'inf2cat')
    $withFiles = ($custom -and $global:chkFiles.Checked)
    $scopeTxt = 'INF only'
    if ($withFiles) { $scopeTxt = 'INF + all files of the driver folder' }
    $hwid = ''
    if ($dev) { $hwid = 'pci\ven_10de&dev_' + $dev.ToLower() }
    if ($custom -and $all) {
        [void][System.Windows.Forms.MessageBox]::Show("The $engineName engine only works with the GPU INFs (Fast mode). Turn off ""Sign ALL INF packages"" or choose the Inf2Cat engine.", $global:AppName, 'OK', 'Warning'); return
    }
    if ($custom) { $fast = $true }
    $msg = "Folder:`n$rootFull`n`n"
    $msg += "Catalog engine: $engineName`n`n"
    if ($custom) { $msg += "$engineName is EXPERIMENTAL (catalog scope: $scopeTxt). The catalogs are checked with signtool afterwards, but test one INF with pnputil before trusting them (or use 'Test all engines').`n`n" }
    if ($all) { $msg += "Mode: sign ALL INF packages in this folder ($jobs parallel Inf2Cat jobs).`n`n" }
    else      { $msg += "GPU: VEN_10DE&DEV_$dev`n`n" }
    if ($keepOnly) { $msg += "All other .inf and .cat files will be MOVED to:`n${rootFull}_removed_INF_backup`nOnly the INF containing your GPU is kept and signed.`nNOTE: the NVIDIA setup.exe will NOT work with this option (install with pnputil / Device Manager).`n`n" }
    $msg += 'Continue?'
    if ([System.Windows.Forms.MessageBox]::Show($msg, $global:AppName, 'YesNo', 'Question') -ne 'Yes') { return }

    $stageRoot = $null
    $stageMap = @{}
    Set-Busy $true
    try {
        $needDl = $false
        if ($engine -eq 'makecat') { $needDl = -not (Find-KitTool 'makecat.exe' @('signtool', 'makecat-wdk')) }
        elseif ($engine -eq 'inf2cat') { $needDl = -not (Get-ChildItem -Path (Join-Path $global:ToolsDir 'wdk') -Filter 'Inf2Cat.exe' -ErrorAction SilentlyContinue | Select-Object -First 1) }
        $plan = @{ scan = 6; tools = 0; clean = 0; cert = 6; inf2cat = 60; sign = 8 }
        if ($needDl) { $plan['tools'] = 150 }
        if ($engine -eq 'gencat') { $plan['tools'] = 60 }
        if ($keepOnly) { $plan['clean'] = 4 }
        Start-Plan $plan
        $sw = $global:Sw

        # 1. find the INF file(s)
        Set-Status 'Scanning INF files...'
        if ($all) {
            $hits = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.inf' })
            if ($hits.Count -eq 0) { throw 'No .inf files found in that folder.' }
            Write-UiLog ("Found {0} INF file(s)." -f $hits.Count)
        } else {
            $hits = @(Find-GpuInf $rootFull $dev)
            if ($hits.Count -eq 0) {
                throw "No .inf in that folder contains VEN_10DE&DEV_$dev. Check the device ID (Device Manager > GPU > Details > Hardware Ids) and the folder."
            }
            foreach ($h in $hits) { Write-UiLog "GPU INF: $($h.FullName)" }
        }
        $allDirs = @($hits | ForEach-Object { $_.DirectoryName } | Select-Object -Unique)
        $pkgDirs = @()
        foreach ($d in $allDirs) {
            $nested = $false
            foreach ($o in $allDirs) {
                if ($o -ne $d -and $d.StartsWith($o + '\', [StringComparison]::OrdinalIgnoreCase)) { $nested = $true; break }
            }
            if (-not $nested) { $pkgDirs += $d }
        }
        # Fast mode, Inf2Cat: every matching INF gets its OWN catalog (<name>_nvsigner.cat) and is processed
        # in its own tiny temp package, so Inf2Cat jobs run in parallel.
        # Fast mode, other engines: the INFs of one folder share ONE catalog (<folder>_nvsigner.cat), so the
        # driver files are hashed once. The original shared catalog (e.g. nv_dispi.cat) is never touched and
        # the original INFs are backed up first.
        $realDirs = $pkgDirs
        if ($fast) {
            $stageRoot = Join-Path $env:TEMP ('nvsigner_stage_' + [guid]::NewGuid().ToString('N'))
            $bakDir = Join-Path $global:WorkDir ('inf_backup\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            $stageDirs = @()
            $n = 0
            if ($custom) {
                $fgrp = @{}
                $folders = @()
                foreach ($h in $hits) {
                    $fk = $h.DirectoryName.ToLower()
                    if (-not $fgrp.ContainsKey($fk)) { $fgrp[$fk] = New-Object System.Collections.ArrayList; $folders += $h.DirectoryName }
                    [void]$fgrp[$fk].Add($h)
                }
                foreach ($fd in $folders) {
                    $n++
                    $sd = Join-Path $stageRoot ('g{0:000}' -f $n)
                    $stageMap[$sd] = New-StageGroup $sd $fd @($fgrp[$fd.ToLower()]) (Get-SharedCatName $fd) $hwid (Join-Path $bakDir ('{0:000}' -f $n))
                    $stageDirs += $sd
                }
                $pkgDirs = $stageDirs
                Write-UiLog ("Fast mode: {0} INF(s) in {1} folder(s); one shared catalog per folder (<folder>_nvsigner.cat), so the driver files are hashed once. Original INFs are backed up to: {2}" -f $hits.Count, $pkgDirs.Count, $bakDir)
            } else {
                foreach ($h in $hits) {
                    $n++
                    $sd = Join-Path $stageRoot ('p{0:000}' -f $n)
                    $stageMap[$sd] = New-StageGroup $sd $h.DirectoryName @($h) ($h.BaseName.ToLower() + '_nvsigner.cat') $hwid (Join-Path $bakDir ('{0:000}' -f $n))
                    $stageDirs += $sd
                }
                $pkgDirs = $stageDirs
                Write-UiLog ("Fast mode: {0} INF(s), each with its own catalog (*_nvsigner.cat), run in parallel. Original INFs are backed up to: {1}" -f $hits.Count, $bakDir)
            }
        }
        Write-UiLog ("{0} package folder(s) to process." -f $pkgDirs.Count)

        # target Windows version(s): Inf2Cat checks the INF once per target OS
        $osList = '10_X64,10_RS5_X64,10_19H1_X64,10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64'
        if ($global:chkOS.Checked) {
            $osList = Get-CurrentOsToken
            Write-UiLog "Target OS: only this PC ($osList)"
        } else {
            Write-UiLog 'Target OS: all Windows 10/11 versions (slower)'
        }
        $osCount = @($osList -split ',').Count

        # size of each package -> used for the time estimate
        Set-Status 'Measuring package size...'
        $effJobs = [Math]::Max(1, [Math]::Min($jobs, $pkgDirs.Count))
        $sizes = @()
        foreach ($d in $pkgDirs) {
            $m = Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
            $sizes += [double]($m.Sum / 1MB)
            Do-Events
        }
        $totalMB = [double](($sizes | Measure-Object -Sum).Sum)
        $maxMB = [double](($sizes | Measure-Object -Maximum).Maximum)
        $basisMB = [Math]::Max($maxMB, $totalMB / $effJobs)
        if ($stageMap.Count -gt 0) {
            $tp = Get-StatSpeed 'inf_mbps_per_os' 0.8
            $global:PlanExp['inf2cat'] = ($basisMB * $osCount / $tp) + 3
        } else {
            $tp = Get-StatSpeed 'inf2cat_mbps' 50
            $global:PlanExp['inf2cat'] = ($basisMB / $tp) + 3
        }
        if ($custom) {
            $global:PlanExp['inf2cat'] = 8
            if ($withFiles) { $global:PlanExp['inf2cat'] = 25 }
            if ($engine -eq 'gencat') { $global:PlanExp['inf2cat'] = 20 + $global:PlanExp['inf2cat'] }
        }
        Write-UiLog ("Driver files: {0:N0} MB - estimated catalog time ({1}): ~{2}" -f $totalMB, $engineName, (Format-Span $global:PlanExp['inf2cat']))
        Set-PhaseDone 'scan'

        # 2. tools
        Set-Status 'Preparing tools...'
        $engTool = Prepare-Engine $engine
        $inf2cat = $null
        if ($engine -eq 'inf2cat') { $inf2cat = $engTool }
        Get-ToolsState
        Set-PhaseDone 'tools'

        # 3. keep only the GPU inf
        if ($keepOnly) {
            Set-Status 'Moving other INF packages to backup...'
            $keepNames = @($hits | ForEach-Object { $_.FullName })
            $del = 0
            $bak = $rootFull + '_removed_INF_backup'
            foreach ($f in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue)) {
                $isInf = ($f.Extension -ieq '.inf') -and ($keepNames -notcontains $f.FullName)
                $isCat = ($f.Extension -ieq '.cat') -and ($realDirs -notcontains $f.DirectoryName)
                if ($isInf -or $isCat) {
                    $dst = Join-Path $bak ($f.FullName.Substring($rootFull.Length).TrimStart('\'))
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                    Move-Item -LiteralPath $f.FullName -Destination $dst -Force
                    $del++
                }
            }
            Write-UiLog "Moved $del other .inf/.cat file(s) to: $bak"
        }
        Set-PhaseDone 'clean'

        # 4. certificate
        Set-Status 'Preparing certificate...'
        $cert = Get-SigningCert
        if ($global:chkTrust.Checked) { Install-CertTrust $cert }
        $cer = Join-Path $global:WorkDir 'NvidiaModdedDriversSigner.cer'
        [void](Export-Certificate -Cert $cert -FilePath $cer -Force)
        Write-UiLog "Certificate exported: $cer"
        Set-PhaseDone 'cert'

        # 5. catalogs (Inf2Cat, several packages at the same time)
        $effJobs = [Math]::Max(1, [Math]::Min($jobs, $pkgDirs.Count))
        if ($custom) {
            Write-UiLog ("Running {0} on {1} INF(s) in {2} catalog(s) (experimental, the INF is not parsed; scope: {3})..." -f $engineName, $hits.Count, $pkgDirs.Count, $scopeTxt)
            Set-Status ("Creating catalogs ({0})..." -f $engineName)
        } else {
            Write-UiLog ("Running Inf2Cat ({0} parallel job(s))... this can take a minute" -f $effJobs)
            Set-Status 'Creating catalogs (Inf2Cat)...'
        }
        $t0 = Get-Date
        $global:InfTotal = $pkgDirs.Count; $global:InfDone = 0; $global:InfStart = Get-Date; $global:InfRunning = $true
        $res = @(Invoke-CatEngine $engine $engTool $pkgDirs $stageMap $withFiles $osList $effJobs)
        $global:InfRunning = $false
        if ($global:StopRequested) { Write-UiLog 'Stopped by user. Nothing was changed in the driver folder.'; return }
        Set-PhaseDone 'inf2cat'
        $dur = ((Get-Date) - $t0).TotalSeconds
        if (($stageMap.Count -gt 0) -and (-not $custom)) {
            $failedStage = @($res | Where-Object { $_.ExitCode -ne 0 -and $stageMap.ContainsKey($_.Dir) })
            if ($failedStage.Count -gt 0) {
                foreach ($fs in $failedStage) {
                    foreach ($line in ($fs.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
                }
                Write-UiLog ('Isolated catalog failed for {0} package(s): the INF needs the files it lists. Retrying with the INF plus only those files (hard links, not the whole folder)...' -f $failedStage.Count)
                $retryDirs = @()
                foreach ($fs in $failedStage) {
                    $smR = $stageMap[$fs.Dir]
                    try {
                        $lf = @(Get-InfFiles $smR.InfPath)
                        if ($lf.Count -gt 0) {
                            $mbR = Get-FilesMB $lf
                            $sameVol = ([IO.Path]::GetPathRoot($fs.Dir) -ieq [IO.Path]::GetPathRoot($smR.InfPath))
                            if ($sameVol -or $mbR -le 3000) {
                                Write-UiLog ('  {0}: {1} listed file(s), {2:N0} MB' -f $smR.Name, $lf.Count, $mbR)
                                [void](Add-StageFiles $fs.Dir $lf)
                                $retryDirs += $fs.Dir
                            }
                        }
                    } catch { Write-UiLog ('  could not prepare {0}: {1}' -f $smR.Name, $_.Exception.Message) }
                }
                $res = @($res | Where-Object { -not ($_.ExitCode -ne 0 -and $stageMap.ContainsKey($_.Dir)) })
                $stillFailed = @()
                if ($retryDirs.Count -gt 0) {
                    $rr = @(Invoke-Inf2CatParallel $inf2cat $retryDirs $osList ([Math]::Max(1, [Math]::Min([Math]::Min($jobs, 4), $retryDirs.Count))))
                    $res += @($rr | Where-Object { $_.ExitCode -eq 0 })
                    $stillFailed = @($rr | Where-Object { $_.ExitCode -ne 0 })
                    foreach ($fs in $stillFailed) {
                        foreach ($line in ($fs.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
                    }
                }
                $notRetried = @($failedStage | Where-Object { $retryDirs -notcontains $_.Dir })
                $needFull = @($stillFailed) + @($notRetried)
                if ($needFull.Count -gt 0) {
                    Write-UiLog ('Still failing for {0} package(s). Falling back to the full folder for them - slower.' -f $needFull.Count)
                    $fbDirs = @($needFull | ForEach-Object { $stageMap[$_.Dir].Dir } | Select-Object -Unique)
                    $res += @(Invoke-Inf2CatParallel $inf2cat $fbDirs $osList ([Math]::Max(1, [Math]::Min($jobs, $fbDirs.Count))))
                }
            }
        }
        if ($global:StopRequested) { Write-UiLog 'Stopped by user. Nothing was changed in the driver folder.'; return }
        $okDirs = @()
        foreach ($r in $res) {
            if ($r.ExitCode -eq 0) { $state = 'OK'; $okDirs += $r.Dir } else { $state = "FAILED (exit code $($r.ExitCode))" }
            $lbl = $r.Dir
            if ($stageMap.ContainsKey($r.Dir)) { $lbl = $stageMap[$r.Dir].Name }
            $secTxt = ''
            if ($null -ne $r.Secs) { $secTxt = (' ({0:N1} s)' -f [double]$r.Secs) }
            Write-UiLog ("{0} {1}: {2}{3}" -f $engineName, $state, $lbl, $secTxt)
            foreach ($line in ($r.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
        }
        if ($okDirs.Count -eq $pkgDirs.Count -and $dur -gt 8 -and (-not $custom)) {
            if ($stageMap.Count -eq 0) { Save-StatSpeed 'inf2cat_mbps' ($basisMB / ($dur - 3)) }
            else { Save-StatSpeed 'inf_mbps_per_os' ($basisMB * $osCount / ($dur - 3)) }
        }
        if ($okDirs.Count -eq 0) {
            throw "$engineName failed for every package. See the log above - missing files listed in the INF are the usual cause (Inf2Cat)."
        }
        $failedCount = @($res | Where-Object { $_.ExitCode -ne 0 }).Count
        if ($failedCount -gt 0) {
            Write-UiLog ("WARNING: {0} package(s) failed and were skipped." -f $failedCount)
        }

        # 6. sign all new catalogs in one go
        $cats = @()
        foreach ($d in $okDirs) {
            if ($stageMap.ContainsKey($d)) {
                $sm = $stageMap[$d]
                $newCatPath = Join-Path $d $sm.Cat
                if (-not (Test-Path -LiteralPath $newCatPath)) { Write-UiLog ("  Catalog not created for {0}" -f $sm.Name); continue }
                # back up the original INF(s), then put the INF(s) that point to the new catalog in place
                New-Item -ItemType Directory -Force -Path $sm.BakDir | Out-Null
                foreach ($it in @($sm.Items)) {
                    Copy-Item -LiteralPath $it.InfPath -Destination (Join-Path $sm.BakDir $it.Name) -Force
                    Copy-Item -LiteralPath (Join-Path $d $it.Name) -Destination $it.InfPath -Force
                }
                $target = Join-Path $sm.Dir $sm.Cat
                Copy-Item -LiteralPath $newCatPath -Destination $target -Force
                $cats += Get-Item -LiteralPath $target
            } else {
                $cats += @(Get-ChildItem -LiteralPath $d -Recurse -Filter '*.cat' -File | Where-Object { $_.LastWriteTime -ge $t0.AddSeconds(-10) })
            }
        }
        if ($cats.Count -eq 0) { throw 'Inf2Cat finished but no new .cat file was created.' }
        Write-UiLog ("Signing {0} catalog(s)..." -f $cats.Count)
        Set-Status 'Signing catalogs...'
        $paths = @($cats | ForEach-Object { $_.FullName })
        $needFallback = @()
        try {
            $sigs = @(Set-AuthenticodeSignature -FilePath $paths -Certificate $cert -HashAlgorithm SHA256 -ErrorAction Stop)
            foreach ($sg in $sigs) { if (-not $sg.SignerCertificate) { $needFallback += $sg.Path } }
        } catch {
            Write-UiLog "PowerShell signing failed ($($_.Exception.Message)), trying SignTool..."
            $needFallback = $paths
        }
        if ($needFallback.Count -gt 0) {
            $signtool = Ensure-Tool 'Microsoft.Windows.SDK.BuildTools' 'signtool.exe' 'signtool' '^10\.0\.26100\.\d+$' '/x64/'
            for ($i = 0; $i -lt $needFallback.Count; $i += 15) {
                $last = [Math]::Min($i + 14, $needFallback.Count - 1)
                $argFiles = ($needFallback[$i..$last] | ForEach-Object { '"{0}"' -f $_ }) -join ' '
                $s = Invoke-Tool $signtool ('sign /fd SHA256 /sha1 {0} /sm /s My {1}' -f $cert.Thumbprint, $argFiles)
                foreach ($line in ($s.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
                if ($s.ExitCode -ne 0) { throw 'SignTool failed.' }
            }
        }
        $valid = 0
        foreach ($pth in $paths) {
            $chk = Get-AuthenticodeSignature -FilePath $pth
            if ($chk.Status -eq 'Valid') { $valid++ } else { Write-UiLog ("  {0}: {1}" -f (Split-Path -Leaf $pth), $chk.Status) }
        }
        Write-UiLog ("{0}/{1} catalog(s) signed with status Valid." -f $valid, $paths.Count)
        if ($valid -lt $paths.Count) { Write-UiLog '  (not Valid - enable "Trust certificate" so the root/publisher stores contain it)' }

        if ($custom) {
            Set-Status 'Verifying INF against its catalog (signtool)...'
            $stool = Find-KitTool 'signtool.exe' @('signtool')
            if (-not $stool) { $stool = Ensure-Tool 'Microsoft.Windows.SDK.BuildTools' 'signtool.exe' 'signtool' '^10\.0\.26100\.\d+$' '/x64/' }
            $vOk = 0; $vTot = 0
            foreach ($sd in @($stageMap.Keys)) {
                if ($okDirs -notcontains $sd) { continue }
                $sm = $stageMap[$sd]
                foreach ($it in @($sm.Items)) {
                    $vTot++
                    $v = Invoke-Tool $stool ('verify /pa /c "{0}" "{1}"' -f (Join-Path $sm.Dir $sm.Cat), $it.InfPath)
                    if ($v.ExitCode -eq 0) { $vOk++ } else {
                        Write-UiLog ("  Verify FAILED for {0}:" -f $it.Name)
                        foreach ($line in ($v.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('    ' + $line.Trim()) } }
                    }
                }
            }
            Write-UiLog ("signtool verify: {0}/{1} INF(s) match their catalog." -f $vOk, $vTot)
            if ($vOk -lt $vTot) { Write-UiLog '  WARNING: Windows will probably reject these catalogs. Use the Inf2Cat engine.' }
        }

        Set-PhaseDone 'sign'
        $global:PlanOk = $true
        $sw.Stop()
        Write-UiLog '------------------------------------------------------------'
        Write-UiLog ("DONE in {0} s." -f [int]$sw.Elapsed.TotalSeconds)
        Write-UiLog 'Install the signed driver(s) with:'
        if ($all) { Write-UiLog ('  pnputil /add-driver "{0}\*.inf" /subdirs /install' -f $rootFull) }
        else { foreach ($h in $hits) { Write-UiLog ('  pnputil /add-driver "{0}" /install' -f $h.FullName) } }
        Write-UiLog 'On other PCs, import the .cer above into Trusted Root + Trusted Publishers first.'
        [void][System.Windows.Forms.MessageBox]::Show(("Signing finished: {0}/{1} catalog(s) valid." -f $valid, $paths.Count), $global:AppName, 'OK', 'Information')
    } catch {
        Write-UiLog ('ERROR: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $global:AppName, 'OK', 'Error')
    } finally {
        if ($stageRoot -and (Test-Path -LiteralPath $stageRoot)) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
        End-Plan
        Set-Busy $false
    }
}

# ============================================================================
#  GUI
# ============================================================================
$bg     = [Drawing.Color]::FromArgb(30, 30, 33)
$panel  = [Drawing.Color]::FromArgb(45, 45, 50)
$fg     = [Drawing.Color]::FromArgb(235, 235, 235)
$dim    = [Drawing.Color]::FromArgb(160, 160, 165)
$green  = [Drawing.Color]::FromArgb(118, 185, 0)
$font   = New-Object Drawing.Font('Segoe UI', 9)

function global:New-Label($text, $x, $y, $w, $h) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, $h)
    $l.ForeColor = $fg; $l.BackColor = [Drawing.Color]::Transparent
    return $l
}
function global:New-Button($text, $x, $y, $w, $h, $accent) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0; $b.Cursor = 'Hand'
    if ($accent) { $b.BackColor = $green; $b.ForeColor = [Drawing.Color]::Black; $b.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold) }
    else { $b.BackColor = [Drawing.Color]::FromArgb(70, 70, 76); $b.ForeColor = $fg }
    return $b
}

$form = New-Object Windows.Forms.Form
$form.Text = "$($global:AppName) v$($global:AppVersion)"
$form.Size = New-Object Drawing.Size(800, 700)
$form.MinimumSize = New-Object Drawing.Size(720, 600)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = $font

$title = New-Label $global:AppName 20 12 600 32
$title.Font = New-Object Drawing.Font('Segoe UI', 17, [Drawing.FontStyle]::Bold); $title.ForeColor = $green
$form.Controls.Add($title)
$form.Controls.Add((New-Label "v$($global:AppVersion)  -  re-sign NVCleanstall-modded NVIDIA driver INF (GPU INF only)" 22 48 700 20))
$form.Controls[$form.Controls.Count - 1].ForeColor = $dim

# folder
$form.Controls.Add((New-Label 'Modded driver folder (drop a folder here too)' 20 82 400 20))
$global:tbDir = New-Object Windows.Forms.TextBox
$global:tbDir.Location = New-Object Drawing.Point(20, 104); $global:tbDir.Size = New-Object Drawing.Size(630, 26)
$global:tbDir.Anchor = 'Top,Left,Right'; $global:tbDir.BackColor = $panel; $global:tbDir.ForeColor = $fg; $global:tbDir.BorderStyle = 'FixedSingle'
$global:tbDir.AllowDrop = $true
$global:tbDir.Add_DragEnter({ param($s, $e) if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $e.Effect = 'Copy' } })
$global:tbDir.Add_DragDrop({ param($s, $e)
    $p = ($e.Data.GetData([Windows.Forms.DataFormats]::FileDrop))[0]
    if (Test-Path -LiteralPath $p -PathType Leaf) { $p = Split-Path -Parent $p }
    $global:tbDir.Text = $p })
$form.Controls.Add($global:tbDir)
$global:btnBrowse = New-Button 'Browse...' 660 102 110 28 $false
$global:btnBrowse.Anchor = 'Top,Right'
$global:btnBrowse.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = 'Select the extracted modded NVIDIA driver folder'
    $d.ShowNewFolderButton = $false
    if ($d.ShowDialog() -eq 'OK') { $global:tbDir.Text = $d.SelectedPath }
})
$form.Controls.Add($global:btnBrowse)

# gpu
$form.Controls.Add((New-Label 'Your GPU (device ID, e.g. DEV_2518)' 20 142 400 20))
$global:cbGpu = New-Object Windows.Forms.ComboBox
$global:cbGpu.Location = New-Object Drawing.Point(20, 164); $global:cbGpu.Size = New-Object Drawing.Size(630, 26)
$global:cbGpu.Anchor = 'Top,Left,Right'; $global:cbGpu.DropDownStyle = 'DropDown'
$global:cbGpu.BackColor = $panel; $global:cbGpu.ForeColor = $fg; $global:cbGpu.FlatStyle = 'Flat'
$form.Controls.Add($global:cbGpu)
$global:btnDetect = New-Button 'Detect GPU' 660 162 110 28 $false
$global:btnDetect.Anchor = 'Top,Right'
$global:btnDetect.Add_Click({
    $global:cbGpu.Items.Clear()
    $g = @(Get-NvGpus)
    if ($g.Count -eq 0) { Write-UiLog 'No NVIDIA GPU detected - type the device ID manually.'; return }
    foreach ($x in $g) { [void]$global:cbGpu.Items.Add($x) }
    $global:cbGpu.SelectedIndex = 0
    Write-UiLog ("Detected: " + ($g -join ' | '))
})
$form.Controls.Add($global:btnDetect)

# options
$global:chkFast = New-Object Windows.Forms.CheckBox
$global:chkFast.Text = 'Fast: only the GPU INFs, in tiny temp packages (much faster)'
$global:chkFast.Location = New-Object Drawing.Point(20, 198); $global:chkFast.Size = New-Object Drawing.Size(470, 22)
$global:chkFast.Checked = $true; $global:chkFast.ForeColor = $fg
$form.Controls.Add($global:chkFast)
$global:chkOS = New-Object Windows.Forms.CheckBox
$global:chkOS.Text = "Target only this PC's Windows version (much faster)"
$global:chkOS.Location = New-Object Drawing.Point(20, 264); $global:chkOS.Size = New-Object Drawing.Size(470, 22)
$global:chkOS.Checked = $true; $global:chkOS.ForeColor = $fg
$form.Controls.Add($global:chkOS)
$lblEng = New-Label 'Catalog engine:' 500 250 270 16
$lblEng.Anchor = 'Top,Right'
$form.Controls.Add($lblEng)
$global:cbEngine = New-Object Windows.Forms.ComboBox
$global:cbEngine.Location = New-Object Drawing.Point(500, 266); $global:cbEngine.Size = New-Object Drawing.Size(270, 22)
$global:cbEngine.Anchor = 'Top,Right'; $global:cbEngine.DropDownStyle = 'DropDownList'
$global:cbEngine.BackColor = $panel; $global:cbEngine.ForeColor = $fg; $global:cbEngine.FlatStyle = 'Flat'
[void]$global:cbEngine.Items.Add('MakeCat (experimental)')
[void]$global:cbEngine.Items.Add('libwdi-style, native (experimental)')
[void]$global:cbEngine.Items.Add('generate-cat-file via WSL (experimental)')
[void]$global:cbEngine.Items.Add('Inf2Cat (standard)')
# the standard, proven engine stays the default selection
$global:cbEngine.SelectedIndex = [array]::IndexOf($global:EngineIds, 'inf2cat')
$form.Controls.Add($global:cbEngine)
$global:chkKeep = New-Object Windows.Forms.CheckBox
$global:chkKeep.Text = 'Keep only my GPU INF (others moved to backup; no setup.exe)'
$global:chkKeep.Location = New-Object Drawing.Point(20, 220); $global:chkKeep.Size = New-Object Drawing.Size(470, 22)
$global:chkKeep.Checked = $false; $global:chkKeep.ForeColor = $fg
$form.Controls.Add($global:chkKeep)
$global:chkTrust = New-Object Windows.Forms.CheckBox
$global:chkTrust.Text = 'Trust certificate on this PC (Trusted Root + Trusted Publishers)'
$global:chkTrust.Location = New-Object Drawing.Point(20, 242); $global:chkTrust.Size = New-Object Drawing.Size(470, 22)
$global:chkTrust.Checked = $true; $global:chkTrust.ForeColor = $fg
$form.Controls.Add($global:chkTrust)
$global:chkAll = New-Object Windows.Forms.CheckBox
$global:chkAll.Text = 'Sign ALL INF packages (parallel)'
$global:chkAll.Location = New-Object Drawing.Point(500, 198); $global:chkAll.Size = New-Object Drawing.Size(270, 22)
$global:chkAll.Anchor = 'Top,Right'; $global:chkAll.ForeColor = $fg
$global:chkAll.Add_CheckedChanged({
    if ($global:chkAll.Checked) { $global:chkKeep.Checked = $false; $global:chkKeep.Enabled = $false; $global:chkFast.Enabled = $false }
    else { $global:chkKeep.Enabled = $true; $global:chkFast.Enabled = $true }
})
$form.Controls.Add($global:chkAll)
$lblJobs = New-Label 'Parallel jobs:' 500 227 90 20
$lblJobs.Anchor = 'Top,Right'
$form.Controls.Add($lblJobs)
$global:nudJobs = New-Object Windows.Forms.NumericUpDown
$global:nudJobs.Location = New-Object Drawing.Point(595, 224); $global:nudJobs.Size = New-Object Drawing.Size(60, 24)
$global:nudJobs.Anchor = 'Top,Right'; $global:nudJobs.Minimum = 1; $global:nudJobs.Maximum = 8
$global:nudJobs.Value = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount))
$global:nudJobs.BackColor = $panel; $global:nudJobs.ForeColor = $fg
$form.Controls.Add($global:nudJobs)

# tools
$global:lblTools = New-Label '' 20 294 470 20
$form.Controls.Add($global:lblTools)
$global:chkFiles = New-Object Windows.Forms.CheckBox
$global:chkFiles.Text = 'Hash all driver files'
$global:chkFiles.Location = New-Object Drawing.Point(500, 292); $global:chkFiles.Size = New-Object Drawing.Size(155, 22)
$global:chkFiles.Anchor = 'Top,Right'; $global:chkFiles.Checked = $true; $global:chkFiles.ForeColor = $fg
$form.Controls.Add($global:chkFiles)
$global:tt = New-Object Windows.Forms.ToolTip
$global:tt.SetToolTip($global:chkFiles, 'MakeCat / libwdi-style / generate-cat-file only: the shared catalog also gets the hash of every file of the driver folder (the files the INFs list and the ones copied as whole directories, e.g. ngx-builtins). Each file is hashed once. Windows checks every file it copies against the catalog; one missing hash and it shows the "can''t verify the publisher" prompt. Off = INF hash only (faster, but Windows rejects it when the INF copies files).')
$global:tt.SetToolTip($global:cbEngine, 'Inf2Cat is the standard Microsoft tool. The other engines are experimental alternatives that do not parse the INF. Use "Test all engines" to compare them on your files.')
$global:btnTools = New-Button 'Download tools' 660 288 110 28 $false
$global:btnTools.Anchor = 'Top,Right'
$global:btnTools.Add_Click({
    Set-Busy $true
    try {
        Start-Plan @{ tools = 150 }
        [void](Ensure-Tool 'Microsoft.Windows.WDK.x64' 'Inf2Cat.exe' 'wdk' '^10\.0\.26100\.\d+$' '/x86/')
        Get-ToolsState
        Set-PhaseDone 'tools'
        $global:PlanOk = $true
    }
    catch { Write-UiLog ('ERROR: ' + $_.Exception.Message) }
    finally { End-Plan; Set-Busy $false }
})
$form.Controls.Add($global:btnTools)

# progress + status
$global:pb = New-Object Windows.Forms.ProgressBar
$global:pb.Location = New-Object Drawing.Point(20, 322); $global:pb.Size = New-Object Drawing.Size(750, 14)
$global:pb.Anchor = 'Top,Left,Right'
$form.Controls.Add($global:pb)
$global:lblStatus = New-Label 'Ready.' 20 340 440 20
$global:lblStatus.Anchor = 'Top,Left'; $global:lblStatus.ForeColor = $dim
$form.Controls.Add($global:lblStatus)
$global:lblTimer = New-Label 'Elapsed 00:00:00   ETA --:--:--' 440 340 330 20
$global:lblTimer.Anchor = 'Top,Right'; $global:lblTimer.TextAlign = 'MiddleRight'; $global:lblTimer.ForeColor = $green
$global:lblTimer.Font = New-Object Drawing.Font('Consolas', 9, [Drawing.FontStyle]::Bold)
$form.Controls.Add($global:lblTimer)
$global:uiTimer = New-Object Windows.Forms.Timer
$global:uiTimer.Interval = 500
$global:uiTimer.Add_Tick({ Update-Progress })

# log
$global:tbLog = New-Object Windows.Forms.TextBox
$global:tbLog.Location = New-Object Drawing.Point(20, 366); $global:tbLog.Size = New-Object Drawing.Size(750, 226)
$global:tbLog.Anchor = 'Top,Bottom,Left,Right'; $global:tbLog.Multiline = $true; $global:tbLog.ReadOnly = $true
$global:tbLog.ScrollBars = 'Vertical'; $global:tbLog.BackColor = [Drawing.Color]::FromArgb(20, 20, 22); $global:tbLog.ForeColor = [Drawing.Color]::FromArgb(200, 230, 160)
$global:tbLog.Font = New-Object Drawing.Font('Consolas', 9); $global:tbLog.BorderStyle = 'FixedSingle'
$form.Controls.Add($global:tbLog)

# bottom buttons
$global:btnStart = New-Button 'SIGN DRIVER' 20 608 200 40 $true
$global:btnStart.Anchor = 'Bottom,Left'
$global:btnStart.Add_Click({ Start-Signing })
$form.Controls.Add($global:btnStart)
$btnOpen = New-Button 'Open folder' 230 612 120 32 $false
$btnOpen.Anchor = 'Bottom,Left'
$btnOpen.Add_Click({ if ($global:tbDir.Text -and (Test-Path -LiteralPath $global:tbDir.Text)) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $global:tbDir.Text) } })
$form.Controls.Add($btnOpen)
$global:btnTest = New-Button 'Test all engines...' 360 612 170 32 $false
$global:btnTest.Anchor = 'Bottom,Left'
$global:btnTest.Add_Click({ Start-EngineTest })
$form.Controls.Add($global:btnTest)
$global:btnStop = New-Button 'Stop step' 540 612 110 32 $false
$global:btnStop.Anchor = 'Bottom,Left'
$global:btnStop.Enabled = $false
$global:btnStop.Add_Click({ $global:StopRequested = $true; Write-UiLog 'Stop requested - stopping the current step...' })
$form.Controls.Add($global:btnStop)
$btnExit = New-Button 'Exit' 660 612 110 32 $false
$btnExit.Anchor = 'Bottom,Right'
$btnExit.Add_Click({ $form.Close() })
$form.Controls.Add($btnExit)

$form.Add_Shown({
    Write-UiLog "$($global:AppName) v$($global:AppVersion)"
    Write-UiLog 'Tip: point it at the folder NVCleanstall produced (the one with Display.Driver\nv_dispi.inf).'
    Get-ToolsState
    $global:btnDetect.PerformClick()
    Set-Marquee $false
})

[void]$form.ShowDialog()
