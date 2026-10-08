param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$taskAddonSource = $PSScriptRoot
$taskCollectorSource = Join-Path $taskAddonSource 'collector'
$taskLauncherSource = Join-Path $taskAddonSource 'GeminiUsageAddon.cs'
$taskRepoRoot = [IO.Path]::GetFullPath($taskAddonSource)
$taskTargetRoot = Join-Path $taskRepoRoot 'target'
$taskProductVersion = (Get-Content -LiteralPath (Join-Path $taskRepoRoot 'VERSION') -Raw).Trim()
if (-not $taskProductVersion) { throw 'VERSION is empty.' }
if (-not $OutputPath) { $OutputPath = Join-Path $taskTargetRoot ('GeminiUsageMonitor-' + $taskProductVersion + '.zip') }
$taskOutputPath = [IO.Path]::GetFullPath($OutputPath)
$taskOutputDirectory = Split-Path -Parent $taskOutputPath

if (-not (Test-Path -LiteralPath $taskTargetRoot)) {
    New-Item -ItemType Directory -Path $taskTargetRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $taskCollectorSource)) { throw 'The collector source directory is missing.' }
if (-not (Test-Path -LiteralPath (Join-Path $taskCollectorSource 'node_modules\playwright-core\package.json'))) {
    throw 'Run npm ci --ignore-scripts in the collector folder before packaging.'
}
if (-not (Test-Path -LiteralPath $taskLauncherSource -PathType Leaf)) { throw 'The add-on launcher source is missing.' }

$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $taskCompiler -PathType Leaf)) {
    $taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $taskCompiler -PathType Leaf)) { throw 'The .NET Framework C# compiler is required to package the Windows launcher.' }
$taskLauncherBuildDirectory = Join-Path $env:TEMP ('GeminiUsageAddon-build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskLauncherBuildDirectory | Out-Null
$taskLauncherBuildPath = Join-Path $taskLauncherBuildDirectory 'GeminiUsageAddon.exe'
$taskLauncherIconBuildPath = Join-Path $taskLauncherBuildDirectory 'GeminiUsageAddon.ico'
Add-Type -AssemblyName System.Drawing
$taskIconStream = [IO.File]::Open($taskLauncherIconBuildPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { [System.Drawing.SystemIcons]::Information.Save($taskIconStream) } finally { $taskIconStream.Dispose() }
$taskCompilerArguments = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', ('/win32icon:' + $taskLauncherIconBuildPath), ('/out:' + $taskLauncherBuildPath), $taskLauncherSource)
$taskCompilerOutput = & $taskCompiler @taskCompilerArguments 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskLauncherBuildPath -PathType Leaf)) {
    throw ('Compiling the Windows launcher failed: ' + ($taskCompilerOutput -join "`n"))
}

$taskFiles = @(
    @{ Source = Join-Path $taskAddonSource 'install-gemini-addon.ps1'; Entry = 'GeminiUsageAddon\install-gemini-addon.ps1' },
    @{ Source = Join-Path $taskAddonSource 'start-gemini-addon.ps1'; Entry = 'GeminiUsageAddon\start-gemini-addon.ps1' },
    @{ Source = Join-Path $taskAddonSource 'uninstall-gemini-addon.ps1'; Entry = 'GeminiUsageAddon\uninstall-gemini-addon.ps1' },
    @{ Source = Join-Path $taskAddonSource 'README.md'; Entry = 'GeminiUsageAddon\README.md' },
    @{ Source = Join-Path $taskAddonSource 'LICENSE'; Entry = 'GeminiUsageAddon\LICENSE' },
    @{ Source = Join-Path $taskAddonSource 'THIRD_PARTY_NOTICES.md'; Entry = 'GeminiUsageAddon\THIRD_PARTY_NOTICES.md' },
    @{ Source = Join-Path $taskAddonSource 'licenses\playwright-core\LICENSE'; Entry = 'GeminiUsageAddon\licenses\playwright-core\LICENSE' },
    @{ Source = Join-Path $taskAddonSource 'licenses\playwright-core\NOTICE'; Entry = 'GeminiUsageAddon\licenses\playwright-core\NOTICE' },
    @{ Source = $taskLauncherIconBuildPath; Entry = 'GeminiUsageAddon\GeminiUsageAddon.ico' },
    @{ Source = $taskLauncherBuildPath; Entry = 'GeminiUsageAddon\GeminiUsageAddon.exe' }
)
foreach ($taskName in @('cli.mjs', 'collector.mjs', 'diagnostics.mjs', 'parser.mjs', 'profile.mjs', 'package.json', 'package-lock.json')) {
    $taskFiles += @{ Source = Join-Path $taskCollectorSource $taskName; Entry = ('GeminiUsageAddon\collector\' + $taskName) }
}
Get-ChildItem -LiteralPath (Join-Path $taskCollectorSource 'node_modules\playwright-core') -File -Recurse | ForEach-Object {
    $taskRelativePath = $_.FullName.Substring((Join-Path $taskCollectorSource 'node_modules').Length).TrimStart('\')
    $taskFiles += @{ Source = $_.FullName; Entry = ('GeminiUsageAddon\collector\node_modules\' + $taskRelativePath) }
}
foreach ($taskFile in $taskFiles) {
    if (-not (Test-Path -LiteralPath $taskFile.Source -PathType Leaf)) { throw ('Package input is missing: ' + $taskFile.Source) }
}

if (-not (Test-Path -LiteralPath $taskOutputDirectory)) {
    New-Item -ItemType Directory -Path $taskOutputDirectory -Force | Out-Null
}
if (Test-Path -LiteralPath $taskOutputPath) { Remove-Item -LiteralPath $taskOutputPath -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$taskArchive = [IO.Compression.ZipFile]::Open($taskOutputPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($taskFile in $taskFiles) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($taskArchive, $taskFile.Source, $taskFile.Entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally { $taskArchive.Dispose() }

$taskCheck = [IO.Compression.ZipFile]::OpenRead($taskOutputPath)
try {
    $taskRequired = @('GeminiUsageAddon\install-gemini-addon.ps1', 'GeminiUsageAddon\start-gemini-addon.ps1', 'GeminiUsageAddon\uninstall-gemini-addon.ps1', 'GeminiUsageAddon\GeminiUsageAddon.exe', 'GeminiUsageAddon\GeminiUsageAddon.ico', 'GeminiUsageAddon\LICENSE', 'GeminiUsageAddon\THIRD_PARTY_NOTICES.md', 'GeminiUsageAddon\licenses\playwright-core\LICENSE', 'GeminiUsageAddon\licenses\playwright-core\NOTICE', 'GeminiUsageAddon\collector\cli.mjs', 'GeminiUsageAddon\collector\node_modules\playwright-core\package.json')
    $taskEntries = @($taskCheck.Entries | ForEach-Object { $_.FullName })
    foreach ($taskEntry in $taskRequired) {
        if ($taskEntry -notin $taskEntries) { throw ('The package is missing required entry: ' + $taskEntry) }
    }
} finally { $taskCheck.Dispose() }

Write-Output ('Created ' + $taskOutputPath)
