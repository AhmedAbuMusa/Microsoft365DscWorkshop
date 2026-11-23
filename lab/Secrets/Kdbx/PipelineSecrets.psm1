function ConvertTo-M365DscPipelineSecureString
{
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)][string]$Value)

    $secureValue = [securestring]::new()
    foreach ($character in $Value.ToCharArray())
    {
        $secureValue.AppendChar($character)
    }
    $secureValue.MakeReadOnly()
    return $secureValue
}

function ConvertFrom-M365DscPipelineMetadata
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $metadata = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($metadata -isnot [System.Collections.IDictionary] -or
        @($metadata.Keys | Where-Object { $_ -notin 'projectName', 'environments' }).Count -or
        [string]::IsNullOrWhiteSpace($metadata.projectName) -or $metadata.projectName -match '^<.+>$' -or
        $metadata.environments -isnot [System.Collections.IDictionary] -or $metadata.environments.Count -eq 0)
    {
        throw 'Invalid Kdbx pipeline metadata: only projectName and environments are allowed.'
    }
    foreach ($alias in $metadata.environments.Keys)
    {
        if ($alias -notmatch '^[A-Za-z][A-Za-z0-9_]*$')
        {
            throw "Invalid environment alias '$alias'."
        }
        $environment = $metadata.environments[$alias]
        $allowed = 'AzTenantName', 'AzTenantId', 'AzSubscriptionId', 'HasExchangeOnline', 'HasSharePointOnline', 'Identities'
        if ($environment -isnot [System.Collections.IDictionary] -or
            @($environment.Keys | Where-Object { $_ -notin $allowed }).Count -or
            $environment.AzTenantName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$' -or
            -not [guid]::TryParse([string]$environment.AzTenantId, [ref]([guid]::Empty)) -or
            ($environment.AzSubscriptionId -and -not [guid]::TryParse([string]$environment.AzSubscriptionId, [ref]([guid]::Empty))) -or
            $environment.HasExchangeOnline -isnot [bool] -or $environment.HasSharePointOnline -isnot [bool])
        {
            throw "Invalid allowlisted tenant metadata for '$alias'."
        }
        foreach ($identity in @($environment.Identities))
        {
            if ($identity -isnot [System.Collections.IDictionary] -or
                @($identity.Keys | Where-Object { $_ -notin 'Name', 'ApplicationId', 'CertificateThumbprint' }).Count -or
                [string]::IsNullOrWhiteSpace($identity.Name) -or
                -not [guid]::TryParse([string]$identity.ApplicationId, [ref]([guid]::Empty)) -or
                $identity.CertificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$')
            {
                throw "Invalid certificate-only identity metadata for '$alias'."
            }
        }
        foreach ($identityName in 'M365DscLcmApplication', 'M365DscExportApplication')
        {
            if (@($environment.Identities | Where-Object Name -EQ $identityName).Count -ne 1)
            {
                throw "Exactly one '$identityName' certificate identity is required for '$alias'."
            }
        }
    }
    return $metadata
}

function Update-M365DscDatumFromPipelineMetadata
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Datum,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$EnvironmentName
    )

    $metadata = ConvertFrom-M365DscPipelineMetadata -Path $Path
    if ($metadata.environments.Count -ne 1 -or -not $metadata.environments.Contains($EnvironmentName))
    {
        throw "Kdbx pipeline metadata must contain only selected environment '$EnvironmentName'."
    }
    if (-not $Datum.Global.Azure.Environments.Contains($EnvironmentName))
    {
        throw "Environment '$EnvironmentName' is not configured in Datum."
    }
    $Datum.Global.ProjectSettings.ProjectName = $metadata.projectName
    $target = $Datum.Global.Azure.Environments[$EnvironmentName]
    foreach ($key in $metadata.environments[$EnvironmentName].Keys)
    {
        $target[$key] = $metadata.environments[$EnvironmentName][$key]
    }
    return $Datum
}

