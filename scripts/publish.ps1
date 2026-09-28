param([ValidateSet('win-x64','win-x86','win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$dest = Join-Path $root "dist/$Runtime"
dotnet publish src/Planner.Windows/Planner.Windows.csproj -c Release -r $Runtime --self-contained true -p:PublishSingleFile=false -p:DebugType=None -o $dest
if ($LASTEXITCODE -ne 0) { throw 'Publish failed' }
Copy-Item README.ru.md,LICENSE,THIRD_PARTY.md -Destination $dest
Compress-Archive -Path "$dest/*" -DestinationPath "dist/AutoConnectRush-$Runtime.zip" -Force
