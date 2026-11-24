[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Source and imported checkouts share one explicitly closed operator session.')]
param()
$ErrorActionPreference = 'Stop'

function ConvertTo-M365DscKdbxSecureString
{
    param([Parameter(Mandatory)][string]$Value)
    $result = [securestring]::new()
    foreach ($character in $Value.ToCharArray()) { $result.AppendChar($character) }
    $result.MakeReadOnly()
    return $result
}

function Import-KdbxLibrary
{
    $manifest = Import-PowerShellDataFile $PSScriptRoot\Dependencies.psd1
    $root = Join-Path $PSScriptRoot '..\..\..\output\Tools\Kdbx'
    $library = Join-Path $root "$($manifest.Package).$($manifest.Version)\lib\netstandard2.0\KeePassLib.dll"
    if (-not (Test-Path -LiteralPath $library)) { throw 'Restore KDBX dependencies before opening the store.' }
    if ((Get-FileHash -LiteralPath $library -Algorithm SHA256).Hash -ne $manifest.LibrarySha256)
    {
        throw 'The KDBX library failed its integrity check.'
    }
    $loaded = 'KeePassLib.PwDatabase' -as [type]
    if ($loaded)
    {
        if ((Get-FileHash -LiteralPath $loaded.Assembly.Location -Algorithm SHA256).Hash -ne $manifest.LibrarySha256)
        {
            throw 'Another KeePass library is already loaded. Start a fresh PowerShell session.'
        }
        return
    }
    $assemblies = [Collections.Generic.List[string]]::new()
    foreach ($package in Get-ChildItem -LiteralPath $root -Directory)
    {
        foreach ($framework in 'net10.0','net9.0','net8.0','net6.0','netstandard2.1','netstandard2.0','net462')
        {
            $folder = Join-Path $package.FullName "lib\$framework"
            if (-not (Test-Path -LiteralPath $folder)) { continue }
            foreach ($dll in Get-ChildItem -LiteralPath $folder -Filter '*.dll' -File) { $assemblies.Add($dll.FullName) }
            break
        }
    }
    if (-not ('Microsoft365DscWorkshop.KdbxAssemblyLoader' -as [type]))
    {
        Add-Type -Path $PSScriptRoot\AssemblyLoader.cs -ErrorAction Stop
    }
    [Microsoft365DscWorkshop.KdbxAssemblyLoader]::new($assemblies.ToArray()).LoadLibrary($library)
}

function Assert-KdbxExternalPath
{
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.DirectoryInfo]::new((Split-Path $fullPath -Parent))
    while ($directory)
    {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName '.git'))
        {
            throw 'KDBX databases and backups must be outside every Git checkout.'
        }
        if ($directory.Exists -and ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint))
        {
            throw 'KDBX paths cannot traverse symbolic links or junctions.'
        }
        $directory = $directory.Parent
    }
    if ((Test-Path -LiteralPath $fullPath) -and
        ((Get-Item -LiteralPath $fullPath).Attributes -band [IO.FileAttributes]::ReparsePoint))
    {
        throw 'The KDBX database cannot be a symbolic link.'
    }
    return $fullPath
}

function Close-M365DscSecretStore
{
    if ($global:M365DscKdbxStore)
    {
        try { $global:M365DscKdbxStore.Database.Close() }
        finally
        {
            $global:M365DscKdbxStore.Lock.Dispose()
            $global:M365DscKdbxStore = $null
        }
    }
}

