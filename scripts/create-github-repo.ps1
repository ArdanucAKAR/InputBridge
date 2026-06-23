[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [ValidateSet('public', 'private')][string]$Visibility = 'public'
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required. Install it from https://cli.github.com, run 'gh auth login', then retry."
}
if (-not (Test-Path '.git')) {
    git init
    git branch -M main
    git add .
    git commit -m 'Initial InputBridge release'
}

gh repo create $Repository --$Visibility --source . --remote origin --push
Write-Host "Repository created and pushed. Create a version tag with: git tag v0.2.0; git push origin v0.2.0"
