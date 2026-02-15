@echo off
echo === Installing .NET 8 SDK ===
powershell -ExecutionPolicy Bypass -Command "& { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile '%TEMP%\dotnet-install.ps1' -UseBasicParsing; & '%TEMP%\dotnet-install.ps1' -Channel 8.0 -InstallDir '%LOCALAPPDATA%\dotnet' }"

set PATH=%LOCALAPPDATA%\dotnet;%PATH%
set DOTNET_ROOT=%LOCALAPPDATA%\dotnet

echo === Verifying .NET 8 SDK ===
dotnet --version

echo === Copying project locally ===
xcopy /E /I /Y \\host.lan\Data C:\Dev\wot

echo === Restoring test project ===
dotnet restore C:\Dev\wot\tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj

echo === Building test project ===
dotnet build C:\Dev\wot\tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj -c Release

echo === Running tests ===
dotnet test C:\Dev\wot\tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj -c Release --verbosity normal --logger "trx;LogFileName=test-results.trx" --results-directory C:\Dev\wot\test-results

echo === Copying results back ===
xcopy /E /I /Y C:\Dev\wot\test-results \\host.lan\Data\artifacts\evidence\windows-tests

echo === DONE ===
pause
