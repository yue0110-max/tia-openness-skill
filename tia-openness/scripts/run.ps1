# run.ps1 - run TiaOpen.exe as the dedicated Openness service user
# Must run elevated (Start-Process -Credential needs the privilege).
# ASCII only: Windows PowerShell 5.1 decodes BOM-less UTF-8 scripts as ANSI.
#
# The job file is UTF-8 and contains one item per line:
#   line 1 : tag (used for log/status file names, keep it ASCII)
#   line 2+: arguments handed to TiaOpen.exe (the tool log path is prepended)
# Example job file:
#   dump1
#   dump
#   C:\ProgramData\TiaOpenness\work\MyProject\MyProject.ap20
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File run.ps1 -Job C:\ProgramData\TiaOpenness\jobs\dump1.txt
# Exit codes: 0 ok, 2 usage, 3 tool failure, 4 timeout, 5 not elevated, 6 launch failed
param(
    [Parameter(Mandatory = $true)][string]$Job,
    [string]$DataDir = "C:\ProgramData\TiaOpenness",
    [int]$TimeoutSec = 1800,
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$logDir = Join-Path $DataDir "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

function W([string]$path, [string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    Write-Host $line
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isElevated -and -not $Elevated) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Job "{1}" -DataDir "{2}" -TimeoutSec {3} -Elevated' -f $PSCommandPath, $Job, $DataDir, $TimeoutSec
    Write-Host "not elevated: relaunching elevated, poll $logDir for status"
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden | Out-Null
    exit 0
}

if (-not (Test-Path -LiteralPath $Job)) {
    Write-Host "ERROR: job file not found: $Job"
    exit 2
}
$lines = @(Get-Content -LiteralPath $Job -Encoding UTF8)
if ($lines.Count -lt 2) {
    Write-Host "ERROR: job file needs a tag line and at least one argument"
    exit 2
}
$tag = $lines[0].Trim()
if ($tag.Length -eq 0) { $tag = "job" }
$toolArgs = @()
for ($i = 1; $i -lt $lines.Count; $i++) {
    $v = $lines[$i]
    if ($null -eq $v) { continue }
    if ($v.Trim().Length -eq 0 -and $toolArgs.Count -gt 0) { continue }
    $toolArgs += $v
}

$statusFile = Join-Path $logDir ("{0}.status" -f $tag)
$toolLog = Join-Path $logDir ("{0}.log" -f $tag)
if (Test-Path -LiteralPath $statusFile) { Remove-Item -LiteralPath $statusFile -Force -ErrorAction SilentlyContinue }
W $statusFile ("job {0}: {1}" -f $tag, ($toolArgs -join " "))
W $statusFile ("tool log: {0}" -f $toolLog)

$cfgPath = Join-Path $DataDir "config.json"
if (-not (Test-Path -LiteralPath $cfgPath)) {
    W $statusFile "ERROR: config.json missing, run setup.ps1 first"
    exit 6
}
$cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
$exe = [string]$cfg.exe
if (-not (Test-Path -LiteralPath $exe)) {
    W $statusFile ("ERROR: exe not found: {0}" -f $exe)
    exit 6
}

$sec = ConvertTo-SecureString ([string]$cfg.password) -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential([string]$cfg.user, $sec)

$argList = @($toolLog) + $toolArgs
$proc = $null
try {
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $DataDir -Credential $cred -PassThru -WindowStyle Hidden
} catch {
    W $statusFile ("ERROR: launch failed: {0}" -f $_.Exception.Message)
    exit 6
}
W $statusFile ("started pid {0} as {1}" -f $proc.Id, $cfg.user)

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$finished = $false
while ((Get-Date) -lt $deadline) {
    try {
        if ($proc.HasExited) { $finished = $true; break }
    } catch {
        $finished = $true; break
    }
    Start-Sleep -Milliseconds 700
}

$code = $null
if ($finished) {
    try { $code = $proc.ExitCode } catch { $code = $null }
}

# With -Credential the Process handle may not expose ExitCode; the tool writes
# its own exit code as the last "== done rc=N ==" line, so prefer that.
$rcFromLog = $null
if (Test-Path -LiteralPath $toolLog) {
    $text = Get-Content -LiteralPath $toolLog -Encoding UTF8 -Raw
    if ($text) {
        $ms = [regex]::Matches($text, '== done rc=(\d+) ==')
        if ($ms.Count -gt 0) { $rcFromLog = [int]$ms[$ms.Count - 1].Groups[1].Value }
    }
}
$final = 0
if ($null -ne $rcFromLog) { $final = $rcFromLog }
elseif ($null -ne $code) { $final = [int]$code }

if (-not $finished) {
    W $statusFile ("TIMEOUT after {0}s (pid {1} still running)" -f $TimeoutSec, $proc.Id)
} else {
    W $statusFile ("exit={0} (proc={1}, log={2})" -f $final, $code, $rcFromLog)
}

if (Test-Path -LiteralPath $toolLog) {
    $text = Get-Content -LiteralPath $toolLog -Encoding UTF8 -Raw
    if ($text) {
        $trimmed = $text.TrimEnd()
        W $statusFile "--- tool log ---"
        Add-Content -LiteralPath $statusFile -Value $trimmed -Encoding UTF8
    }
}

if (-not $finished) { exit 4 }
if ($final -ne 0) { exit 3 }
exit 0
