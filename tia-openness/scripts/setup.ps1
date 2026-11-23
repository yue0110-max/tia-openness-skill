# setup.ps1 - one-time setup of the TIA Portal Openness bridge for DSH
# ASCII only: Windows PowerShell 5.1 decodes BOM-less UTF-8 scripts as ANSI.
#
# What it does:
#   1. detects the installed TIA Portal Openness version (highest wins)
#   2. creates a staging folder, copies the Openness assemblies and compiles TiaOpen.exe
#   3. creates a dedicated local user and puts it in the "Siemens TIA Openness" group
#   4. whitelists TiaOpen.exe in the Openness firewall registry
#   5. writes config.json and runs a self test (info)
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File setup.ps1
#   powershell.exe ... -File setup.ps1 -DataDir C:\ProgramData\TiaOpenness -User TiaOpenness
param(
    [string]$DataDir = "C:\ProgramData\TiaOpenness",
    [string]$User = "TiaOpenness",
    [string]$Password = "",
    [string]$GroupName = "Siemens TIA Openness",
    [switch]$SkipSelfTest,
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$logFile = Join-Path $env:TEMP "tia-openness-setup.log"

function W([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated -and -not $Elevated) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -DataDir "{1}" -User "{2}" -Elevated' -f $PSCommandPath, $DataDir, $User
    if ($Password) { $argLine += (' -Password "{0}"' -f $Password) }
    Write-Host "not elevated: relaunching elevated (UAC). log: $logFile"
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden | Out-Null
    exit 0
}

W "--- setup start (elevated=True) ---"
W ("data dir : {0}" -f $DataDir)
W ("user     : {0}\{1}" -f $env:COMPUTERNAME, $User)

# ---------- 1. detect Openness ----------
function Get-OpennessInfo {
    $bases = @(
        "HKLM:\SOFTWARE\Siemens\Automation\Openness",
        "HKLM:\SOFTWARE\WOW6432Node\Siemens\Automation\Openness"
    )
    $found = @()
    foreach ($b in $bases) {
        if (-not (Test-Path $b)) { continue }
        foreach ($vk in (Get-ChildItem -LiteralPath $b)) {
            if ($vk.PSChildName -notmatch '^\d+\.\d+$') { continue }
            $apiRoot = Join-Path $vk.PSPath "PublicAPI"
            if (-not (Test-Path -LiteralPath $apiRoot)) { continue }
            foreach ($ak in (Get-ChildItem -LiteralPath $apiRoot)) {
                if ($ak.PSChildName -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
                $prop = Get-ItemProperty -LiteralPath $ak.PSPath -Name "Siemens.Engineering" -ErrorAction SilentlyContinue
                if (-not $prop) { continue }
                $dll = [string]$prop."Siemens.Engineering"
                if (-not (Test-Path -LiteralPath $dll)) { continue }
                $found += [pscustomobject]@{
                    VersionKey      = $vk.PSChildName
                    AssemblyVersion = $ak.PSChildName
                    Dll             = $dll
                    DllDir          = (Split-Path -Parent $dll)
                }
            }
        }
    }
    return $found
}

$infos = @(Get-OpennessInfo)
if ($infos.Count -eq 0) {
    W "ERROR: TIA Portal Openness not found (HKLM\SOFTWARE\Siemens\Automation\Openness)"
    exit 6
}
$info = $infos | Sort-Object { [version]$_.VersionKey }, { [version]$_.AssemblyVersion } | Select-Object -Last 1
W ("TIA Openness {0} (assembly {1})" -f $info.VersionKey, $info.AssemblyVersion)
W ("public API : {0}" -f $info.Dll)

# ---------- 2. stage + compile ----------
foreach ($d in @($DataDir, (Join-Path $DataDir "logs"), (Join-Path $DataDir "jobs"), (Join-Path $DataDir "work"), (Join-Path $DataDir "out"))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Get-ChildItem -LiteralPath $info.DllDir -Filter "Siemens.Engineering*.dll" -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $DataDir -Force
    W ("copied {0}" -f $_.Name)
}
$srcCs = Join-Path $scriptDir "tools\TiaOpen.cs"
if (-not (Test-Path -LiteralPath $srcCs)) { W "ERROR: tools\TiaOpen.cs missing"; exit 6 }
$dstCs = Join-Path $DataDir "TiaOpen.cs"
Copy-Item -LiteralPath $srcCs -Destination $dstCs -Force
$exe = Join-Path $DataDir "TiaOpen.exe"

$cscCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$csc = $null
foreach ($c in $cscCandidates) { if (Test-Path -LiteralPath $c) { $csc = $c; break } }
if (-not $csc) { W "ERROR: csc.exe (.NET Framework 4.x) not found"; exit 6 }
W ("compiling with {0}" -f $csc)

$outFile = Join-Path $DataDir "build.out"
$errFile = Join-Path $DataDir "build.err"
Get-Process -Name "TiaOpen" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$buildExe = Join-Path $DataDir "TiaOpen.build.exe"
if (Test-Path -LiteralPath $buildExe) { Remove-Item -LiteralPath $buildExe -Force }
# response file: avoids all command line quoting problems (paths may contain spaces)
$rsp = Join-Path $DataDir "build.rsp"
$rspLines = @(
    "/nologo",
    "/target:exe",
    "/platform:x64",
    ('/r:"{0}"' -f $info.Dll),
    ('/out:"{0}"' -f $buildExe),
    ('"{0}"' -f $dstCs)
)
[IO.File]::WriteAllLines($rsp, $rspLines, (New-Object System.Text.UTF8Encoding($false)))
$cp = Start-Process -FilePath $csc -ArgumentList ('@"{0}"' -f $rsp) -WorkingDirectory $DataDir -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -NoNewWindow -Wait
$cout = ""
if (Test-Path -LiteralPath $outFile) { $cout = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8 }
if ($cout -and $cout.Trim().Length -gt 0) { W ("csc output:`n{0}" -f $cout.Trim()) }
if (-not (Test-Path -LiteralPath $buildExe)) {
    W "ERROR: compile failed (TiaOpen.build.exe missing)"
    exit 6
}
Move-Item -LiteralPath $buildExe -Destination $exe -Force
W ("compiled {0}" -f $exe)

# ---------- 3. local user + group ----------
if (-not $Password) {
    $Password = "Tia#" + ([guid]::NewGuid().ToString("N").Substring(0, 10)) + "!"
}
$existing = Get-LocalUser -Name $User -ErrorAction SilentlyContinue
if (-not $existing) {
    try {
        New-LocalUser -Name $User -Password (ConvertTo-SecureString $Password -AsPlainText -Force) `
            -PasswordNeverExpires -AccountNeverExpires -Description "TIA Portal Openness bridge for DSH" -ErrorAction Stop | Out-Null
        W ("created local user {0}" -f $User)
    } catch { W ("ERROR creating user: {0}" -f $_.Exception.Message); exit 6 }
} else {
    try {
        Set-LocalUser -Name $User -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction Stop
        W ("user {0} exists, password updated" -f $User)
    } catch { W ("WARN: could not update password: {0}" -f $_.Exception.Message) }
}

$group = Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue
if (-not $group) {
    W ("ERROR: local group '{0}' missing - install the TIA Portal Openness feature first" -f $GroupName)
    exit 6
}
$members = @(Get-LocalGroupMember -Group $GroupName -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
if ($members -notcontains "$env:COMPUTERNAME\$User") {
    Add-LocalGroupMember -Group $GroupName -Member $User -ErrorAction Stop
    W ("added {0} to '{1}'" -f $User, $GroupName)
} else {
    W ("{0} already in '{1}'" -f $User, $GroupName)
}

# ---------- 4. ACLs ----------
$acct = "$env:COMPUTERNAME\$User"
& icacls $DataDir /grant ("{0}:(OI)(CI)M" -f $acct) /T /Q | Out-Null
& icacls $DataDir /grant "*S-1-5-32-545:(OI)(CI)RX" /T /Q | Out-Null
W ("ACL granted (modify) to {0}" -f $acct)

# ---------- 5. whitelist ----------
$wl = Join-Path $scriptDir "whitelist.ps1"
if (Test-Path -LiteralPath $wl) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wl -Exe $exe -LogPath (Join-Path $DataDir "whitelist.log") | Out-Null
    if ($LASTEXITCODE -ne 0) { W ("WARN: whitelist.ps1 exit={0}, check {1}" -f $LASTEXITCODE, (Join-Path $DataDir "whitelist.log")) }
    else { W "whitelisted TiaOpen.exe" }
}

# ---------- 6. config ----------
$cfg = [pscustomobject]@{
    tiaVersion      = [string]$info.VersionKey
    assemblyVersion = [string]$info.AssemblyVersion
    dll             = [string]$info.Dll
    dllDir          = [string]$info.DllDir
    dataDir         = [string]$DataDir
    exe             = [string]$exe
    user            = [string]$acct
    password        = [string]$Password
    logs            = (Join-Path $DataDir "logs")
    work            = (Join-Path $DataDir "work")
}
$cfgFile = Join-Path $DataDir "config.json"
$json = $cfg | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText($cfgFile, $json, (New-Object System.Text.UTF8Encoding($false)))
& icacls $cfgFile /inheritance:r /grant:r "Administrators:(F)" "SYSTEM:(F)" ("{0}:(R)" -f $acct) /Q | Out-Null
W ("config written: {0}" -f $cfgFile)

# ---------- 7. self test ----------
if (-not $SkipSelfTest) {
    $jobFile = Join-Path $DataDir ("jobs\selftest.txt")
    $jobText = "selftest`r`ninfo" + "`r`n"
    [IO.File]::WriteAllText($jobFile, $jobText, (New-Object System.Text.UTF8Encoding($false)))
    W "self test: info (may take 1-2 minutes for the first TIA start) ..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir "run.ps1") -Job $jobFile -DataDir $DataDir -TimeoutSec 300 -Elevated | Out-Null
    $rc = $LASTEXITCODE
    W ("self test exit={0}" -f $rc)
    $status = Join-Path $DataDir "logs\selftest.status"
    if (Test-Path -LiteralPath $status) {
        $text = Get-Content -LiteralPath $status -Raw -Encoding UTF8
        W ("self test status:`n{0}" -f $text.Trim())
    }
    if ($rc -ne 0) { W "WARN: self test failed - check the logs above" }
}

W "--- setup done ---"
W ("next: write a job file under {0}\jobs and run scripts\run.ps1 -Job <file>" -f $DataDir)
exit 0
