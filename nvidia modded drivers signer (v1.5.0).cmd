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
#    3. creates a new .cat catalog for the INF
#    4. signs the .cat with a local self-signed certificate and trusts it
# ============================================================================
$ErrorActionPreference = 'Stop'
$global:AppVersion  = '1.5.0'
$global:AppName     = 'NVIDIA Modded Drivers Signer'
$global:CertSubject = 'CN=NVIDIA Modded Drivers Signer'
$global:WorkDir     = Join-Path $env:ProgramData 'NvidiaModdedDriversSigner'
$global:ToolsDir    = Join-Path $global:WorkDir 'tools'
$global:UA          = 'NvidiaModdedDriversSigner/' + $global:AppVersion

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
    foreach ($c in @($global:btnStart, $global:btnBrowse, $global:btnDetect, $global:btnTools, $global:tbDir, $global:cbGpu, $global:chkKeep, $global:chkTrust, $global:chkAll, $global:nudJobs, $global:chkFast, $global:chkOS)) { $c.Enabled = (-not $busy) }
    if (-not $busy -and $global:chkAll.Checked) { $global:chkKeep.Enabled = $false; $global:chkFast.Enabled = $false }
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
            $running += [pscustomobject]@{ Proc = $p; Dir = $d; Log = $log }
            Write-UiLog "Inf2Cat started: $d"
        }
        Do-Events
        Start-Sleep -Milliseconds 150
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
                $results += [pscustomobject]@{ Dir = $j.Dir; ExitCode = $j.Proc.ExitCode; Output = $out }
                $done++
                $global:InfDone = $done
                Set-Status ('Inf2Cat: {0} / {1} package(s) done' -f $done, $total)
            } else { $still += $j }
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
    $msg = "Folder:`n$rootFull`n`n"
    if ($all) { $msg += "Mode: sign ALL INF packages in this folder ($jobs parallel Inf2Cat jobs).`n`n" }
    else      { $msg += "GPU: VEN_10DE&DEV_$dev`n`n" }
    if ($keepOnly) { $msg += "All other .inf and .cat files will be MOVED to:`n${rootFull}_removed_INF_backup`nOnly the INF containing your GPU is kept and signed.`nNOTE: the NVIDIA setup.exe will NOT work with this option (install with pnputil / Device Manager).`n`n" }
    $msg += 'Continue?'
    if ([System.Windows.Forms.MessageBox]::Show($msg, $global:AppName, 'YesNo', 'Question') -ne 'Yes') { return }

    $stageRoot = $null
    $stageMap = @{}
    Set-Busy $true
    try {
        $needDl = -not (Get-ChildItem -Path (Join-Path $global:ToolsDir 'wdk') -Filter 'Inf2Cat.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
        $plan = @{ scan = 6; tools = 0; clean = 0; cert = 6; inf2cat = 60; sign = 8 }
        if ($needDl) { $plan['tools'] = 150 }
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
        # Fast mode: every matching INF gets its OWN catalog (<name>_nvsigner.cat) and is processed
        # in its own tiny temp package, so Inf2Cat jobs run in parallel and the original shared
        # catalog (e.g. nv_dispi.cat) is never touched. The original INFs are backed up first.
        $realDirs = $pkgDirs
        if ($fast) {
            $stageRoot = Join-Path $env:TEMP ('nvsigner_stage_' + [guid]::NewGuid().ToString('N'))
            $bakDir = Join-Path $global:WorkDir ('inf_backup\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            $stageDirs = @()
            $n = 0
            foreach ($h in $hits) {
                $n++
                $sd = Join-Path $stageRoot ('p{0:000}' -f $n)
                New-Item -ItemType Directory -Force -Path $sd | Out-Null
                $newCat = $h.BaseName.ToLower() + '_nvsigner.cat'
                Set-InfCatalogName $h.FullName (Join-Path $sd $h.Name) $newCat
                $stageMap[$sd] = @{ Dir = $h.DirectoryName; InfPath = $h.FullName; Name = $h.Name; Cat = $newCat; BakDir = (Join-Path $bakDir ('{0:000}' -f $n)) }
                $stageDirs += $sd
            }
            $pkgDirs = $stageDirs
            Write-UiLog ("Fast mode: {0} INF(s), each with its own catalog (*_nvsigner.cat), run in parallel. Original INFs are backed up to: {1}" -f $hits.Count, $bakDir)
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
        Write-UiLog ("Driver files: {0:N0} MB - estimated Inf2Cat time: ~{1}" -f $totalMB, (Format-Span $global:PlanExp['inf2cat']))
        Set-PhaseDone 'scan'

        # 2. tools
        Set-Status 'Preparing tools...'
        $inf2cat = Ensure-Tool 'Microsoft.Windows.WDK.x64' 'Inf2Cat.exe' 'wdk' '^10\.0\.26100\.\d+$' '/x86/'
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
        Write-UiLog ("Running Inf2Cat ({0} parallel job(s))... this can take a minute" -f $effJobs)
        Set-Status 'Creating catalogs (Inf2Cat)...'
        $t0 = Get-Date
        $global:InfTotal = $pkgDirs.Count; $global:InfDone = 0; $global:InfStart = Get-Date; $global:InfRunning = $true
        $res = @(Invoke-Inf2CatParallel $inf2cat $pkgDirs $osList $effJobs)
        $global:InfRunning = $false
        Set-PhaseDone 'inf2cat'
        $dur = ((Get-Date) - $t0).TotalSeconds
        if ($stageMap.Count -gt 0) {
            $failedStage = @($res | Where-Object { $_.ExitCode -ne 0 -and $stageMap.ContainsKey($_.Dir) })
            if ($failedStage.Count -gt 0) {
                foreach ($fs in $failedStage) {
                    foreach ($line in ($fs.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
                }
                Write-UiLog ('Isolated catalog failed for {0} package(s) (they need other driver files). Falling back to the full folder for them - slower.' -f $failedStage.Count)
                $fbDirs = @($failedStage | ForEach-Object { $stageMap[$_.Dir].Dir } | Select-Object -Unique)
                $res = @($res | Where-Object { -not ($_.ExitCode -ne 0 -and $stageMap.ContainsKey($_.Dir)) })
                $res += @(Invoke-Inf2CatParallel $inf2cat $fbDirs $osList ([Math]::Max(1, [Math]::Min($jobs, $fbDirs.Count))))
            }
        }
        $okDirs = @()
        foreach ($r in $res) {
            if ($r.ExitCode -eq 0) { $state = 'OK'; $okDirs += $r.Dir } else { $state = "FAILED (exit code $($r.ExitCode))" }
            Write-UiLog ("Inf2Cat {0}: {1}" -f $state, $r.Dir)
            foreach ($line in ($r.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
        }
        if ($okDirs.Count -eq $pkgDirs.Count -and $dur -gt 8) {
            if ($stageMap.Count -eq 0) { Save-StatSpeed 'inf2cat_mbps' ($basisMB / ($dur - 3)) }
            else { Save-StatSpeed 'inf_mbps_per_os' ($basisMB * $osCount / ($dur - 3)) }
        }
        if ($okDirs.Count -eq 0) {
            throw 'Inf2Cat failed for every package. See the log above - missing files listed in the INF are the usual cause.'
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
                # back up the original INF, then put the INF that points to its own catalog in place
                New-Item -ItemType Directory -Force -Path $sm.BakDir | Out-Null
                Copy-Item -LiteralPath $sm.InfPath -Destination (Join-Path $sm.BakDir $sm.Name) -Force
                Copy-Item -LiteralPath (Join-Path $d $sm.Name) -Destination $sm.InfPath -Force
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
$global:chkFast.Text = 'Fast: own catalog per GPU INF, in parallel (much faster)'
$global:chkFast.Location = New-Object Drawing.Point(20, 198); $global:chkFast.Size = New-Object Drawing.Size(470, 22)
$global:chkFast.Checked = $true; $global:chkFast.ForeColor = $fg
$form.Controls.Add($global:chkFast)
$global:chkOS = New-Object Windows.Forms.CheckBox
$global:chkOS.Text = "Target only this PC's Windows version (much faster)"
$global:chkOS.Location = New-Object Drawing.Point(20, 264); $global:chkOS.Size = New-Object Drawing.Size(470, 22)
$global:chkOS.Checked = $true; $global:chkOS.ForeColor = $fg
$form.Controls.Add($global:chkOS)
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
$global:lblTools = New-Label '' 20 294 560 20
$form.Controls.Add($global:lblTools)
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
