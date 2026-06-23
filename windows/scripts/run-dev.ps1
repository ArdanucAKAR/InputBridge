$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
dotnet run --project .\src\InputBridge.Windows\InputBridge.Windows.csproj
