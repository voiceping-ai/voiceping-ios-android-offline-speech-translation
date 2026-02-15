# Windows Dev Environment Setup Script
# Run this from PowerShell inside the Windows container
# The project source is accessible at \\host.lan\Data (Samba share)

Write-Host "=== Setting up .NET 8 SDK ===" -ForegroundColor Cyan

# Download .NET 8 SDK installer
$dotnetUrl = "https://dot.net/v1/dotnet-install.ps1"
$installScript = "$env:TEMP\dotnet-install.ps1"

Write-Host "Downloading .NET 8 SDK install script..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $dotnetUrl -OutFile $installScript -UseBasicParsing

Write-Host "Installing .NET 8 SDK..."
& $installScript -Channel 8.0 -InstallDir "$env:LOCALAPPDATA\dotnet"

# Add to PATH for this session
$env:PATH = "$env:LOCALAPPDATA\dotnet;$env:PATH"
$env:DOTNET_ROOT = "$env:LOCALAPPDATA\dotnet"

# Verify installation
Write-Host "`n=== Verifying .NET 8 SDK ===" -ForegroundColor Cyan
dotnet --version
dotnet --list-sdks

# Copy project from Samba share to local disk for faster builds
Write-Host "`n=== Copying project to local disk ===" -ForegroundColor Cyan
$projectSrc = "\\host.lan\Data"
$localProject = "C:\Dev\windows-offline-speech-translation"

if (Test-Path $projectSrc) {
    New-Item -ItemType Directory -Force -Path $localProject | Out-Null
    Copy-Item -Path "$projectSrc\*" -Destination $localProject -Recurse -Force
    Write-Host "Project copied to $localProject"
} else {
    Write-Host "WARNING: Cannot access $projectSrc - check Samba share" -ForegroundColor Yellow
    Write-Host "You may need to map the network drive first:"
    Write-Host "  net use Z: \\host.lan\Data"
}

# Try to restore and build tests (non-WinUI, cross-platform)
Write-Host "`n=== Building test project ===" -ForegroundColor Cyan
Push-Location $localProject
dotnet restore tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj
dotnet build tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj -c Release

Write-Host "`n=== Running unit tests ===" -ForegroundColor Cyan
dotnet test tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj -c Release --verbosity normal --logger "trx;LogFileName=test-results.trx" --results-directory "$localProject\test-results"
Pop-Location

Write-Host "`n=== Setup complete ===" -ForegroundColor Green
Write-Host "Test results at: $localProject\test-results\"
Write-Host "To copy results back: Copy-Item $localProject\test-results\* \\host.lan\Data\artifacts\evidence\ -Force"