function Get-M365DscPipelineTenantIdentifierMap
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Path)

    $map = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $aliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $projectName = $null
    foreach ($metadataPath in $Path)
    {
        $metadata = ConvertFrom-M365DscPipelineMetadata -Path $metadataPath
        if ($projectName -and $projectName -ne $metadata.projectName)
        {
            throw 'Delta report metadata must belong to one project.'
        }
        $projectName = $metadata.projectName
        foreach ($alias in $metadata.environments.Keys)
        {
            if (-not $aliases.Add($alias))
            {
                throw "Duplicate metadata for environment '$alias'."
            }
            foreach ($identifier in $metadata.environments[$alias].AzTenantName, $metadata.environments[$alias].AzTenantId)
            {
                if ($map.Contains($identifier) -and $map[$identifier] -ne $alias)
                {
                    throw "Tenant identifier maps to more than one environment."
                }
                $map[$identifier] = $alias
            }
        }
    }
    return $map
}

function Import-M365DscPipelineCertificate
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$ExpectedThumbprint,
        [ValidateSet('CurrentUser', 'LocalMachine')][string]$StoreLocation = 'CurrentUser'
    )

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        [System.IO.File]::ReadAllBytes($Path), $Password,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    try
    {
        if (-not $certificate.HasPrivateKey -or $certificate.Thumbprint -ne $ExpectedThumbprint)
        {
            throw 'The downloaded PFX does not match the selected certificate identity.'
        }
        if ($certificate.NotAfter -le [datetime]::Now -or $certificate.NotBefore -gt [datetime]::Now)
        {
            throw 'The downloaded certificate is not currently valid.'
        }
        $storePath = "Cert:\$StoreLocation\My\$($certificate.Thumbprint)"
        $existing = Test-Path -LiteralPath $storePath
        if ($existing -and -not (Get-Item -LiteralPath $storePath).HasPrivateKey)
        {
            throw 'An existing certificate has no private key; refusing to overwrite it.'
        }
        if (-not $existing)
        {
            Import-PfxCertificate -FilePath $Path -Password $Password -CertStoreLocation "Cert:\$StoreLocation\My" -ErrorAction Stop | Out-Null
        }
        return @{ Path = $storePath; Imported = -not $existing; Thumbprint = $certificate.Thumbprint }
    }
    finally
    {
        $certificate.Dispose()
    }
}

function Remove-M365DscPipelineCertificate
{
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Certificate)
    if ($Certificate.Imported)
    {
        Remove-Item -LiteralPath $Certificate.Path -DeleteKey -ErrorAction Stop
    }
}

