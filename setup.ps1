# setup.ps1 — install MAST Claude Code skills and memories (Windows PowerShell 5.1+)
#
# Memory lives under %USERPROFILE%\.claude\projects\<slug>\memory, where <slug>
# is Claude Code's encoding of the project working-dir path (path separators and
# the drive ':' become '-'). The slug differs per machine, so it is NOT hardcoded:
#   C:\Users\you\Desktop\MAST  ->  C--Users-you-Desktop-MAST
#
# Pass the project working-dir path (or the slug itself) as -ProjectDir. With
# none, the script auto-detects when exactly one project exists.
#
# Symlinks need Developer Mode or an elevated shell; without either, files are
# copied instead and you must re-run this script after each `git pull`.
param(
    [string]$ProjectDir
)
$ErrorActionPreference = 'Stop'

$RepoDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillsDir   = Join-Path $env:USERPROFILE '.claude\skills'
$ProjectsDir = Join-Path $env:USERPROFILE '.claude\projects'

function Get-Slug([string]$p) { return ($p -replace '[/\\:]', '-') }

$slug = ''
if ($ProjectDir) {
    if (Test-Path (Join-Path $ProjectsDir $ProjectDir)) { $slug = $ProjectDir }
    else { $slug = Get-Slug $ProjectDir }
}
if (-not $slug) {
    $dirs = @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 1) {
        $slug = $dirs[0].Name
    } else {
        Write-Host "Could not determine which Claude project to install memories into."
        Write-Host "Re-run with the project working-dir path, e.g.:"
        Write-Host "  .\setup.ps1 -ProjectDir 'C:\Users\you\Desktop\MAST'"
        Write-Host "Projects currently under ${ProjectsDir}:"
        foreach ($d in $dirs) { Write-Host "  $($d.Name)" }
        exit 1
    }
}
$MemoryDir = Join-Path $ProjectsDir (Join-Path $slug 'memory')

Write-Host "Installing MAST Claude Code configuration..."
Write-Host "  skills -> $SkillsDir"
Write-Host "  memory -> $MemoryDir"

New-Item -ItemType Directory -Force -Path $SkillsDir | Out-Null
New-Item -ItemType Directory -Force -Path $MemoryDir | Out-Null

function Install-Link($src, $dst, $kind) {
    $name = Split-Path $dst -Leaf
    if (Test-Path $dst) {
        $item = Get-Item $dst -Force
        if ($item.LinkType) { Write-Host "  ${kind}: $name (already linked)" }
        else { Write-Host "  ${kind}: $name - skipped (local file exists, not a link)" }
        return
    }
    try {
        New-Item -ItemType SymbolicLink -Path $dst -Target $src -ErrorAction Stop | Out-Null
        Write-Host "  ${kind}: $name -> linked"
    } catch {
        Copy-Item -Path $src -Destination $dst
        Write-Host "  ${kind}: $name -> copied (symlink needs Developer Mode/admin; re-run after 'git pull')"
    }
}

Get-ChildItem -Path (Join-Path $RepoDir 'skills') -Filter '*.md' -File |
    ForEach-Object { Install-Link $_.FullName (Join-Path $SkillsDir $_.Name) 'skill' }

Get-ChildItem -Path (Join-Path $RepoDir 'memory\*') -Include '*.md','*.toml' -File |
    ForEach-Object { Install-Link $_.FullName (Join-Path $MemoryDir $_.Name) 'memory' }

Write-Host "Done. Restart Claude Code to pick up new skills."
