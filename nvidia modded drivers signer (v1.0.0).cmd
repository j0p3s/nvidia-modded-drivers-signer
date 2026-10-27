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
$global:AppVersion  = '1.0.0'
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
    foreach ($c in @($global:btnStart, $global:btnBrowse, $global:btnDetect, $global:btnTools, $global:tbDir, $global:cbGpu, $global:chkKeep, $global:chkTrust)) { $c.Enabled = (-not $busy) }
    Set-Marquee $busy
    if (-not $busy) { Set-Status 'Ready.' }
}

function global:Download-File($url, $dest) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = $global:UA
    $req.AllowAutoRedirect = $true
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($dest)
    try {
        $global:pb.Style = 'Continuous'; $global:pb.Value = 0
        $buf = New-Object byte[] 262144
        $got = 0L
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $got += $n
            if ($total -gt 0) {
                $global:pb.Value = [int](100 * $got / $total)
                Set-Status ('Downloading... {0:N1} / {1:N1} MB' -f ($got / 1MB), ($total / 1MB))
            } else {
                Set-Status ('Downloading... {0:N1} MB' -f ($got / 1MB))
            }
            Do-Events
        }
    } finally {
        $out.Close(); $in.Close(); $resp.Close()
        $global:pb.Value = 0
        $global:pb.Style = 'Marquee'
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
    $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
    try {
        $cands = @($zip.Entries | Where-Object { $_.Name -ieq $exe })
        $e = $cands | Where-Object { $_.FullName -match $pathHint } | Select-Object -First 1
        if (-not $e) { $e = $cands | Select-Object -First 1 }
        if (-not $e) { throw "$exe not found inside $id package" }
        $prefix = $e.FullName.Substring(0, $e.FullName.Length - $e.Name.Length)
        foreach ($x in $zip.Entries) {
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
    $dev = Get-DevId
    if (-not $dev) {
        [void][System.Windows.Forms.MessageBox]::Show('Enter your GPU device ID (example: DEV_2518) or press Detect.', $global:AppName, 'OK', 'Warning'); return
    }
    $keepOnly = $global:chkKeep.Checked
    $msg = "Folder:`n$rootFull`n`nGPU: VEN_10DE&DEV_$dev`n`n"
    if ($keepOnly) { $msg += "All other .inf files (and their .cat files) in this folder will be DELETED.`nOnly the INF containing your GPU is kept and signed.`n`n" }
    $msg += 'Continue?'
    if ([System.Windows.Forms.MessageBox]::Show($msg, $global:AppName, 'YesNo', 'Question') -ne 'Yes') { return }

    Set-Busy $true
    try {
        # 1. find the GPU inf
        Set-Status 'Scanning INF files...'
        $hits = @(Find-GpuInf $rootFull $dev)
        if ($hits.Count -eq 0) {
            throw "No .inf in that folder contains VEN_10DE&DEV_$dev. Check the device ID (Device Manager > GPU > Details > Hardware Ids) and the folder."
        }
        foreach ($h in $hits) { Write-UiLog "GPU INF: $($h.FullName)" }
        $gpuDirs = @($hits | ForEach-Object { $_.DirectoryName } | Select-Object -Unique)

        # 2. tools
        Set-Status 'Preparing tools...'
        $inf2cat = Ensure-Tool 'Microsoft.Windows.WDK.x64' 'Inf2Cat.exe' 'wdk' '^10\.0\.26100\.\d+$' '/x86/'
        Get-ToolsState

        # 3. keep only the GPU inf
        if ($keepOnly) {
            Set-Status 'Removing other INF packages...'
            $keepNames = @($hits | ForEach-Object { $_.FullName })
            $del = 0
            foreach ($f in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue)) {
                $isInf = ($f.Extension -ieq '.inf') -and ($keepNames -notcontains $f.FullName)
                $isCat = ($f.Extension -ieq '.cat') -and ($gpuDirs -notcontains $f.DirectoryName)
                if ($isInf -or $isCat) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    $del++
                }
            }
            Write-UiLog "Removed $del other .inf/.cat file(s)."
        }

        # 4. certificate
        Set-Status 'Preparing certificate...'
        $cert = Get-SigningCert
        if ($global:chkTrust.Checked) { Install-CertTrust $cert }
        $cer = Join-Path $global:WorkDir 'NvidiaModdedDriversSigner.cer'
        [void](Export-Certificate -Cert $cert -FilePath $cer -Force)
        Write-UiLog "Certificate exported: $cer"

        # 5. catalog + signature for each GPU package folder
        $osList = '10_X64,10_RS5_X64,10_19H1_X64,10_VB_X64,10_CO_X64,10_NI_X64,10_GE_X64'
        $signedInf = @()
        foreach ($dir in $gpuDirs) {
            Set-Status 'Creating catalog (Inf2Cat)... this can take a minute'
            Write-UiLog "Inf2Cat: $dir"
            $r = Invoke-Tool $inf2cat ('/driver:"{0}" /os:{1} /uselocaltime' -f $dir, $osList)
            foreach ($line in ($r.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
            if ($r.ExitCode -ne 0) {
                throw "Inf2Cat failed (exit code $($r.ExitCode)). See the log above - missing files listed in the INF are the usual cause."
            }

            $cats = @(Get-ChildItem -LiteralPath $dir -Filter '*.cat' -File | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) })
            if ($cats.Count -eq 0) { throw "Inf2Cat finished but no new .cat file was created in $dir" }

            foreach ($cat in $cats) {
                Set-Status "Signing $($cat.Name) ..."
                $ok = $false
                try {
                    $sig = Set-AuthenticodeSignature -FilePath $cat.FullName -Certificate $cert -HashAlgorithm SHA256 -ErrorAction Stop
                    if ($sig.SignerCertificate) { $ok = $true }
                } catch { Write-UiLog "PowerShell signing failed ($($_.Exception.Message)), trying SignTool..." }
                if (-not $ok) {
                    $signtool = Ensure-Tool 'Microsoft.Windows.SDK.BuildTools' 'signtool.exe' 'signtool' '^10\.0\.26100\.\d+$' '/x64/'
                    $s = Invoke-Tool $signtool ('sign /fd SHA256 /sha1 {0} /sm /s My "{1}"' -f $cert.Thumbprint, $cat.FullName)
                    foreach ($line in ($s.Output -split "`r?`n")) { if ($line.Trim()) { Write-UiLog ('  ' + $line.Trim()) } }
                    if ($s.ExitCode -ne 0) { throw "SignTool failed for $($cat.Name)" }
                }
                $chk = Get-AuthenticodeSignature -FilePath $cat.FullName
                Write-UiLog ("Signed {0} - status: {1}" -f $cat.Name, $chk.Status)
                if ($chk.Status -ne 'Valid') { Write-UiLog '  (status is not Valid - enable "Trust certificate" so the root/publisher stores contain it)' }
            }
        }
        foreach ($h in $hits) { $signedInf += $h.FullName }

        Write-UiLog '------------------------------------------------------------'
        Write-UiLog 'DONE. Install the signed driver with:'
        foreach ($i in $signedInf) { Write-UiLog ('  pnputil /add-driver "{0}" /install' -f $i) }
        Write-UiLog 'On other PCs, import the .cer above into Trusted Root + Trusted Publishers first.'
        [void][System.Windows.Forms.MessageBox]::Show("Signing finished.`n`nSigned INF:`n" + ($signedInf -join "`n"), $global:AppName, 'OK', 'Information')
    } catch {
        Write-UiLog ('ERROR: ' + $_.Exception.Message)
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, $global:AppName, 'OK', 'Error')
    } finally {
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
$global:chkKeep = New-Object Windows.Forms.CheckBox
$global:chkKeep.Text = 'Keep only my GPU INF (delete all other .inf / .cat files - faster)'
$global:chkKeep.Location = New-Object Drawing.Point(20, 204); $global:chkKeep.Size = New-Object Drawing.Size(600, 22)
$global:chkKeep.Checked = $true; $global:chkKeep.ForeColor = $fg
$form.Controls.Add($global:chkKeep)
$global:chkTrust = New-Object Windows.Forms.CheckBox
$global:chkTrust.Text = 'Trust certificate on this PC (Trusted Root + Trusted Publishers)'
$global:chkTrust.Location = New-Object Drawing.Point(20, 230); $global:chkTrust.Size = New-Object Drawing.Size(600, 22)
$global:chkTrust.Checked = $true; $global:chkTrust.ForeColor = $fg
$form.Controls.Add($global:chkTrust)

# tools
$global:lblTools = New-Label '' 20 264 560 20
$form.Controls.Add($global:lblTools)
$global:btnTools = New-Button 'Download tools' 660 258 110 28 $false
$global:btnTools.Anchor = 'Top,Right'
$global:btnTools.Add_Click({
    Set-Busy $true
    try { [void](Ensure-Tool 'Microsoft.Windows.WDK.x64' 'Inf2Cat.exe' 'wdk' '^10\.0\.26100\.\d+$' '/x86/'); Get-ToolsState }
    catch { Write-UiLog ('ERROR: ' + $_.Exception.Message) }
    finally { Set-Busy $false }
})
$form.Controls.Add($global:btnTools)

# progress + status
$global:pb = New-Object Windows.Forms.ProgressBar
$global:pb.Location = New-Object Drawing.Point(20, 298); $global:pb.Size = New-Object Drawing.Size(750, 14)
$global:pb.Anchor = 'Top,Left,Right'
$form.Controls.Add($global:pb)
$global:lblStatus = New-Label 'Ready.' 20 316 750 20
$global:lblStatus.Anchor = 'Top,Left,Right'; $global:lblStatus.ForeColor = $dim
$form.Controls.Add($global:lblStatus)

# log
$global:tbLog = New-Object Windows.Forms.TextBox
$global:tbLog.Location = New-Object Drawing.Point(20, 342); $global:tbLog.Size = New-Object Drawing.Size(750, 250)
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