function Set-M365DscPipelineResourceAuthorization
{
    param([string]$BaseUri, [hashtable]$Headers, [string]$ResourceType, [string]$ResourceId, [int[]]$PipelineId)
    $uri = "$BaseUri/_apis/pipelines/pipelinepermissions/$ResourceType/${ResourceId}?api-version=7.1-preview.1"
    $existing = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
    $ids = @(@($existing.pipelines | ForEach-Object { [int]$_.id }) + $PipelineId | Sort-Object -Unique)
    $permissions = @{
        allPipelines = @{ authorized = $false }
        pipelines = @($ids | ForEach-Object { @{ id = $_; authorized = $_ -in $PipelineId } })
    }
    Invoke-RestMethod -Uri $uri -Headers $Headers -Method Patch -ContentType 'application/json' `
        -Body ($permissions | ConvertTo-Json -Depth 10 -Compress) -ErrorAction Stop | Out-Null
}

function Publish-M365DscKdbxPipelineSecrets
{
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Datum,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')][string]$EnvironmentName,
        [int[]]$TrustedPipelineId,
        [switch]$IncludeLcmCertificate
    )

    $Datum = Get-M365DscKdbxProjectSettings -Datum $Datum
    $Datum = Update-M365DscDatumFromKdbx -Datum $Datum -EnvironmentName $EnvironmentName
    $settings = $Datum.Global.ProjectSettings
    foreach ($name in 'OrganizationName', 'ProjectName', 'PersonalAccessToken', 'AgentPoolName')
    {
        if ([string]::IsNullOrWhiteSpace([string]$settings[$name]) -or [string]$settings[$name] -match '^<.+>$')
        {
            throw "Private project setting '$name' is required in Kdbx."
        }
    }
    $pat = if ($settings.PersonalAccessToken -is [securestring])
    {
        [System.Net.NetworkCredential]::new('', $settings.PersonalAccessToken).Password
    }
    else { [string]$settings.PersonalAccessToken }
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$pat")) }
    $organizationUri = "https://dev.azure.com/$([uri]::EscapeDataString($settings.OrganizationName))"
    $baseUri = "$organizationUri/$([uri]::EscapeDataString($settings.ProjectName))"
    $project = Invoke-RestMethod -Uri "$organizationUri/_apis/projects/$([uri]::EscapeDataString($settings.ProjectName))?api-version=7.1" -Headers $headers -ErrorAction Stop
    $definitions = @( (Invoke-RestMethod -Uri "$baseUri/_apis/build/definitions?api-version=7.1" -Headers $headers -ErrorAction Stop).value )
    if (-not $TrustedPipelineId)
    {
        $trustedNames = 'M365DSC build', 'M365DSC export', 'M365DSC deltaReport', 'M365DSC push', 'M365DSC reapply', 'M365DSC test'
        $trustedDefinitions = @($definitions | Where-Object { $_.name -in $trustedNames })
        foreach ($definition in $trustedDefinitions)
        {
            $expectedPath = "pipelines/Kdbx/$($definition.name.Substring('M365DSC '.Length)).yml"
            $detail = Invoke-RestMethod -Uri "$baseUri/_apis/build/definitions/$($definition.id)?api-version=7.1" -Headers $headers -ErrorAction Stop
            $path = ([string]$detail.process.yamlFilename).Replace('\', '/').TrimStart('/')
            if ($path -ne $expectedPath)
            {
                throw "Pipeline '$($definition.name)' does not use '$expectedPath'; refusing to authorize an existing Key Vault pipeline."
            }
        }
        $TrustedPipelineId = @($trustedDefinitions | ForEach-Object { [int]$_.id })
    }
    if (-not $TrustedPipelineId -or @($TrustedPipelineId | Where-Object { $_ -le 0 -or $_ -notin $definitions.id }).Count)
    {
        throw 'Supply existing explicit TrustedPipelineId values, or create trusted M365DSC workshop pipelines with pipelines/Kdbx entry points first.'
    }
    $TrustedPipelineId = @($TrustedPipelineId | Sort-Object -Unique)
    $source = $Datum.Global.Azure.Environments[$EnvironmentName]
    $publicEnvironment = @{}
    foreach ($name in 'AzTenantName', 'AzTenantId', 'AzSubscriptionId', 'HasExchangeOnline', 'HasSharePointOnline')
    {
        $publicEnvironment[$name] = $source[$name]
    }
    $publicEnvironment.Identities = @(
        foreach ($identity in $source.Identities)
        {
            if ($identity.Name -in 'M365DscLcmApplication', 'M365DscExportApplication')
            {
                @{ Name = $identity.Name; ApplicationId = $identity.ApplicationId; CertificateThumbprint = $identity.CertificateThumbprint }
            }
        }
    )
    $prefix = "M365DSC-$EnvironmentName-Kdbx"
    $workingDirectory = Join-Path -Path (Get-Location).Path -ChildPath ".kdbx-publish-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $workingDirectory -ItemType Directory -ErrorAction Stop | Out-Null
    try
    {
        if ($IsWindows)
        {
            $acl = Get-Acl -LiteralPath $workingDirectory
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $workingDirectory -AclObject $acl -ErrorAction Stop
        }
        $metadataName = "$prefix.metadata.json"
        $metadataPath = Join-Path $workingDirectory $metadataName
        @{ projectName = $settings.ProjectName; environments = @{ $EnvironmentName = $publicEnvironment } } |
            ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $metadataPath -Encoding utf8 -ErrorAction Stop
        ConvertFrom-M365DscPipelineMetadata -Path $metadataPath | Out-Null
        $files = @(@{ Name = $metadataName; Path = $metadataPath })
        $variables = @{
            M365DSC_METADATA_FILE = @{ value = $metadataName; isSecret = $false }
            M365DSC_AGENT_POOL = @{ value = [string]$settings.AgentPoolName; isSecret = $false }
        }
        $identityTypes = @('Export')
        if ($IncludeLcmCertificate) { $identityTypes += 'Lcm' }
        foreach ($type in $identityTypes)
        {
            $certificate = Get-M365DscStoredCertificate -EnvironmentName $EnvironmentName -IdentityName "M365Dsc${type}Application"
            $identity = @($publicEnvironment.Identities | Where-Object Name -EQ "M365Dsc${type}Application")[0]
            if (-not $certificate.Pfx -or $certificate.Password -isnot [securestring] -or
                $certificate.Password.Length -eq 0 -or $certificate.Thumbprint -ne $identity.CertificateThumbprint)
            {
                throw "Stored $type certificate does not match metadata for '$EnvironmentName'."
            }
            $fileName = "$prefix.$type.pfx"
            $filePath = Join-Path $workingDirectory $fileName
            [System.IO.File]::WriteAllBytes($filePath, [byte[]]$certificate.Pfx)
            $pfxCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                [byte[]]$certificate.Pfx, $certificate.Password,
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
            try
            {
                if (-not $pfxCertificate.HasPrivateKey -or $pfxCertificate.Thumbprint -ne $identity.CertificateThumbprint)
                {
                    throw "Stored $type PFX does not contain the matching private key."
                }
            }
            finally { $pfxCertificate.Dispose() }
            $files += @{ Name = $fileName; Path = $filePath }
            $variablePrefix = "M365DSC_$($type.ToUpperInvariant())_PFX"
            $variables["${variablePrefix}_FILE"] = @{ value = $fileName; isSecret = $false }
            $variables["${variablePrefix}_PASSWORD"] = @{
                value = [System.Net.NetworkCredential]::new('', $certificate.Password).Password
                isSecret = $true
            }
        }
        $secureFilesUri = "$baseUri/_apis/distributedtask/securefiles"
        $existingFiles = @((Invoke-RestMethod -Uri "${secureFilesUri}?api-version=7.1-preview.1" -Headers $headers -ErrorAction Stop).value)
        foreach ($file in $files)
        {
            foreach ($existing in @($existingFiles | Where-Object name -EQ $file.Name))
            {
                Invoke-RestMethod -Uri "$secureFilesUri/$($existing.id)?api-version=7.1-preview.1" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
            }
            $uploaded = Invoke-RestMethod -Uri "${secureFilesUri}?name=$([uri]::EscapeDataString($file.Name))&api-version=7.1-preview.1" `
                -Headers $headers -Method Post -ContentType 'application/octet-stream' -InFile $file.Path -ErrorAction Stop
            Set-M365DscPipelineResourceAuthorization -BaseUri $baseUri -Headers $headers -ResourceType securefile -ResourceId $uploaded.id -PipelineId $TrustedPipelineId
        }
        $groupsUri = "$baseUri/_apis/distributedtask/variablegroups"
        $existingGroups = @((Invoke-RestMethod -Uri "${groupsUri}?groupName=$([uri]::EscapeDataString($prefix))&api-version=7.1" -Headers $headers -ErrorAction Stop).value |
            Where-Object name -EQ $prefix)
        if ($existingGroups.Count -gt 1) { throw "Multiple variable groups named '$prefix'." }
        $body = @{
            name = $prefix; type = 'Vsts'; variables = $variables
            description = 'Explicitly selected Kdbx native pipeline delivery; no database or unlock credentials.'
            variableGroupProjectReferences = @(@{ name = $prefix; projectReference = @{ id = $project.id; name = $settings.ProjectName } })
        }
        $group = if ($existingGroups.Count)
        {
            Invoke-RestMethod -Uri "$organizationUri/_apis/distributedtask/variablegroups/$($existingGroups[0].id)?api-version=7.1" `
                -Headers $headers -Method Put -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 12 -Compress) -ErrorAction Stop
        }
        else
        {
            Invoke-RestMethod -Uri "${groupsUri}?api-version=7.1" -Headers $headers -Method Post -ContentType 'application/json' `
                -Body ($body | ConvertTo-Json -Depth 12 -Compress) -ErrorAction Stop
        }
        Set-M365DscPipelineResourceAuthorization -BaseUri $baseUri -Headers $headers -ResourceType variablegroup -ResourceId $group.id -PipelineId $TrustedPipelineId
        return @{ VariableGroup = $prefix; SecureFiles = @($files.Name); PipelineIds = $TrustedPipelineId }
    }
    finally
    {
        $headers.Clear()
        $pat = $null
        if ($variables) { $variables.Clear() }
        Remove-Item -LiteralPath $workingDirectory -Recurse -Force -ErrorAction Stop
    }
}

Export-ModuleMember -Function ConvertTo-M365DscPipelineSecureString, ConvertFrom-M365DscPipelineMetadata, Update-M365DscDatumFromPipelineMetadata,
    Get-M365DscPipelineTenantIdentifierMap, Import-M365DscPipelineCertificate, Remove-M365DscPipelineCertificate,
    Publish-M365DscKdbxPipelineSecrets
