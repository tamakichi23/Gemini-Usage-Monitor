param(
    [string]$InstallRoot,
    [switch]$InstallStartup,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$taskAddonSource = $PSScriptRoot
$taskCollectorSource = Join-Path $PSScriptRoot 'collector'
if (-not $InstallRoot) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'GeminiUsageAddon' }
$taskInstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$taskCollectorTarget = Join-Path $taskInstallRoot 'collector'
$taskStartTarget = Join-Path $taskInstallRoot 'start-gemini-addon.ps1'
$taskUninstallTarget = Join-Path $taskInstallRoot 'uninstall-gemini-addon.ps1'
$taskLauncherSource = Join-Path $taskAddonSource 'GeminiUsageAddon.exe'
$taskLauncherTarget = Join-Path $taskInstallRoot 'GeminiUsageAddon.exe'
$taskLauncherIconSource = Join-Path $taskAddonSource 'GeminiUsageAddon.ico'
$taskLauncherIconTarget = Join-Path $taskInstallRoot 'GeminiUsageAddon.ico'
$taskLegacyUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GeminiUsageAddon'
$taskBundledDependency = Join-Path $taskCollectorSource 'node_modules\playwright-core'

if (-not (Test-Path -LiteralPath (Join-Path $taskCollectorSource 'package-lock.json'))) {
    throw 'The collector source package is missing.'
}

$taskActiveAddon = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($taskStartTarget) } |
    Select-Object -First 1
if ($taskActiveAddon) { throw 'Exit the running add-on before installing an update.' }
$taskActiveCollector = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains((Join-Path $taskCollectorTarget 'cli.mjs')) } |
    Select-Object -First 1
if ($taskActiveCollector) { throw 'Exit the running add-on before installing an update.' }

New-Item -ItemType Directory -Path $taskCollectorTarget -Force | Out-Null
foreach ($taskFile in @('cli.mjs', 'collector.mjs', 'diagnostics.mjs', 'parser.mjs', 'profile.mjs', 'package.json', 'package-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $taskCollectorSource $taskFile) -Destination (Join-Path $taskCollectorTarget $taskFile) -Force
}
if (Test-Path -LiteralPath $taskBundledDependency) {
    $taskTargetModules = Join-Path $taskCollectorTarget 'node_modules'
    New-Item -ItemType Directory -Path $taskTargetModules -Force | Out-Null
    Copy-Item -LiteralPath $taskBundledDependency -Destination $taskTargetModules -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $taskAddonSource 'start-gemini-addon.ps1') -Destination $taskStartTarget -Force
Copy-Item -LiteralPath (Join-Path $taskAddonSource 'uninstall-gemini-addon.ps1') -Destination $taskUninstallTarget -Force
if (Test-Path -LiteralPath $taskLauncherIconSource -PathType Leaf) {
    Copy-Item -LiteralPath $taskLauncherIconSource -Destination $taskLauncherIconTarget -Force
} else {
    Add-Type -AssemblyName System.Drawing
    $taskIconStream = [IO.File]::Open($taskLauncherIconTarget, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { [System.Drawing.SystemIcons]::Information.Save($taskIconStream) } finally { $taskIconStream.Dispose() }
}
if (Test-Path -LiteralPath $taskLauncherSource -PathType Leaf) {
    Copy-Item -LiteralPath $taskLauncherSource -Destination $taskLauncherTarget -Force
} elseif (-not (Test-Path -LiteralPath $taskLauncherTarget -PathType Leaf)) {
    $taskLauncherCode = Join-Path $taskAddonSource 'GeminiUsageAddon.cs'
    if (Test-Path -LiteralPath $taskLauncherCode -PathType Leaf) {
        $taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $taskCompiler -PathType Leaf)) {
            $taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
        }
        if (-not (Test-Path -LiteralPath $taskCompiler -PathType Leaf)) { throw 'The .NET Framework C# compiler is required to build the Windows launcher from source.' }
        $taskCompilerArguments = @('/nologo', '/target:winexe', '/platform:x64', '/optimize+', ('/win32icon:' + $taskLauncherIconTarget), ('/out:' + $taskLauncherTarget), $taskLauncherCode)
        $taskCompilerOutput = & $taskCompiler @taskCompilerArguments 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $taskLauncherTarget -PathType Leaf)) {
            throw ('Compiling the Windows launcher failed: ' + ($taskCompilerOutput -join "`n"))
        }
    }
}
Copy-Item -LiteralPath (Join-Path $taskAddonSource 'README.md') -Destination (Join-Path $taskInstallRoot 'README.md') -Force

 $taskNodeCommand = Get-Command node -ErrorAction Stop
 $taskNodeVersion = & $taskNodeCommand.Source --version
if ($taskNodeVersion -notmatch '^v?(\d+)\.' -or [int]$Matches[1] -lt 22) {
    throw 'Gemini Usage Monitor requires Node.js 22 or newer.'
}
if (-not (Test-Path -LiteralPath (Join-Path $taskCollectorTarget 'node_modules\playwright-core\package.json'))) {
    Push-Location $taskCollectorTarget
    try {
        & npm ci --ignore-scripts
        if ($LASTEXITCODE -ne 0) { throw 'Installing the add-on collector dependency failed.' }
    } finally { Pop-Location }
}

$taskPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path -LiteralPath $taskLegacyUninstallKey) {
    $taskLegacyRoot = (Get-ItemProperty -LiteralPath $taskLegacyUninstallKey -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
    $taskLegacyUninstall = (Get-ItemProperty -LiteralPath $taskLegacyUninstallKey -Name 'UninstallString' -ErrorAction SilentlyContinue).UninstallString
    if ($taskLegacyRoot -and $taskLegacyUninstall -and $taskLegacyUninstall.Contains('GeminiUsageAddon.exe')) {
        $taskLegacyRoot = [IO.Path]::GetFullPath($taskLegacyRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        if ($taskLegacyRoot.Equals($taskInstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $taskLegacyUninstallKey -Recurse -Force
        }
    }
}

if ($InstallStartup) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $taskStartTarget -InstallStartup
    if ($LASTEXITCODE -ne 0) { throw 'Registering the add-on startup entry failed.' }
}

if ($Launch) {
    if (Test-Path -LiteralPath $taskLauncherTarget -PathType Leaf) {
        Start-Process -FilePath $taskLauncherTarget -WindowStyle Hidden | Out-Null
    } else {
        $taskLaunchArgs = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $taskStartTarget + '"'
        Start-Process -FilePath $taskPowerShell -ArgumentList $taskLaunchArgs -WindowStyle Hidden | Out-Null
    }
}

Write-Output ('Gemini Usage Monitor files installed at ' + $taskInstallRoot)
