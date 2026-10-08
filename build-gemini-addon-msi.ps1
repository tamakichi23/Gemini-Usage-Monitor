param(
    [string]$WixBin,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$taskAddonSource = $PSScriptRoot
$taskRepoRoot = [IO.Path]::GetFullPath($taskAddonSource)
$taskTargetRoot = Join-Path $taskRepoRoot 'target'
$taskProductVersion = (Get-Content -LiteralPath (Join-Path $taskRepoRoot 'VERSION') -Raw).Trim()
if ($taskProductVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION must use major.minor.patch format.' }
$taskAssemblyVersion = [regex]::Match((Get-Content -LiteralPath (Join-Path $taskAddonSource 'GeminiUsageAddon.cs') -Raw), 'AssemblyVersion\("([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"\)').Groups[1].Value
if ($taskAssemblyVersion -ne ($taskProductVersion + '.0')) { throw 'The C# assembly version must match VERSION plus a .0 revision.' }
$taskCollectorVersion = (Get-Content -LiteralPath (Join-Path $taskAddonSource 'collector\package.json') -Raw | ConvertFrom-Json).version
if ($taskCollectorVersion -ne $taskProductVersion) { throw 'The collector package version must match VERSION.' }
if (-not $OutputPath) { $OutputPath = Join-Path $taskTargetRoot ('GeminiUsageMonitor-' + $taskProductVersion + '.msi') }
$taskOutputPath = [IO.Path]::GetFullPath($OutputPath)
$taskOutputDirectory = Split-Path -Parent $taskOutputPath

if (-not $WixBin) {
    $taskDefaultWixBin = Join-Path $env:TEMP 'wix3141-gemini-addon\tools'
    if (Test-Path -LiteralPath (Join-Path $taskDefaultWixBin 'candle.exe')) {
        $WixBin = $taskDefaultWixBin
    } else {
        $taskCandle = Get-Command candle.exe -ErrorAction SilentlyContinue
        if ($taskCandle) { $WixBin = Split-Path -Parent $taskCandle.Source }
    }
}
if (-not $WixBin) { throw 'WiX Toolset v3 binaries are required. Pass -WixBin with the folder containing candle.exe, light.exe, and heat.exe.' }
$WixBin = [IO.Path]::GetFullPath($WixBin)
foreach ($taskTool in @('candle.exe', 'light.exe', 'heat.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $WixBin $taskTool) -PathType Leaf)) { throw ('WiX tool not found: ' + (Join-Path $WixBin $taskTool)) }
}

$taskBuildDirectory = Join-Path $env:TEMP ('GeminiUsageAddon-msi-' + [guid]::NewGuid().ToString('N'))
$taskPackagePath = Join-Path $taskBuildDirectory 'GeminiUsageAddon.zip'
$taskStageRoot = Join-Path $taskBuildDirectory 'stage'
$taskStageAddon = Join-Path $taskStageRoot 'GeminiUsageAddon'
$taskHarvestPath = Join-Path $taskBuildDirectory 'GeminiUsageAddon-files.wxs'
$taskMainObjectPath = Join-Path $taskBuildDirectory 'GeminiUsageAddon.wixobj'
$taskHarvestObjectPath = Join-Path $taskBuildDirectory 'GeminiUsageAddon-files.wixobj'
$taskSourcePath = Join-Path $taskAddonSource 'GeminiUsageAddon.wxs'

try {
    New-Item -ItemType Directory -Path $taskBuildDirectory -Force | Out-Null
    $taskWindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskPackageScript = Join-Path $taskAddonSource 'package-gemini-addon.ps1'
    $taskPackageOutput = & $taskWindowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $taskPackageScript -OutputPath $taskPackagePath 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskPackagePath -PathType Leaf)) {
        throw ('Creating the add-on payload failed: ' + ($taskPackageOutput -join "`n"))
    }

    Expand-Archive -LiteralPath $taskPackagePath -DestinationPath $taskStageRoot -Force
    if (-not (Test-Path -LiteralPath (Join-Path $taskStageAddon 'GeminiUsageAddon.exe') -PathType Leaf)) {
        throw 'The packaged add-on launcher is missing.'
    }

    $taskHeat = Join-Path $WixBin 'heat.exe'
    $taskHeatArguments = @(
        'dir', $taskStageAddon,
        '-cg', 'AddonFiles',
        '-dr', 'INSTALLFOLDER',
        '-ag',
        '-srd', '-scom', '-sreg',
        '-var', 'var.AddonSource',
        '-out', $taskHarvestPath
    )
    $taskHeatOutput = & $taskHeat @taskHeatArguments 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskHarvestPath -PathType Leaf)) {
        throw ('Harvesting the packaged add-on files failed: ' + ($taskHeatOutput -join "`n"))
    }

    [xml]$taskHarvestXml = Get-Content -LiteralPath $taskHarvestPath -Raw
    $taskXmlNamespace = New-Object System.Xml.XmlNamespaceManager($taskHarvestXml.NameTable)
    $taskXmlNamespace.AddNamespace('w', 'http://schemas.microsoft.com/wix/2006/wi')
    $taskHarvestComponents = @($taskHarvestXml.SelectNodes('//w:Component', $taskXmlNamespace))
    $taskGuidNamespace = [Text.Encoding]::UTF8.GetBytes('GeminiUsageAddon-MSI-Components-v1:')
    foreach ($taskComponent in $taskHarvestComponents) {
        $taskComponentFiles = @($taskComponent.SelectNodes('w:File', $taskXmlNamespace))
        $taskFileKeyPath = $taskComponent.SelectSingleNode('w:File[@KeyPath="yes"]', $taskXmlNamespace)
        if (-not $taskComponentFiles.Count -or -not $taskFileKeyPath) { continue }
        if ($taskFileKeyPath.GetAttribute('Source') -eq '$(var.AddonSource)\GeminiUsageAddon.exe') {
            $taskFileKeyPath.SetAttribute('Id', 'GeminiUsageAddonExeFile')
        }
        $taskFileKeyPath.RemoveAttribute('KeyPath')
        $taskGuidName = [Text.Encoding]::UTF8.GetBytes($taskComponent.GetAttribute('Id'))
        $taskGuidInput = New-Object byte[] ($taskGuidNamespace.Length + $taskGuidName.Length)
        [Array]::Copy($taskGuidNamespace, 0, $taskGuidInput, 0, $taskGuidNamespace.Length)
        [Array]::Copy($taskGuidName, 0, $taskGuidInput, $taskGuidNamespace.Length, $taskGuidName.Length)
        $taskSha1 = [Security.Cryptography.SHA1]::Create()
        try { $taskGuidBytes = [byte[]]$taskSha1.ComputeHash($taskGuidInput)[0..15] } finally { $taskSha1.Dispose() }
        $taskGuidBytes[6] = ($taskGuidBytes[6] -band 0x0f) -bor 0x50
        $taskGuidBytes[8] = ($taskGuidBytes[8] -band 0x3f) -bor 0x80
        $taskGuidHex = [BitConverter]::ToString($taskGuidBytes).Replace('-', '')
        $taskComponentGuid = '{' + $taskGuidHex.Substring(0, 8) + '-' + $taskGuidHex.Substring(8, 4) + '-' + $taskGuidHex.Substring(12, 4) + '-' + $taskGuidHex.Substring(16, 4) + '-' + $taskGuidHex.Substring(20, 12) + '}'
        $taskComponent.SetAttribute('Guid', $taskComponentGuid)
        $taskRegistryValue = $taskHarvestXml.CreateElement('RegistryValue', 'http://schemas.microsoft.com/wix/2006/wi')
        $taskRegistryValue.SetAttribute('Root', 'HKCU')
        $taskRegistryValue.SetAttribute('Key', ('Software\PersonalAddons\GeminiUsageAddon\Components\' + $taskComponent.GetAttribute('Id')))
        $taskRegistryValue.SetAttribute('Name', 'Installed')
        $taskRegistryValue.SetAttribute('Type', 'integer')
        $taskRegistryValue.SetAttribute('Value', '1')
        $taskRegistryValue.SetAttribute('KeyPath', 'yes')
        [void]$taskComponent.PrependChild($taskRegistryValue)
    }

    $taskFolderCleanupFragment = $taskHarvestXml.CreateElement('Fragment', 'http://schemas.microsoft.com/wix/2006/wi')
    $taskFolderCleanupGroup = $taskHarvestXml.CreateElement('ComponentGroup', 'http://schemas.microsoft.com/wix/2006/wi')
    $taskFolderCleanupGroup.SetAttribute('Id', 'AddonFolderCleanup')
    $taskFolderCleanupFragment.AppendChild($taskFolderCleanupGroup) | Out-Null
    $taskFolderNodes = @($taskHarvestXml.SelectNodes('//w:Directory', $taskXmlNamespace))
    foreach ($taskFolder in $taskFolderNodes) {
        $taskFolderId = $taskFolder.GetAttribute('Id')
        $taskFolderComponentId = 'folderCleanup_' + $taskFolderId
        $taskFolderGuidName = [Text.Encoding]::UTF8.GetBytes('Folder:' + $taskFolderId)
        $taskFolderGuidInput = New-Object byte[] ($taskGuidNamespace.Length + $taskFolderGuidName.Length)
        [Array]::Copy($taskGuidNamespace, 0, $taskFolderGuidInput, 0, $taskGuidNamespace.Length)
        [Array]::Copy($taskFolderGuidName, 0, $taskFolderGuidInput, $taskGuidNamespace.Length, $taskFolderGuidName.Length)
        $taskFolderSha1 = [Security.Cryptography.SHA1]::Create()
        try { $taskFolderGuidBytes = [byte[]]$taskFolderSha1.ComputeHash($taskFolderGuidInput)[0..15] } finally { $taskFolderSha1.Dispose() }
        $taskFolderGuidBytes[6] = ($taskFolderGuidBytes[6] -band 0x0f) -bor 0x50
        $taskFolderGuidBytes[8] = ($taskFolderGuidBytes[8] -band 0x3f) -bor 0x80
        $taskFolderGuidHex = [BitConverter]::ToString($taskFolderGuidBytes).Replace('-', '')
        $taskFolderComponentGuid = '{' + $taskFolderGuidHex.Substring(0, 8) + '-' + $taskFolderGuidHex.Substring(8, 4) + '-' + $taskFolderGuidHex.Substring(12, 4) + '-' + $taskFolderGuidHex.Substring(16, 4) + '-' + $taskFolderGuidHex.Substring(20, 12) + '}'

        $taskFolderComponent = $taskHarvestXml.CreateElement('Component', 'http://schemas.microsoft.com/wix/2006/wi')
        $taskFolderComponent.SetAttribute('Id', $taskFolderComponentId)
        $taskFolderComponent.SetAttribute('Guid', $taskFolderComponentGuid)
        $taskRemoveFolder = $taskHarvestXml.CreateElement('RemoveFolder', 'http://schemas.microsoft.com/wix/2006/wi')
        $taskRemoveFolder.SetAttribute('Id', ('Remove_' + $taskFolderComponentId))
        $taskRemoveFolder.SetAttribute('On', 'uninstall')
        [void]$taskFolderComponent.AppendChild($taskRemoveFolder)
        $taskFolderRegistryValue = $taskHarvestXml.CreateElement('RegistryValue', 'http://schemas.microsoft.com/wix/2006/wi')
        $taskFolderRegistryValue.SetAttribute('Root', 'HKCU')
        $taskFolderRegistryValue.SetAttribute('Key', ('Software\PersonalAddons\GeminiUsageAddon\Directories\' + $taskFolderId))
        $taskFolderRegistryValue.SetAttribute('Name', 'Installed')
        $taskFolderRegistryValue.SetAttribute('Type', 'integer')
        $taskFolderRegistryValue.SetAttribute('Value', '1')
        $taskFolderRegistryValue.SetAttribute('KeyPath', 'yes')
        [void]$taskFolderComponent.AppendChild($taskFolderRegistryValue)
        [void]$taskFolder.AppendChild($taskFolderComponent)

        $taskFolderComponentRef = $taskHarvestXml.CreateElement('ComponentRef', 'http://schemas.microsoft.com/wix/2006/wi')
        $taskFolderComponentRef.SetAttribute('Id', $taskFolderComponentId)
        [void]$taskFolderCleanupGroup.AppendChild($taskFolderComponentRef)
    }
    [void]$taskHarvestXml.DocumentElement.AppendChild($taskFolderCleanupFragment)
    $taskHarvestXml.Save($taskHarvestPath)

    $taskCandle = Join-Path $WixBin 'candle.exe'
    $taskCommonCandleArguments = @('-nologo', ('-dAddonSource=' + $taskStageAddon), ('-dProductVersion=' + $taskProductVersion))
    $taskMainCandleOutput = & $taskCandle @taskCommonCandleArguments '-out' $taskMainObjectPath $taskSourcePath 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskMainObjectPath -PathType Leaf)) {
        throw ('Compiling the MSI authoring failed: ' + ($taskMainCandleOutput -join "`n"))
    }
    $taskHarvestCandleOutput = & $taskCandle @taskCommonCandleArguments '-out' $taskHarvestObjectPath $taskHarvestPath 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskHarvestObjectPath -PathType Leaf)) {
        throw ('Compiling the harvested file list failed: ' + ($taskHarvestCandleOutput -join "`n"))
    }

    if (-not (Test-Path -LiteralPath $taskOutputDirectory)) {
        New-Item -ItemType Directory -Path $taskOutputDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $taskOutputPath) { Remove-Item -LiteralPath $taskOutputPath -Force }
    $taskLight = Join-Path $WixBin 'light.exe'
    $taskLightOutput = & $taskLight '-nologo' '-out' $taskOutputPath $taskMainObjectPath $taskHarvestObjectPath 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskOutputPath -PathType Leaf)) {
        $taskLightErrors = @($taskLightOutput | Where-Object { $_ -match 'error LGHT|error ICE' } | Select-Object -First 20)
        throw ('Linking the MSI package failed: ' + ($taskLightErrors -join "`n"))
    }

    $taskInstallCommandPath = Join-Path $taskOutputDirectory 'Install-GeminiUsageMonitor.cmd'
    $taskMsiFileName = [IO.Path]::GetFileName($taskOutputPath)
    $taskInstallCommand = @(
        '@echo off',
        'setlocal',
        ('set "MSI=%~dp0' + $taskMsiFileName + '"'),
        'if not exist "%MSI%" exit /b 2',
        'start /wait "" msiexec.exe /i "%MSI%"',
        'set "RESULT=%ERRORLEVEL%"',
        'if "%RESULT%"=="0" start "" "%LOCALAPPDATA%\GeminiUsageAddon\GeminiUsageAddon.exe"',
        'if "%RESULT%"=="3010" start "" "%LOCALAPPDATA%\GeminiUsageAddon\GeminiUsageAddon.exe"',
        'exit /b %RESULT%'
    ) -join "`r`n"
    [IO.File]::WriteAllText($taskInstallCommandPath, ($taskInstallCommand + "`r`n"), [Text.Encoding]::ASCII)

    Write-Output ('Created ' + $taskOutputPath)
    Write-Output ('Version: ' + $taskProductVersion)
    Write-Output ('Payload files: ' + (Get-ChildItem -LiteralPath $taskStageAddon -File -Recurse | Measure-Object).Count)
    Write-Output ('Installer helper: ' + $taskInstallCommandPath)
} finally {
    if (Test-Path -LiteralPath $taskBuildDirectory) { Remove-Item -LiteralPath $taskBuildDirectory -Recurse -Force }
}
