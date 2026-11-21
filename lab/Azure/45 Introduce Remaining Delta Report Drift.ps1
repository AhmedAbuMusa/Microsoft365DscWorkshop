<#
    .SYNOPSIS
        Adds reversible drift for the remaining exported identity resources in Test.

    .DESCRIPTION
        Avoids changing Security Defaults, the top-level authentication-method
        policy, or method states. It changes secondary settings only on methods
        that are already disabled, and creates isolated test named-location,
        disabled role, unassigned authentication-strength, and unavailable
        authentication-context resources. Disabled-method settings are dormant
        while disabled, but could become effective if the method is enabled later.
        Original values are saved locally and can be restored with -RestoreFrom.

    .EXAMPLE
        & '.\lab\Azure\45 Introduce Remaining Delta Report Drift.ps1' -WhatIf

        Previews dormant changes and inert test resources without applying them.

    .EXAMPLE
        & '.\lab\Azure\45 Introduce Remaining Delta Report Drift.ps1' -RestoreFrom '<rollback-file>'

        Restores saved dormant settings and removes created test resources.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Required for interactive change and rollback instructions')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Datum decrypts the protected app secret to a process-local string; Graph requires it as a SecureString in PSCredential')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param (
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Restore')]
    [ValidateSet('Test')]
    [string]$EnvironmentName = 'Test',

    [Parameter(Mandatory = $true, ParameterSetName = 'Restore')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RestoreFrom
)

$ErrorActionPreference = 'Stop'

$requiredModulesPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\output\RequiredModules'
if (-not (Test-Path -LiteralPath $requiredModulesPath -PathType Container))
{
    throw "Required modules were not found at '$requiredModulesPath'. Run the repository build to restore dependencies first."
}

$requiredModulesPath = (Resolve-Path -LiteralPath $requiredModulesPath -ErrorAction Stop).Path
if ($env:PSModulePath -notlike "*$requiredModulesPath*")
{
    $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $requiredModulesPath
}

$loadedGraphModules = @(Get-Module -Name 'Microsoft.Graph.*')
$loadedGraphAssemblies = @(
    [AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -like 'Microsoft.Graph.*' } |
        ForEach-Object { '{0} {1}' -f $_.GetName().Name, $_.GetName().Version }
)
if ($loadedGraphModules.Count -gt 0 -or $loadedGraphAssemblies.Count -gt 0)
{
    $loadedComponents = @(
        $loadedGraphModules | ForEach-Object { '{0} {1}' -f $_.Name, $_.Version }
        $loadedGraphAssemblies
    ) | Sort-Object -Unique
    $powerShell = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction Stop
    $childArguments = @('-NoLogo', '-NoProfile', '-File', $PSCommandPath)
    foreach ($parameterName in $PSBoundParameters.Keys)
    {
        $parameterValue = $PSBoundParameters[$parameterName]
        if ($parameterValue -is [bool] -or $parameterValue -is [System.Management.Automation.SwitchParameter])
        {
            if ($parameterValue)
            {
                $childArguments += "-$parameterName"
            }
            else
            {
                $childArguments += "-${parameterName}:`$false"
            }
        }
        else
        {
            $childArguments += "-$parameterName"
            $childArguments += [string]$parameterValue
        }
    }

    Write-Output "Microsoft Graph components are already loaded in this PowerShell process ($($loadedComponents -join ', ')); continuing in an isolated PowerShell 7 process without profiles."
    & $powerShell.Source @childArguments
    $childExitCode = $LASTEXITCODE
    if ($childExitCode -ne 0)
    {
        throw "The isolated drift script process exited with code $childExitCode."
    }
    return
}

Import-Module -Name Datum -ErrorAction Stop
Import-Module -Name Microsoft.Graph.Authentication -RequiredVersion '2.41.1' -ErrorAction Stop

$datum = New-DatumStructure -DefinitionFile (Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Datum.yml')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'AzHelpers.psm1') -Force -ErrorAction Stop
Update-M365DscDatumFromKeyVault `
    -Datum $datum `
    -ProjectName $datum.Global.ProjectSettings.ProjectName `
    -EnvironmentName $EnvironmentName `
    -IncludeCredentials `
    -CredentialIdentityName 'M365DscSetupApplication' | Out-Null
$environment = $datum.Global.Azure.Environments."$EnvironmentName"
if (-not $environment -or -not $environment.AzTenantId)
{
    throw "Environment '$EnvironmentName' does not have tenant metadata in Key Vault. Run '10 Setup App Registrations.ps1' first."
}
$setupIdentities = @($environment.Identities | Where-Object Name -EQ 'M365DscSetupApplication')
if ($setupIdentities.Count -ne 1 -or
    -not $setupIdentities[0].ApplicationId -or
    -not $setupIdentities[0].ApplicationSecret -or
    $setupIdentities[0].ApplicationSecret -eq '<AutoGeneratedLater>')
{
    throw "Exactly one 'M365DscSetupApplication' with an application ID and secret must exist in Key Vault for environment '$EnvironmentName'. Run '10 Setup App Registrations.ps1' first."
}

$requiredResources = @(
    'AADSecurityDefaults',
    'AADNamedLocationPolicy',
    'AADRoleDefinition',
    'AADAuthenticationMethodPolicy',
    'AADAuthenticationMethodPolicyAuthenticator',
    'AADAuthenticationMethodPolicyEmail',
    'AADAuthenticationMethodPolicyExternal',
    'AADAuthenticationMethodPolicyFido2',
    'AADAuthenticationMethodPolicyHardware',
    'AADAuthenticationMethodPolicyQRCodeImage',
    'AADAuthenticationMethodPolicySms',
    'AADAuthenticationMethodPolicySoftware',
    'AADAuthenticationMethodPolicyTemporary',
    'AADAuthenticationMethodPolicyVoice',
    'AADAuthenticationMethodPolicyX509',
    'AADAuthenticationStrengthPolicy',
    'AADAuthenticationContextClassReference'
)
$exportConfigurationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\export\ExportConfiguration.yml'
foreach ($resourceName in $requiredResources)
{
    if (-not (Select-String -LiteralPath $exportConfigurationPath -Pattern ("^\s*-\s*$([regex]::Escape($resourceName))\s*$") -Quiet -ErrorAction Stop))
    {
        throw "$resourceName is not listed in '$exportConfigurationPath'; its drift would not appear in the delta report."
    }
}

$rollbackData = $null
if ($PSCmdlet.ParameterSetName -eq 'Restore')
{
    $rollbackData = Get-Content -LiteralPath $RestoreFrom -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($rollbackData.SchemaVersion -ne 1 -or
        $rollbackData.Environment -ne $EnvironmentName -or
        $rollbackData.TenantId -ne $environment.AzTenantId)
    {
        throw "Rollback file '$RestoreFrom' is not a supported backup for the configured '$EnvironmentName' tenant."
    }
}

$clientSecret = ConvertTo-M365DscSecureString -Value $setupIdentities[0].ApplicationSecret
$clientSecretCredential = [System.Management.Automation.PSCredential]::new($setupIdentities[0].ApplicationId, $clientSecret)
Connect-MgGraph -TenantId $environment.AzTenantId -ClientSecretCredential $clientSecretCredential -NoWelcome -ErrorAction Stop

function Invoke-GraphRequest
{
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [object]$Body
    )

    $request = @{
        Method      = $Method
        Uri         = $Uri
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body'))
    {
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
        $request.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @request
}

function Save-RollbackData
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Data
    )

    $Data | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
}

function Get-GraphObjectIfPresent
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    try
    {
        Invoke-GraphRequest -Method GET -Uri $Uri
    }
    catch
    {
        $statusCode = $_.Exception.ResponseStatusCode
        if (-not $statusCode) { $statusCode = $_.Exception.StatusCode }
        if ([int]$statusCode -eq 404) { return $null }
        throw
    }
}

function Restore-Drift
{
    param (
        [Parameter(Mandatory = $true)]
        [object]$Data,

        [switch]$SkipTargetValidation
    )

    $authenticationPolicyUri = 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy'
    $methodConfigurationUri = "$authenticationPolicyUri/authenticationMethodConfigurations"

    if (-not $SkipTargetValidation)
    {
        if ($Data.PSObject.Properties.Name -contains 'SecurityDefaultsOriginal')
        {
            $securityDefaultsUri = 'https://graph.microsoft.com/beta/policies/identitySecurityDefaultsEnforcementPolicy'
            $currentSecurityDefaults = Invoke-GraphRequest -Method GET -Uri $securityDefaultsUri
            if ($currentSecurityDefaults.isEnabled -notin @($Data.SecurityDefaultsTarget, $Data.SecurityDefaultsOriginal))
            {
                throw "Security defaults no longer match the saved values in '$($Data.RollbackPath)'; refusing to overwrite newer changes."
            }
        }

        if ($Data.PSObject.Properties.Name -contains 'AuthenticationPolicyOriginal')
        {
            $currentAuthenticationPolicy = Invoke-GraphRequest -Method GET -Uri $authenticationPolicyUri
            if ($currentAuthenticationPolicy.reconfirmationInDays -notin @($Data.AuthenticationPolicyTarget, $Data.AuthenticationPolicyOriginal))
            {
                throw "Authentication-method policy no longer matches the saved values in '$($Data.RollbackPath)'; refusing to overwrite newer changes."
            }
        }

        foreach ($change in $Data.MethodConfigurationChanges)
        {
            $escapedId = [uri]::EscapeDataString([string]$change.Id)
            $currentConfiguration = Invoke-GraphRequest -Method GET -Uri "$methodConfigurationUri/$escapedId"
            if ($change.ExpectedState -and $currentConfiguration.state -ne $change.ExpectedState)
            {
                throw "Authentication method '$($change.Id)' is no longer '$($change.ExpectedState)'; refusing to restore a dormant setting while the method is active."
            }
            if ($currentConfiguration.($change.Property) -notin @($change.TargetValue, $change.OriginalValue))
            {
                throw "Authentication-method configuration '$($change.Id)' no longer matches the drifted value; refusing to overwrite newer changes."
            }
        }
    }

    $createdResources = @(
        @{ Uri = 'https://graph.microsoft.com/beta/identity/conditionalAccess/namedLocations'; Id = $Data.CreatedNamedLocationId; Name = $Data.CreatedNamedLocationName },
        @{ Uri = 'https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions'; Id = $Data.CreatedRoleDefinitionId; Name = $Data.CreatedRoleDefinitionName },
        @{ Uri = 'https://graph.microsoft.com/beta/policies/authenticationStrengthPolicies'; Id = $Data.CreatedAuthenticationStrengthId; Name = $Data.CreatedAuthenticationStrengthName },
        @{ Uri = 'https://graph.microsoft.com/beta/identity/conditionalAccess/authenticationContextClassReferences'; Id = $Data.CreatedAuthenticationContextId; Name = $Data.CreatedAuthenticationContextName }
    )
    foreach ($created in $createdResources)
    {
        if ($created.Id)
        {
            $escapedId = [uri]::EscapeDataString([string]$created.Id)
            $existing = Get-GraphObjectIfPresent -Uri "$($created.Uri)/$escapedId"
            if ($existing -and $existing.displayName -ne $created.Name)
            {
                throw "Resource '$($created.Id)' no longer has the saved test name '$($created.Name)'; refusing to restore or delete resources."
            }

            $created.Exists = [bool]$existing
        }
    }

    foreach ($change in $Data.MethodConfigurationChanges)
    {
        $escapedId = [uri]::EscapeDataString([string]$change.Id)
        $currentConfiguration = Invoke-GraphRequest -Method GET -Uri "$methodConfigurationUri/$escapedId"
        if ($change.ExpectedState -and $currentConfiguration.state -ne $change.ExpectedState)
        {
            throw "Authentication method '$($change.Id)' is no longer '$($change.ExpectedState)'; refusing to restore a dormant setting while the method is active."
        }
        if ($currentConfiguration.($change.Property) -ne $change.OriginalValue)
        {
            $body = @{}
            $body[$change.Property] = $change.OriginalValue
            Invoke-GraphRequest -Method PATCH -Uri "$methodConfigurationUri/$escapedId" -Body $body | Out-Null
        }
    }

    if ($Data.PSObject.Properties.Name -contains 'AuthenticationPolicyOriginal')
    {
        $currentAuthenticationPolicy = Invoke-GraphRequest -Method GET -Uri $authenticationPolicyUri
        if ($currentAuthenticationPolicy.reconfirmationInDays -ne $Data.AuthenticationPolicyOriginal)
        {
            Invoke-GraphRequest -Method PATCH -Uri $authenticationPolicyUri -Body @{ reconfirmationInDays = $Data.AuthenticationPolicyOriginal } | Out-Null
        }
    }

    if ($Data.PSObject.Properties.Name -contains 'SecurityDefaultsOriginal')
    {
        $securityDefaultsUri = 'https://graph.microsoft.com/beta/policies/identitySecurityDefaultsEnforcementPolicy'
        $currentSecurityDefaults = Invoke-GraphRequest -Method GET -Uri $securityDefaultsUri
        if ($currentSecurityDefaults.isEnabled -ne $Data.SecurityDefaultsOriginal)
        {
            Invoke-GraphRequest -Method PATCH -Uri $securityDefaultsUri -Body @{ isEnabled = $Data.SecurityDefaultsOriginal } | Out-Null
        }
    }

    foreach ($created in $createdResources)
    {
        if ($created.Id -and $created.Exists)
        {
            $escapedId = [uri]::EscapeDataString([string]$created.Id)
            Invoke-GraphRequest -Method DELETE -Uri "$($created.Uri)/$escapedId" | Out-Null
        }
    }
}

try
{
    if ($PSCmdlet.ParameterSetName -eq 'Restore')
    {
        $rollbackData.RollbackPath = $RestoreFrom
        if ($PSCmdlet.ShouldProcess("$EnvironmentName tenant", 'Restore dormant authentication-method settings and remove test resources'))
        {
            Restore-Drift -Data $rollbackData
            Write-Host "Restored dormant authentication-method settings and removed the saved test resources in '$EnvironmentName'." -ForegroundColor Green
        }
    }
    else
    {
        $authenticationPolicyUri = 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy'
        $methodConfigurationUri = "$authenticationPolicyUri/authenticationMethodConfigurations"
        $authenticationPolicy = Invoke-GraphRequest -Method GET -Uri $authenticationPolicyUri
        $methodConfigurations = @($authenticationPolicy.authenticationMethodConfigurations)

        $resourceMap = @(
            @{ Resource = 'AADAuthenticationMethodPolicyAuthenticator'; Id = 'microsoftAuthenticator'; Property = 'isSoftwareOathEnabled'; Kind = 'boolean' },
            @{ Resource = 'AADAuthenticationMethodPolicyEmail'; Id = 'email'; Property = 'allowExternalIdToUseEmailOtp'; Kind = 'emailOtp' },
            @{ Resource = 'AADAuthenticationMethodPolicyExternal'; MatchType = '#microsoft.graph.externalAuthenticationMethodConfiguration'; Optional = $true },
            @{ Resource = 'AADAuthenticationMethodPolicyFido2'; Id = 'fido2'; Property = 'isSelfServiceRegistrationAllowed'; Kind = 'boolean' },
            @{ Resource = 'AADAuthenticationMethodPolicyHardware'; Id = 'hardwareOath' },
            @{ Resource = 'AADAuthenticationMethodPolicyQRCodeImage'; Id = 'qrCodePin'; Property = 'standardQRCodeLifetimeInDays'; Kind = 'smallLifetime' },
            @{ Resource = 'AADAuthenticationMethodPolicySms'; Id = 'sms' },
            @{ Resource = 'AADAuthenticationMethodPolicySoftware'; Id = 'softwareOath' },
            @{ Resource = 'AADAuthenticationMethodPolicyTemporary'; Id = 'temporaryAccessPass'; Property = 'defaultLifetimeInMinutes'; Kind = 'passLifetime' },
            @{ Resource = 'AADAuthenticationMethodPolicyVoice'; Id = 'voice' },
            @{ Resource = 'AADAuthenticationMethodPolicyX509'; Id = 'X509Certificate' }
        )

        $marker = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $methodChanges = @()
        $skippedResources = @(
            'AADSecurityDefaults (no writable non-security property)',
            'AADAuthenticationMethodPolicy (writable properties affect policy behavior)'
        )
        foreach ($resource in $resourceMap)
        {
            if ($resource.MatchType)
            {
                $matchingConfigurations = @($methodConfigurations | Where-Object { $_.'@odata.type' -eq $resource.MatchType } | Sort-Object -Property Id | Select-Object -First 1)
            }
            else
            {
                $matchingConfigurations = @($methodConfigurations | Where-Object { $_.id -eq $resource.Id })
            }

            if ($matchingConfigurations.Count -ne 1)
            {
                if ($resource.Optional -and $matchingConfigurations.Count -eq 0)
                {
                    $skippedResources += $resource.Resource
                    continue
                }

                throw "Expected one Graph authentication-method configuration '$($resource.Id)' for $($resource.Resource); found $($matchingConfigurations.Count). No changes were made."
            }

            $configuration = $matchingConfigurations[0]
            if (-not $resource.Property)
            {
                $skippedResources += "$($resource.Resource) (no safe secondary property)"
                continue
            }
            if ($configuration.state -ne 'disabled')
            {
                $skippedResources += "$($resource.Resource) (currently $($configuration.state); only already-disabled methods are changed)"
                continue
            }

            $originalValue = $configuration.($resource.Property)
            if ($resource.Kind -eq 'boolean')
            {
                if ($null -eq $originalValue)
                {
                    $skippedResources += "$($resource.Resource) ($($resource.Property) is unset)"
                    continue
                }
                $targetValue = -not [bool]$originalValue
            }
            elseif ($resource.Kind -eq 'emailOtp')
            {
                if ($originalValue -notin @('default', 'enabled', 'disabled', 'unknownFutureValue'))
                {
                    $skippedResources += "$($resource.Resource) ($($resource.Property) has unsupported value)"
                    continue
                }
                $targetValue = if ($originalValue -eq 'default') { 'disabled' } else { 'default' }
            }
            else
            {
                $currentLifetime = if ($null -eq $originalValue) { 0 } else { [int]$originalValue }
                $range = if ($resource.Kind -eq 'smallLifetime') { @(1, 31) } else { @(10, 43201) }
                $targetValue = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($range[0], $range[1])
                while ($targetValue -eq $currentLifetime)
                {
                    $targetValue = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($range[0], $range[1])
                }
            }

            $methodChanges += [ordered]@{
                Resource      = $resource.Resource
                Id            = [string]$configuration.id
                Property      = $resource.Property
                ExpectedState = 'disabled'
                OriginalValue = $originalValue
                TargetValue   = $targetValue
            }
        }

        $contextCollectionUri = 'https://graph.microsoft.com/beta/identity/conditionalAccess/authenticationContextClassReferences'
        $existingContexts = @( (Invoke-GraphRequest -Method GET -Uri $contextCollectionUri).value )
        $availableContextId = $null
        foreach ($contextNumber in 1..25)
        {
            $candidateContextId = "c$contextNumber"
            if (-not @($existingContexts | Where-Object Id -EQ $candidateContextId).Count)
            {
                $availableContextId = $candidateContextId
                break
            }
        }
        if (-not $availableContextId)
        {
            throw "No unused authentication-context reference ID is available in '$EnvironmentName'. No changes were made."
        }

        $rollbackDirectory = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft365DSC\DeltaReportRollback'
        $rollbackFileName = "DeltaReportRemainingRollback-$EnvironmentName-$marker-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $rollbackPath = Join-Path -Path $rollbackDirectory -ChildPath $rollbackFileName
        $rollbackData = [ordered]@{
            SchemaVersion = 1
            Environment = $EnvironmentName
            TenantId = [string]$environment.AzTenantId
            RollbackPath = $rollbackPath
            MethodConfigurationChanges = $methodChanges
            CreatedNamedLocationId = $null
            CreatedNamedLocationName = "DeltaReport-Test-$marker"
            CreatedRoleDefinitionId = $null
            CreatedRoleDefinitionName = "DeltaReport Test Role $marker"
            CreatedAuthenticationStrengthId = $null
            CreatedAuthenticationStrengthName = "DeltaTest-$marker"
            CreatedAuthenticationContextId = $null
            CreatedAuthenticationContextName = "DeltaReport Test Context $marker"
            CreatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }

        $operation = 'Change secondary settings on already-disabled methods and create inert test identity resources'
        if ($PSCmdlet.ShouldProcess("$EnvironmentName tenant", $operation))
        {
            New-Item -Path $rollbackDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Save-RollbackData -Path $rollbackPath -Data $rollbackData
            Write-Host "Saved original values to '$rollbackPath'." -ForegroundColor Yellow

            try
            {
                foreach ($change in $rollbackData.MethodConfigurationChanges)
                {
                    $escapedId = [uri]::EscapeDataString([string]$change.Id)
                    $currentConfiguration = Invoke-GraphRequest -Method GET -Uri "$methodConfigurationUri/$escapedId"
                    if ($currentConfiguration.state -ne 'disabled')
                    {
                        throw "Authentication method '$($change.Id)' is no longer disabled. No setting changes were applied to this method."
                    }
                    $body = @{}
                    $body[$change.Property] = $change.TargetValue
                    Invoke-GraphRequest -Method PATCH -Uri "$methodConfigurationUri/$escapedId" -Body $body | Out-Null
                }

                $namedLocation = Invoke-GraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/identity/conditionalAccess/namedLocations' -Body @{
                    '@odata.type' = '#microsoft.graph.ipNamedLocation'
                    displayName = $rollbackData.CreatedNamedLocationName
                    isTrusted = $false
                    ipRanges = @(
                        @{
                            '@odata.type' = '#microsoft.graph.iPv4CidrRange'
                            cidrAddress = '192.0.2.0/24'
                        }
                    )
                }
                $rollbackData.CreatedNamedLocationId = [string]$namedLocation.id
                if (-not $rollbackData.CreatedNamedLocationId) { throw 'Graph did not return an ID for the test named location.' }
                Save-RollbackData -Path $rollbackPath -Data $rollbackData

                $roleDefinition = Invoke-GraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/roleManagement/directory/roleDefinitions' -Body @{
                    displayName = $rollbackData.CreatedRoleDefinitionName
                    description = 'Disabled, unassignable test role for delta-report testing.'
                    isEnabled = $false
                    resourceScopes = @('/')
                    rolePermissions = @(@{ allowedResourceActions = @('microsoft.directory/applications/basic/read') })
                }
                $rollbackData.CreatedRoleDefinitionId = [string]$roleDefinition.id
                if (-not $rollbackData.CreatedRoleDefinitionId) { throw 'Graph did not return an ID for the disabled test role.' }
                Save-RollbackData -Path $rollbackPath -Data $rollbackData

                $strengthPolicy = Invoke-GraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/policies/authenticationStrengthPolicies' -Body @{
                    displayName = $rollbackData.CreatedAuthenticationStrengthName
                    description = 'Unassigned test policy for delta-report testing.'
                    allowedCombinations = @('password,microsoftAuthenticatorPush')
                }
                $rollbackData.CreatedAuthenticationStrengthId = [string]$strengthPolicy.id
                if (-not $rollbackData.CreatedAuthenticationStrengthId) { throw 'Graph did not return an ID for the test authentication-strength policy.' }
                Save-RollbackData -Path $rollbackPath -Data $rollbackData

                $context = Invoke-GraphRequest -Method POST -Uri $contextCollectionUri -Body @{
                    id = $availableContextId
                    displayName = $rollbackData.CreatedAuthenticationContextName
                    description = 'Unavailable test context for delta-report testing.'
                    isAvailable = $false
                }
                $rollbackData.CreatedAuthenticationContextId = [string]$context.id
                if (-not $rollbackData.CreatedAuthenticationContextId) { throw 'Graph did not return an ID for the unavailable test authentication context.' }
                Save-RollbackData -Path $rollbackPath -Data $rollbackData

                Write-Host "Introduced drift for the remaining exported resources in '$EnvironmentName'." -ForegroundColor Green
                if ($rollbackData.MethodConfigurationChanges.Count -gt 0)
                {
                    Write-Host 'Only secondary properties of methods already in disabled state were changed; those properties could take effect if a method is enabled later.' -ForegroundColor Yellow
                }
                Write-Host 'No Security Defaults, top-level authentication-method policy, or method state was changed.' -ForegroundColor Green
                if ($skippedResources.Count -gt 0)
                {
                    Write-Host "Skipped resources: $($skippedResources -join '; ')." -ForegroundColor Yellow
                }
                Write-Host "To undo it, run: .\lab\Azure\45 Introduce Remaining Delta Report Drift.ps1 -RestoreFrom '$rollbackPath'" -ForegroundColor Yellow
            }
            catch
            {
                $applyError = $_
                try
                {
                    Restore-Drift -Data $rollbackData -SkipTargetValidation
                }
                catch
                {
                    throw "Applying drift failed: $($applyError.Exception.Message) Automatic rollback also failed: $($_.Exception.Message). Use rollback file '$rollbackPath' after resolving the Graph error."
                }

                throw "Applying drift failed and automatic rollback was attempted: $($applyError.Exception.Message)"
            }
        }
        elseif ($WhatIfPreference)
        {
            Write-Host "WhatIf: would change secondary properties on $($methodChanges.Count) already-disabled authentication methods and create a named location, disabled role, unassigned authentication-strength policy, and unavailable authentication context." -ForegroundColor Yellow
            if ($skippedResources.Count -gt 0)
            {
                Write-Host "Skipped resources: $($skippedResources -join '; ')." -ForegroundColor Yellow
            }
            Write-Host 'No Security Defaults, top-level authentication-method policy, or method state would be changed. Dormant properties may become effective if their method is enabled later.' -ForegroundColor Yellow
        }
    }
}
finally
{
    Disconnect-MgGraph | Out-Null
}
