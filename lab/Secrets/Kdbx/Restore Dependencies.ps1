[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$manifest = Import-PowerShellDataFile $PSScriptRoot\Dependencies.psd1
$root = Join-Path $PSScriptRoot '..\..\..\output\Tools\Kdbx'
$packageRoot = Join-Path $root "$($manifest.Package).$($manifest.Version)"
$library = Join-Path $packageRoot 'lib\netstandard2.0\KeePassLib.dll'
if (Test-Path -LiteralPath $library)
{
    if ((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne $manifest.LibrarySha256)
    {
        throw 'The KDBX dependency failed its integrity check.'
    }
    return
}
$null = New-Item -Path $root -ItemType Directory -Force
$nuget = Join-Path $root "nuget-$($manifest.NuGetVersion).exe"
if (-not (Test-Path -LiteralPath $nuget))
{
    Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/v$($manifest.NuGetVersion)/nuget.exe" -OutFile $nuget
}
if ((Get-FileHash -LiteralPath $nuget -Algorithm SHA256).Hash -ne $manifest.NuGetSha256)
{
    throw 'The NuGet client failed its integrity check.'
}
& $nuget install $manifest.Package -Version $manifest.Version -Source https://api.nuget.org/v3/index.json `
    -OutputDirectory $root -NonInteractive -DirectDownload -DependencyVersion Lowest -Verbosity quiet
if ($LASTEXITCODE) { throw "KDBX dependency restoration failed with exit code $LASTEXITCODE." }
$package = Join-Path $packageRoot "$($manifest.Package).$($manifest.Version).nupkg"
if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -ne $manifest.PackageSha256 -or
    (Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne $manifest.LibrarySha256)
{
    throw 'The KDBX package failed its integrity check.'
}