function Open-M365DscSecretStore
{
    [CmdletBinding()]
    param(
        [string]$Path = $(if ($env:M365DSC_SECRET_STORE) { $env:M365DSC_SECRET_STORE }
            else { Join-Path $env:LOCALAPPDATA 'Microsoft365DscWorkshop\Secrets\operator.kdbx' }),
        [securestring]$Password,
        [switch]$Create
    )
    $path = Assert-KdbxExternalPath $Path
    $exists = Test-Path -LiteralPath $path
    if ($Create -and $exists) { throw 'The operator database already exists; refusing to overwrite it.' }
    if ($global:M365DscKdbxStore)
    {
        if ($global:M365DscKdbxStore.Path -ne $path) { throw 'Close the current database before selecting another.' }
        return
    }
    if (-not $exists -and -not $Create) { throw 'Initialize a fresh KDBX database first; no Key Vault fallback is performed.' }
    Import-KdbxLibrary
    $ownsPassword = -not $Password
    while ($true)
    {
        if ($ownsPassword) { $Password = Read-Host 'KDBX database passphrase' -AsSecureString }
        $lock = $null
        $database = $null
        $bytes = $null
        try
        {
            if ($ownsPassword -and -not $Create -and $Password.Length -eq 0)
            {
                Write-Warning 'The KDBX passphrase cannot be empty. Try again, or press Ctrl+C to cancel.'
                continue
            }
            if ($Password.Length -eq 0 -or ($Create -and $Password.Length -lt 16))
            {
                throw 'A new KDBX database requires a passphrase of at least 16 characters.'
            }
            $directory = Split-Path $path -Parent
            $null = New-Item -Path $directory -ItemType Directory -Force
            $unexpectedFiles = @(Get-ChildItem -LiteralPath $directory -Force | Where-Object {
                    $_.Name -notin @((Split-Path $path -Leaf), ((Split-Path $path -Leaf) + '.bak'), ((Split-Path $path -Leaf) + '.lock'))
                })
            if ($unexpectedFiles.Count) { throw 'Use a dedicated directory containing only this database, its backup and lock.' }
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18')))
            {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
            Set-Acl -LiteralPath $directory -AclObject $acl
            $lock = [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $bytes = [Text.Encoding]::UTF8.GetBytes([Net.NetworkCredential]::new('', $Password).Password)
            $key = [KeePassLib.Keys.CompositeKey]::new()
            $key.AddUserKey([KeePassLib.Keys.KcpPassword]::new($bytes))
            $database = [KeePassLib.PwDatabase]::new()
            $connection = [KeePassLib.Serialization.IOConnectionInfo]::FromPath($path)
            if ($Create)
            {
                $database.New($connection, $key)
                $kdf = [KeePassLib.Cryptography.KeyDerivation.Argon2Kdf]::new([KeePassLib.Cryptography.KeyDerivation.Argon2Type]::ID)
                $database.KdfParameters = $kdf.GetDefaultParameters()
            }
            else { $database.Open($connection, $key, $null) }
            $global:M365DscKdbxStore = @{ Path = $path; Database = $database; Lock = $lock }
            $env:M365DSC_SECRET_STORE = $path
            if ($Create) { Set-M365DscSecretJson -Name '__manifest' -Value @{ SchemaVersion = 1; DeploymentId = [Guid]::NewGuid().ToString('N') } }
            $manifest = Get-KdbxJson '__manifest'
            if ($manifest.SchemaVersion -ne 1 -or -not $manifest.DeploymentId) { throw 'Unsupported or incomplete operator database manifest.' }
            return
        }
        catch
        {
            Close-M365DscSecretStore
            if ($database) { $database.Close() }
            if ($lock) { $lock.Dispose() }
            $exception = $_.Exception
            while ($exception -and $exception -isnot [KeePassLib.Keys.InvalidCompositeKeyException])
            {
                $exception = $exception.InnerException
            }
            if ($ownsPassword -and -not $Create -and $exception)
            {
                Write-Warning 'The KDBX passphrase was not accepted. Try again, or press Ctrl+C to cancel.'
                continue
            }
            throw [InvalidOperationException]::new('Could not open the KDBX database. Check its passphrase, integrity, permissions and lock.', $_.Exception)
        }
        finally
        {
            if ($bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
            if ($ownsPassword) { $Password.Dispose() }
        }
    }
}

function Get-KdbxEntry
{
    param([string]$Name)
    if (-not $global:M365DscKdbxStore) { Open-M365DscSecretStore }
    $entries = @($global:M365DscKdbxStore.Database.RootGroup.Entries | Where-Object { $_.Strings.ReadSafe('Title') -ceq $Name })
    if ($entries.Count -gt 1) { throw "Duplicate operator database records named '$Name'; refusing to select one." }
    return $entries | Select-Object -First 1
}

function Save-KdbxStore
{
    $state = $global:M365DscKdbxStore
    $temporaryPath = "$($state.Path).$([Guid]::NewGuid().ToString('N')).tmp"
    $verify = [KeePassLib.PwDatabase]::new()
    try
    {
        $connection = [KeePassLib.Serialization.IOConnectionInfo]::FromPath($temporaryPath)
        $state.Database.SaveAs($connection, $false, $null)
        $verify.Open($connection, $state.Database.MasterKey, $null)
        $verify.Close()
        if (Test-Path -LiteralPath $state.Path)
        {
            [IO.File]::Replace($temporaryPath, $state.Path, "$($state.Path).bak")
        }
        else { [IO.File]::Move($temporaryPath, $state.Path) }
    }
    finally
    {
        $verify.Close()
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -ErrorAction Stop }
    }
}

function Test-M365DscSecret
{
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-KdbxEntry $Name)
}

function Get-M365DscSecret
{
    param([Parameter(Mandatory)][string]$Name)
    $entry = Get-KdbxEntry $Name
    if (-not $entry) { throw "The operator database is missing record '$Name'." }
    return ConvertTo-M365DscKdbxSecureString $entry.Strings.ReadSafe('Password')
}

function Set-M365DscSecret
{
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][securestring]$Value, [byte[]]$Attachment)
    $old = Get-KdbxEntry $Name
    $entry = [KeePassLib.PwEntry]::new($true, $true)
    $entry.Strings.Set('Title', [KeePassLib.Security.ProtectedString]::new($false, $Name))
    $entry.Strings.Set('Password', [KeePassLib.Security.ProtectedString]::new($true, [Net.NetworkCredential]::new('', $Value).Password))
    if ($Attachment) { $entry.Binaries.Set('certificate.pfx', [KeePassLib.Security.ProtectedBinary]::new($true, $Attachment)) }
    $entries = $global:M365DscKdbxStore.Database.RootGroup.Entries
    if ($old) { $null = $entries.Remove($old) }
    $entries.Add($entry)
    try { Save-KdbxStore }
    catch
    {
        $null = $entries.Remove($entry)
        if ($old) { $entries.Add($old) }
        throw
    }
}

