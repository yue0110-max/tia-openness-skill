# stage-project.ps1 - copy a TIA Portal project folder into the staging area
# so the dedicated service user can open it (it cannot read the operator profile).
# ASCII only: Windows PowerShell 5.1 decodes BOM-less UTF-8 scripts as ANSI.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File stage-project.ps1 -Src "C:\path\MyProject.ap20"
#   powershell.exe ... -File stage-project.ps1 -Src "C:\path\MyProjectFolder" -Name "26year"
#
# Writes <DataDir>\work\last-project.txt (UTF-8) with the staged .apXX full path.
param(
    [string]$Src = "",
    [string]$SrcFile = "",
    [string]$DataDir = "C:\ProgramData\TiaOpenness",
    [string]$Name = "",
    [switch]$Elevated
)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $env:TEMP "tia-openness-stage.log"
function W([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# -SrcFile: UTF-8 text file whose first non-empty line is the source path.
# Use it when the path contains non-ASCII characters and has to cross a
# PowerShell command line (Windows PowerShell decodes -File arguments with the
# ANSI code page, which can corrupt them).
if (-not $Src -and $SrcFile) {
    $lines = @(Get-Content -LiteralPath $SrcFile -Encoding UTF8 | Where-Object { $_.Trim().Length -gt 0 })
    if ($lines.Count -gt 0) { $Src = $lines[0].Trim() }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and -not $Elevated) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SrcFile "{1}" -DataDir "{2}" -Elevated' -f $PSCommandPath, $SrcFile, $DataDir
    if (-not $SrcFile) { $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Src "{1}" -DataDir "{2}" -Elevated' -f $PSCommandPath, $Src, $DataDir }
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden | Out-Null
    exit 0
}

W ("--- stage-project ---")
W ("src = {0}" -f $Src)
if (-not $Src -or -not (Test-Path -LiteralPath $Src)) { W "ERROR: source not found"; exit 6 }

$srcItem = Get-Item -LiteralPath $Src
$projDir = $srcItem.FullName
if (-not $srcItem.PSIsContainer) { $projDir = Split-Path -Parent $srcItem.FullName }
$projFiles = @(Get-ChildItem -LiteralPath $projDir -Filter "*.ap*" -File | Where-Object { $_.Name -match '\.ap\d\d$' })
if ($projFiles.Count -eq 0) { W ("ERROR: no .apXX project file in {0}" -f $projDir); exit 6 }
$projFile = $projFiles[0]
if (-not $srcItem.PSIsContainer -and $srcItem.Name -match '\.ap\d\d$') { $projFile = $srcItem }
if ($Name) {
    foreach ($f in $projFiles) { if ($f.Name -like ("*" + $Name + "*")) { $projFile = $f; break } }
}
W ("project file = {0}" -f $projFile.FullName)

$leaf = Split-Path -Leaf $projDir
$workRoot = Join-Path $DataDir "work"
if (-not (Test-Path -LiteralPath $workRoot)) { New-Item -ItemType Directory -Path $workRoot -Force | Out-Null }
$dstDir = Join-Path $workRoot $leaf
if (Test-Path -LiteralPath $dstDir) {
    W ("removing previous copy {0}" -f $dstDir)
    Remove-Item -LiteralPath $dstDir -Recurse -Force
}
W ("copying {0} -> {1}" -f $projDir, $dstDir)
Copy-Item -LiteralPath $projDir -Destination $dstDir -Recurse -Force

$staged = Join-Path $dstDir $projFile.Name
if (-not (Test-Path -LiteralPath $staged)) { W ("ERROR: staged project missing: {0}" -f $staged); exit 6 }

$cfgPath = Join-Path $DataDir "config.json"
$acct = $null
if (Test-Path -LiteralPath $cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Encoding UTF8 -Raw | ConvertFrom-Json
    $acct = [string]$cfg.user
}
if ($acct) {
    & icacls $dstDir /grant ("{0}:(OI)(CI)M" -f $acct) /T /Q | Out-Null
    W ("ACL granted to {0}" -f $acct)
}
$pointer = Join-Path $workRoot "last-project.txt"
[IO.File]::WriteAllText($pointer, $staged, (New-Object System.Text.UTF8Encoding($false)))
W ("staged = {0}" -f $staged)
W ("pointer = {0}" -f $pointer)
exit 0
