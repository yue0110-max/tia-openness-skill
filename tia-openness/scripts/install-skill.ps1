# install-skill.ps1 - install the tia-openness skill into a DSH skills folder
# ASCII only: Windows PowerShell 5.1 decodes BOM-less UTF-8 scripts as ANSI.
#
# Skills are discovered in (rank order):
#   <projectRoot>\.dsh\skills, <projectRoot>\.agents\skills, customSkillDirs,
#   <dshHome>\skills, <agentsHome>\skills
# A skill is a folder that contains SKILL.md. Discovery is one level deep.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File install-skill.ps1
#   powershell.exe ... -File install-skill.ps1 -Target "C:\path\to\project\.dsh\skills"
param(
    [string]$Target = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$src = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $src "SKILL.md"))) {
    Write-Host "ERROR: SKILL.md not found next to scripts\ - run this from the skill folder"
    exit 2
}
$name = Split-Path -Leaf $src
if (-not $Target) { $Target = Join-Path $env:USERPROFILE ".dsh\skills" }
if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
$dst = Join-Path $Target $name
if (Test-Path -LiteralPath $dst) {
    if (-not $Force) {
        Write-Host "ERROR: $dst already exists (use -Force to overwrite)"
        exit 3
    }
    Remove-Item -LiteralPath $dst -Recurse -Force
}
Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
Write-Host ("installed: {0}" -f $dst)
Write-Host "restart DSH (or wait for the skill watcher) and check that the skill is listed"
exit 0
