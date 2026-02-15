# Comprehensive Windows Evidence Capture Script
# Captures system info, project structure, build attempts, and test results

$evidenceDir = "C:\Dev\evidence"
New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null

$env:PATH = "$env:LOCALAPPDATA\dotnet;$env:PATH"
$env:DOTNET_ROOT = "$env:LOCALAPPDATA\dotnet"

# --- 1. System Info ---
Write-Host "=== 1. System Info ===" -ForegroundColor Cyan
$sysInfo = @{
    ComputerName = $env:COMPUTERNAME
    OS = (Get-CimInstance Win32_OperatingSystem).Caption
    OSVersion = (Get-CimInstance Win32_OperatingSystem).Version
    Architecture = $env:PROCESSOR_ARCHITECTURE
    ProcessorCount = $env:NUMBER_OF_PROCESSORS
    TotalRAM_MB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
    DotNetVersion = (dotnet --version 2>&1)
    DotNetSDKs = (dotnet --list-sdks 2>&1) -join "`n"
    DotNetRuntimes = (dotnet --list-runtimes 2>&1) -join "`n"
    UserName = $env:USERNAME
    DateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}
$sysInfo | ConvertTo-Json -Depth 2 | Out-File "$evidenceDir\01_system_info.json" -Encoding UTF8
$sysInfo | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "Saved: 01_system_info.json"

# --- 2. Project Structure ---
Write-Host "`n=== 2. Project Structure ===" -ForegroundColor Cyan
$projectDir = "C:\Dev\windows-offline-transcribe"
if (Test-Path $projectDir) {
    $tree = Get-ChildItem -Path $projectDir -Recurse -Depth 3 |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|\.vs|\.git)\\' } |
        Select-Object @{N='RelativePath';E={$_.FullName.Replace($projectDir + '\', '')}},
                      @{N='Type';E={if($_.PSIsContainer){'Dir'}else{'File'}}},
                      @{N='Size';E={if(!$_.PSIsContainer){$_.Length}else{$null}}}
    $tree | ConvertTo-Json -Depth 2 | Out-File "$evidenceDir\02_project_structure.json" -Encoding UTF8
    Write-Host "Files in project: $($tree.Count)"
    Write-Host "Saved: 02_project_structure.json"
} else {
    Write-Host "Project not found at $projectDir"
}

# --- 3. Source File Inventory ---
Write-Host "`n=== 3. Source File Inventory ===" -ForegroundColor Cyan
$csFiles = Get-ChildItem -Path "$projectDir\src" -Recurse -Filter "*.cs" |
    Select-Object @{N='File';E={$_.FullName.Replace($projectDir + '\', '')}}, Length
$xamlFiles = Get-ChildItem -Path "$projectDir\src" -Recurse -Filter "*.xaml" |
    Select-Object @{N='File';E={$_.FullName.Replace($projectDir + '\', '')}}, Length
$inventory = @{
    CSharpFiles = $csFiles.Count
    XamlFiles = $xamlFiles.Count
    TotalSourceFiles = $csFiles.Count + $xamlFiles.Count
    Files = @($csFiles) + @($xamlFiles)
}
$inventory | ConvertTo-Json -Depth 3 | Out-File "$evidenceDir\03_source_inventory.json" -Encoding UTF8
Write-Host "C# files: $($csFiles.Count), XAML files: $($xamlFiles.Count)"
Write-Host "Saved: 03_source_inventory.json"

# --- 4. Test Results (already run) ---
Write-Host "`n=== 4. Previous Test Results ===" -ForegroundColor Cyan
$trxPath = "$projectDir\test-results\test-results.trx"
if (Test-Path $trxPath) {
    Copy-Item $trxPath "$evidenceDir\04_test_results_windows.trx" -Force
    Write-Host "TRX file copied ($('{0:N0}' -f (Get-Item $trxPath).Length) bytes)"
} else {
    Write-Host "No TRX found, re-running tests..."
    dotnet test "$projectDir\tests\OfflineSpeechTranslation.Tests\OfflineSpeechTranslation.Tests.csproj" `
        -c Release --verbosity normal `
        --logger "trx;LogFileName=test-results.trx" `
        --results-directory "$evidenceDir" 2>&1 | Tee-Object -FilePath "$evidenceDir\04_test_output.txt"
}

# --- 5. Attempt WinUI App Build ---
Write-Host "`n=== 5. Attempting WinUI 3 App Build ===" -ForegroundColor Cyan
$mainCsproj = "$projectDir\src\OfflineSpeechTranslation\OfflineSpeechTranslation.csproj"
if (Test-Path $mainCsproj) {
    Write-Host "Found main project: $mainCsproj"
    Write-Host "Restoring NuGet packages..."
    $restoreOutput = dotnet restore $mainCsproj 2>&1
    $restoreOutput | Out-File "$evidenceDir\05_winui_restore.txt" -Encoding UTF8
    $restoreOutput | Write-Host

    Write-Host "`nBuilding WinUI 3 app..."
    $buildOutput = dotnet build $mainCsproj -c Release 2>&1
    $buildOutput | Out-File "$evidenceDir\05_winui_build.txt" -Encoding UTF8
    $buildOutput | Write-Host

    if ($LASTEXITCODE -eq 0) {
        Write-Host "BUILD SUCCEEDED!" -ForegroundColor Green

        # Try to find the executable
        $exe = Get-ChildItem -Path "$projectDir\src\OfflineSpeechTranslation\bin\Release" -Recurse -Filter "*.exe" | Select-Object -First 1
        if ($exe) {
            Write-Host "Executable: $($exe.FullName)"
            Write-Host "Size: $('{0:N0}' -f $exe.Length) bytes"
        }
    } else {
        Write-Host "Build failed (expected - may need Windows App SDK workload)" -ForegroundColor Yellow
    }
} else {
    Write-Host "Main project not found"
}

# --- 6. Installed Workloads ---
Write-Host "`n=== 6. .NET Workloads ===" -ForegroundColor Cyan
$workloads = dotnet workload list 2>&1
$workloads | Out-File "$evidenceDir\06_dotnet_workloads.txt" -Encoding UTF8
$workloads | Write-Host

# --- 7. NuGet Package Cache ---
Write-Host "`n=== 7. NuGet Cache Status ===" -ForegroundColor Cyan
$nugetInfo = dotnet nuget locals all --list 2>&1
$nugetInfo | Out-File "$evidenceDir\07_nuget_info.txt" -Encoding UTF8
$nugetInfo | Write-Host

# --- 8. Copy all evidence to shared folder ---
Write-Host "`n=== 8. Copying evidence to shared folder ===" -ForegroundColor Cyan
$sharedEvidence = "//host.lan/Data/artifacts/evidence/windows-real"
New-Item -ItemType Directory -Force -Path $sharedEvidence -ErrorAction SilentlyContinue | Out-Null
Copy-Item "$evidenceDir\*" $sharedEvidence -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Evidence copied to $sharedEvidence"

# --- Summary ---
Write-Host "`n=== EVIDENCE CAPTURE COMPLETE ===" -ForegroundColor Green
Write-Host "Files in $evidenceDir`:"
Get-ChildItem $evidenceDir | Format-Table Name, Length, LastWriteTime -AutoSize
