function Initialize-M365DscBootstrapLog
{
    $directory = Join-Path $env:LOCALAPPDATA 'Microsoft365DscWorkshop\AzureLabBootstrap\Logs'
    $null = New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop
    $path = Join-Path $directory ("bootstrap-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N'))
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stream.Dispose()
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    foreach ($identity in $user, $system)
    {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $identity, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    }
    Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop
    return $path
}

function Write-M365DscBootstrapLog
{
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$Level = 'Detail'
    )
    $entry = "[{0}] [{1}] {2}{3}" -f [DateTimeOffset]::Now.ToString('o'), $Level, $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($LogPath, $entry, [Text.UTF8Encoding]::new($false))
}

function Write-M365DscBootstrapOutput
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)][AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$LogPath
    )
    process
    {
        if ($null -ne $InputObject)
        {
            $text = if ($InputObject -is [string] -or $InputObject -is [Management.Automation.InformationalRecord] -or
                $InputObject -is [Management.Automation.InformationRecord] -or $InputObject -is [Management.Automation.ErrorRecord])
            {
                [string]$InputObject
            }
            else { ($InputObject | Out-String -Width 240).TrimEnd() }
            $isNativeError = $InputObject -is [Management.Automation.ErrorRecord] -and
                $InputObject.FullyQualifiedErrorId -eq 'NativeCommandError'
            $level = if ($InputObject -is [Management.Automation.ErrorRecord] -and -not $isNativeError) { 'Error' }
                elseif ($InputObject -is [Management.Automation.WarningRecord]) { 'Warning' }
                else { 'Detail' }
            $logText = if ($text -match '(?i)To sign in.*code|devicelogin.*code|enter (the )?code')
            {
                'Interactive authentication instructions displayed; device code omitted from log.'
            }
            else { $text }
            Write-M365DscBootstrapLog -LogPath $LogPath -Level $level -Message $logText
            if ($level -eq 'Error')
            {
                Write-M365DscBootstrapLog -LogPath $LogPath -Level Error -Message (
                    "$($InputObject.Exception)`n$($InputObject.ScriptStackTrace)")
                Write-Host "ERROR: $text" -ForegroundColor Red
            }
            elseif ($level -eq 'Warning')
            {
                if ($text -notmatch 'names of some imported commands.*unapproved verbs|Module Version .*will stop supporting all TFS')
                {
                    Write-Host "WARNING: $text" -ForegroundColor Yellow
                }
            }
            elseif ($text -match '(?i)^\[Environment:|^\[\d+\]\s|^Select the Azure subscription|^Registering isolated|is still in progress \(elapsed:|Signing in to tenant|requires.*(authentication|sign-in)|Please select.*account|To sign in|devicelogin|microsoft\.com/link|enter (the )?code|^fatal:|^error:')
            {
                Write-Host $text -ForegroundColor Cyan
            }
        }
    }
}

Export-ModuleMember -Function Initialize-M365DscBootstrapLog,Write-M365DscBootstrapLog,Write-M365DscBootstrapOutput
