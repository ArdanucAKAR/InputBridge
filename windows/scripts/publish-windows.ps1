[CmdletBinding()]
param([string]$Version = '0.1.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root 'src\InputBridge.Windows\InputBridge.Windows.csproj'
$out = Join-Path $root 'dist\publish'
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:Version=$Version -o $out
Write-Host "Published InputBridge to $out"