function Set-M365DscSecretJson
{
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object]$Value)
    $secureValue = ConvertTo-M365DscKdbxSecureString (ConvertTo-Json $Value -Depth 20 -Compress)
    try { Set-M365DscSecret -Name $Name -Value $secureValue }
    finally { $secureValue.Dispose() }
}

function Get-KdbxJson
{
    param([string]$Name)
    $value = Get-M365DscSecret $Name
    try { return [Net.NetworkCredential]::new('', $value).Password | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    finally { $value.Dispose() }
}

function Get-M365DscDeploymentId
{
    return (Get-KdbxJson '__manifest').DeploymentId
}

function Get-M365DscKdbxProjectSettings
{
    param([Parameter(Mandatory)][object]$Datum)
    $settings = Get-KdbxJson 'ProjectSettings'
    foreach ($field in 'OrganizationName','ProjectName','RepositoryName','LocalPath','AgentPoolName','PersonalAccessToken')
    {
        if ([string]::IsNullOrWhiteSpace($settings[$field])) { throw "The operator database is missing project setting '$field'." }
    }
    $target = $Datum.Global.ProjectSettings
    if ($target -isnot [Collections.IDictionary]) { throw 'Project settings must be a writable dictionary.' }
    foreach ($field in $settings.Keys) { $target[$field] = $settings[$field] }
    return $Datum
}

function Update-M365DscDatumFromKdbx
{
    param([Parameter(Mandatory)][object]$Datum, [string[]]$EnvironmentName, [switch]$IncludeCredentials, [string[]]$CredentialIdentityName)
    $names = @($Datum.Global.Azure.Environments.Keys)
    if ($EnvironmentName)
    {
        if (@($EnvironmentName | Where-Object { $_ -notin $names }).Count) { throw 'An unknown environment was requested.' }
        $names = @($names | Where-Object { $_ -in $EnvironmentName })
    }
    foreach ($name in $names)
    {
        $metadata = Get-KdbxJson "Environment/$name"
        if ($metadata.AzTenantName -ne $Datum.Global.Azure.Environments[$name].AzTenantName -or
            -not $metadata.AzTenantId -or -not $metadata.AzSubscriptionId -or -not $metadata.Identities)
        {
            throw "The encrypted metadata does not match environment '$name'."
        }
        $metadata.Identities = @($metadata.Identities | ForEach-Object { [pscustomobject]$_ })
        $Datum.Global.Azure.Environments[$name] = $metadata
    }
    return $Datum
}

function Get-M365DscStoredCertificate
{
    param([Parameter(Mandatory)][string]$EnvironmentName, [Parameter(Mandatory)][string]$IdentityName)
    $name = "Certificate/$EnvironmentName/$IdentityName"
    $entry = Get-KdbxEntry $name
    if (-not $entry -or -not $entry.Binaries.Get('certificate.pfx')) { throw "Missing certificate attachment for '$name'." }
    $password = Get-M365DscSecret $name
    $pfx = $entry.Binaries.Get('certificate.pfx').ReadData()
    $certificate = $null
    try
    {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $pfx, $password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le [DateTime]::Now -or $certificate.NotBefore -gt [DateTime]::Now)
        {
            throw "The certificate for '$name' is expired, not yet valid or has no private key."
        }
        return @{ Pfx = $pfx; Password = $password; Thumbprint = $certificate.Thumbprint }
    }
    catch
    {
        $password.Dispose()
        [Array]::Clear($pfx, 0, $pfx.Length)
        throw
    }
    finally { if ($certificate) { $certificate.Dispose() } }
}

Export-ModuleMember -Function Open-M365DscSecretStore,Close-M365DscSecretStore,Get-M365DscSecret,Set-M365DscSecret,Test-M365DscSecret,Set-M365DscSecretJson,Get-M365DscDeploymentId,Get-M365DscKdbxProjectSettings,Update-M365DscDatumFromKdbx,Get-M365DscStoredCertificate
