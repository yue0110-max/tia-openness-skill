# whitelist.ps1 - add .NET exe files to the TIA Portal Openness firewall whitelist
# Must run elevated. ASCII only on purpose: Windows PowerShell 5.1 reads a
# BOM-less UTF-8 script with the ANSI code page and would garble non-ASCII text.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File whitelist.ps1 -Exe "C:\path\TiaOpen.exe"
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File whitelist.ps1 -All
#
# Registry layout expected by the TIA Portal Openness loader (verified by IL
# inspection of Siemens.Automation.Opns.Loader.Impl.dll):
#   HKLM\SOFTWARE\Siemens\Automation\Openness\<major>.<minor>\Whitelist\<exe name>\<entry name>
#       Path         REG_SZ  full path of the exe
#       DateModified REG_SZ  last write time in UTC, exactly yyyy/MM/dd HH:mm:ss.fff
#       FileHash     REG_SZ  Base64 of the file SHA-256
#
param(
    [string[]]$Exe,
    [switch]$All,
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
if (-not $LogPath) { $LogPath = Join-Path $PSScriptRoot "whitelist.log" }

function W([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
W ("--- whitelist start (elevated={0}) ---" -f $elevated)
if (-not $elevated) {
    W "ERROR: this script must run elevated (HKLM write required)"
    exit 5
}

# ---------- locate Openness versions ----------
$bases = @(
    "HKLM:\SOFTWARE\Siemens\Automation\Openness",
    "HKLM:\SOFTWARE\WOW6432Node\Siemens\Automation\Openness"
)
$versions = @()
foreach ($b in $bases) {
    if (-not (Test-Path $b)) { continue }
    foreach ($k in (Get-ChildItem -LiteralPath $b)) {
        if ($k.PSChildName -match '^\d+\.\d+$' -and ($versions -notcontains $k.PSChildName)) {
            $versions += $k.PSChildName
        }
    }
}
if ($versions.Count -eq 0) {
    W "ERROR: no Openness version key found under HKLM\SOFTWARE\Siemens\Automation\Openness"
    exit 6
}
W ("versions found: {0}" -f ($versions -join ", "))

# ---------- collect targets ----------
$targets = @()
if ($Exe) {
    foreach ($e in $Exe) {
        if (Test-Path -LiteralPath $e) { $targets += (Resolve-Path -LiteralPath $e).Path }
        else { W ("WARN: not found {0}" -f $e) }
    }
}
if ($All) {
    $base = Split-Path -Parent $PSScriptRoot
    foreach ($f in (Get-ChildItem -LiteralPath $base -Filter *.exe -File -ErrorAction SilentlyContinue)) {
        if ($targets -notcontains $f.FullName) { $targets += $f.FullName }
    }
}
if ($targets.Count -eq 0) {
    W "ERROR: nothing to whitelist (pass -Exe <path> or -All)"
    exit 2
}

# ---------- write entries ----------
$ok = 0
foreach ($path in $targets) {
    $item = Get-Item -LiteralPath $path
    $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256
    $bytes = New-Object byte[] ($hash.Hash.Length / 2)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [Convert]::ToByte($hash.Hash.Substring($i * 2, 2), 16)
    }
    $b64 = [Convert]::ToBase64String($bytes)
    $dateUtc = $item.LastWriteTimeUtc.ToString("yyyy/MM/dd HH:mm:ss.fff", [Globalization.CultureInfo]::InvariantCulture)
    foreach ($ver in $versions) {
        foreach ($b in $bases) {
            $root = Join-Path $b $ver
            if (-not (Test-Path $root)) { continue }
            $key = Join-Path $root ("Whitelist\{0}\{0}" -f $item.Name)
            try {
                New-Item -Path $key -Force | Out-Null
                New-ItemProperty -Path $key -Name Path -Value $item.FullName -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $key -Name DateModified -Value $dateUtc -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $key -Name FileHash -Value $b64 -PropertyType String -Force | Out-Null
                $ok++
                W ("OK  {0}  ver={1}  hive={2}" -f $item.Name, $ver, $b)
            } catch {
                W ("ERR {0} ver={1} hive={2}: {3}" -f $item.Name, $ver, $b, $_.Exception.Message)
            }
        }
    }
    W ("    path={0} dateUtc={1} hash={2}" -f $item.FullName, $dateUtc, $b64)
}
W ("--- whitelist done: {0} entries written ---" -f $ok)
if ($ok -eq 0) { exit 7 }
exit 0
