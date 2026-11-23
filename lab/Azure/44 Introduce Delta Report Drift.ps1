<#
    .SYNOPSIS
        Adds reversible delta-report drift to a test application and creates a disabled
        Conditional Access policy in the Test tenant when the tenant is licensed.

    .DESCRIPTION
        Appends a unique test marker to the Description and Notes of one explicitly
        named application, changes the two Group.Unified guidance URLs to reserved
        .invalid addresses, and creates a uniquely named Conditional Access policy
        in disabled state when Conditional Access is licensed; otherwise that
        resource's drift is explicitly skipped. It does not modify authentication-method settings or any
        policy enforcement controls. Original values and the created policy ID are
        saved locally and can be restored with -RestoreFrom.

    .EXAMPLE
        & '.\lab\Azure\44 Introduce Delta Report Drift.ps1' -WhatIf

        Previews the target without changing it.

    .EXAMPLE
        & '.\lab\Azure\44 Introduce Delta Report Drift.ps1'

        Prompts before changing the selected test properties in the Test tenant.

    .EXAMPLE
        & '.\lab\Azure\44 Introduce Delta Report Drift.ps1' -RestoreFrom '<rollback-file>'

        Restores the selected values saved in the rollback file and removes the test policy.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Required for interactive change and rollback instructions')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Datum decrypts the protected app secret to a process-local string; Graph requires it as a SecureString in PSCredential')]
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Apply')]
param (
    [Parameter(ParameterSetName = 'Apply')]
    [Parameter(ParameterSetName = 'Restore')]
    [ValidateSet('Test')]
    [string]$EnvironmentName = 'Test',

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateNotNullOrEmpty()]
    [string]$ApplicationDisplayName = 'M365DscSetupApplication',

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
Import-Module -Name Microsoft.Graph.Applications -RequiredVersion '2.41.1' -ErrorAction Stop

$datum = New-DatumStructure -DefinitionFile (Join-Path -Path $PSScriptRoot -ChildPath '..\..\source\Datum.yml')
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'AzHelpers.psm1') -Force -ErrorAction Stop
Update-M365DscEnvironmentMetadata `
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
$setupIdentity = $setupIdentities[0]

$exportConfigurationPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\export\ExportConfiguration.yml'
if (-not (Select-String -LiteralPath $exportConfigurationPath -Pattern '^\s*-\s*AADApplication\s*$' -Quiet -ErrorAction Stop))
{
    throw "AADApplication is not listed in '$exportConfigurationPath'; changes to this resource would not appear in the delta report."
}
if (-not (Select-String -LiteralPath $exportConfigurationPath -Pattern '^\s*-\s*AADConditionalAccessPolicy\s*$' -Quiet -ErrorAction Stop))
{
    throw "AADConditionalAccessPolicy is not listed in '$exportConfigurationPath'; the test policy would not appear in the delta report."
}
if (-not (Select-String -LiteralPath $exportConfigurationPath -Pattern '^\s*-\s*AADGroupsSettings\s*$' -Quiet -ErrorAction Stop))
{
    throw "AADGroupsSettings is not listed in '$exportConfigurationPath'; the test guidance URL changes would not appear in the delta report."
}

$rollbackData = $null
if ($PSCmdlet.ParameterSetName -eq 'Restore')
{
    $rollbackData = Get-Content -LiteralPath $RestoreFrom -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($rollbackData.SchemaVersion -ne 1 -or
        $rollbackData.Environment -ne $EnvironmentName -or
        $rollbackData.TenantId -ne $environment.AzTenantId -or
        -not $rollbackData.ApplicationId)
    {
        throw "Rollback file '$RestoreFrom' is not a supported backup for the configured '$EnvironmentName' tenant."
    }
}

$groupSettingsUri = 'https://graph.microsoft.com/beta/settings'
$groupSettings = $null
$originalGroupGuidanceUrls = $null
$clientSecret = ConvertTo-M365DscSecureString -Value $setupIdentity.ApplicationSecret
$clientSecretCredential = [System.Management.Automation.PSCredential]::new($setupIdentity.ApplicationId, $clientSecret)
Connect-MgGraph -TenantId $environment.AzTenantId -ClientSecretCredential $clientSecretCredential -NoWelcome -ErrorAction Stop
try
{
    if ($PSCmdlet.ParameterSetName -eq 'Apply')
    {
        $groupSettingsResponse = Invoke-MgGraphRequest -Method GET -Uri $groupSettingsUri -ErrorAction Stop
        $groupSettingsMatches = @($groupSettingsResponse.value | Where-Object DisplayName -EQ 'Group.Unified')
        if ($groupSettingsMatches.Count -ne 1)
        {
            throw "Expected one existing Group.Unified setting in '$EnvironmentName'; found $($groupSettingsMatches.Count). No tenant changes were made."
        }

        $groupSettings = $groupSettingsMatches[0]
        if (-not $groupSettings.id)
        {
            throw "The existing Group.Unified setting did not include an ID. No tenant changes were made."
        }

        $originalGroupGuidanceUrls = @{}
        foreach ($settingName in 'UsageGuidelinesUrl', 'GuestUsageGuidelinesUrl')
        {
            $settingValue = @($groupSettings.values | Where-Object Name -EQ $settingName)
            if ($settingValue.Count -ne 1)
            {
                throw "Group.Unified does not contain exactly one '$settingName' value. No tenant changes were made."
            }

            $originalGroupGuidanceUrls[$settingName] = [string]$settingValue[0].value
        }

        $groupGuidanceMarker = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $newGroupGuidanceUrls = @{
            UsageGuidelinesUrl      = "https://delta-report-test.invalid/groups/$groupGuidanceMarker"
            GuestUsageGuidelinesUrl = "https://delta-report-test.invalid/guests/$groupGuidanceMarker"
        }
    }
    elseif ($rollbackData.GroupSettingsId -and $rollbackData.GroupSettingsValues)
    {
        $groupSettings = Invoke-MgGraphRequest -Method GET -Uri "$groupSettingsUri/$($rollbackData.GroupSettingsId)" -ErrorAction Stop
        if (-not $groupSettings.id -or $groupSettings.id -ne $rollbackData.GroupSettingsId)
        {
            throw "Could not retrieve the original Group.Unified setting '$($rollbackData.GroupSettingsId)' for rollback."
        }

        $originalGroupGuidanceUrls = @{}
        foreach ($settingName in 'UsageGuidelinesUrl', 'GuestUsageGuidelinesUrl')
        {
            $savedValue = @($rollbackData.GroupSettingsValues | Where-Object Name -EQ $settingName)
            $currentValue = @($groupSettings.values | Where-Object Name -EQ $settingName)
            if ($savedValue.Count -ne 1 -or $currentValue.Count -ne 1)
            {
                throw "Could not find exactly one saved and current '$settingName' value; refusing to partially restore Group.Unified."
            }

            $originalGroupGuidanceUrls[$settingName] = [string]$savedValue[0].Value
        }
    }

    if ($PSCmdlet.ParameterSetName -eq 'Restore')
    {
        $application = Get-MgApplication -ApplicationId $rollbackData.ApplicationId -Property Id, DisplayName -ErrorAction Stop
        if ($application.DisplayName -ne $rollbackData.DisplayName)
        {
            throw "Application '$($rollbackData.ApplicationId)' is now named '$($application.DisplayName)', not '$($rollbackData.DisplayName)'. Refusing to restore metadata to a renamed application."
        }

        $targetDescription = $rollbackData.Description
        $targetNotes = $rollbackData.Notes
        $operation = 'Restore application metadata and Group.Unified guidance URLs, and remove the test Conditional Access policy, if recorded'
        $rollbackPath = $RestoreFrom
    }
    else
    {
        $escapedDisplayName = $ApplicationDisplayName.Replace("'", "''")
        $applications = @(
            Get-MgApplication -Filter "displayName eq '$escapedDisplayName'" -Property Id, DisplayName, Description, Notes -All -ErrorAction Stop
        )
        if ($applications.Count -ne 1)
        {
            throw "Expected exactly one application named '$ApplicationDisplayName' in '$EnvironmentName'; found $($applications.Count). No changes were made."
        }

        $application = $applications[0]
        $marker = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $descriptionSuffix = " [DeltaReport test $marker]"
        $notesSuffix = " [DeltaReport test $marker]"
        if (($application.Description.Length + $descriptionSuffix.Length) -gt 1024 -or
            ($application.Notes.Length + $notesSuffix.Length) -gt 1024)
        {
            throw "The Description or Notes for '$ApplicationDisplayName' is too long to append a test marker safely."
        }

        $targetDescription = if ($application.Description) { $application.Description + $descriptionSuffix } else { "DeltaReport test $marker" }
        $targetNotes = if ($application.Notes) { $application.Notes + $notesSuffix } else { "DeltaReport test $marker" }
        $conditionalAccessPolicyName = "DeltaReport-Test-$marker"
        $operation = "Change application metadata and Group.Unified guidance URLs, and attempt to create disabled Conditional Access policy '$conditionalAccessPolicyName' in '$EnvironmentName'"

        $rollbackDirectory = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft365DSC\DeltaReportRollback'
        $rollbackFileName = "DeltaReportRollback-$EnvironmentName-$($application.Id)-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
        $rollbackPath = Join-Path -Path $rollbackDirectory -ChildPath $rollbackFileName
    }

    if ($PSCmdlet.ShouldProcess("$EnvironmentName tenant application '$($application.DisplayName)'", $operation))
    {
        if ($PSCmdlet.ParameterSetName -eq 'Apply')
        {
            New-Item -Path $rollbackDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            [ordered]@{
                SchemaVersion = 1
                Environment   = $EnvironmentName
                TenantId      = [string]$environment.AzTenantId
                ApplicationId = [string]$application.Id
                DisplayName   = [string]$application.DisplayName
                Description   = $application.Description
                Notes         = $application.Notes
                ConditionalAccessPolicyId = $null
                ConditionalAccessPolicyName = $null
                GroupSettingsId = [string]$groupSettings.id
                GroupSettingsValues = @(
                    [ordered]@{
                        Name  = 'UsageGuidelinesUrl'
                        Value = $originalGroupGuidanceUrls.UsageGuidelinesUrl
                    },
                    [ordered]@{
                        Name  = 'GuestUsageGuidelinesUrl'
                        Value = $originalGroupGuidanceUrls.GuestUsageGuidelinesUrl
                    }
                )
                CreatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rollbackPath -Encoding utf8 -ErrorAction Stop
            Write-Host "Saved original values to '$rollbackPath'." -ForegroundColor Yellow
        }

        if ($PSCmdlet.ParameterSetName -eq 'Apply')
        {
            $conditionalAccessPolicySkipped = $false
            $policyBody = @{
                displayName = $conditionalAccessPolicyName
                state       = 'disabled'
                conditions  = @{
                    users = @{
                        includeUsers = @('All')
                    }
                    applications = @{
                        includeApplications = @('All')
                    }
                    clientAppTypes = @('all')
                }
                grantControls = @{
                    operator        = 'OR'
                    builtInControls = @('mfa')
                }
            } | ConvertTo-Json -Depth 10 -Compress

            try
            {
                $createdPolicy = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies' -Body $policyBody -ContentType 'application/json' -ErrorAction Stop
                if (-not $createdPolicy.id)
                {
                    throw "Microsoft Graph did not return an ID for disabled test policy '$conditionalAccessPolicyName'. The application metadata was not changed. Check the tenant before retrying."
                }

                $rollbackData = Get-Content -LiteralPath $rollbackPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $rollbackData.ConditionalAccessPolicyId = [string]$createdPolicy.id
                $rollbackData.ConditionalAccessPolicyName = [string]$createdPolicy.displayName
                $rollbackData | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $rollbackPath -Encoding utf8 -ErrorAction Stop
                Write-Host "Created disabled Conditional Access policy '$($createdPolicy.displayName)'." -ForegroundColor Yellow
            }
            catch
            {
                $caughtGraphError = $_
                $graphErrorDetails = @(
                    $caughtGraphError.ToString()
                    $caughtGraphError.ErrorDetails.Message
                )
                $graphException = $caughtGraphError.Exception
                while ($graphException)
                {
                    $graphErrorDetails += $graphException.Message
                    $graphErrorDetails += $graphException.ToString()
                    $graphException = $graphException.InnerException
                }

                $graphErrorText = $graphErrorDetails -join "`n"
                if ($graphErrorText -match '(?i)not licensed for this feature|tenant is not licensed')
                {
                    $conditionalAccessPolicySkipped = $true
                    Write-Warning "The tenant is not licensed for Conditional Access policy creation. Skipping AADConditionalAccessPolicy drift; application and Group.Unified drift will continue. No Conditional Access policy was created."
                }
                else
                {
                    throw $caughtGraphError
                }
            }
        }

        $updateBody = @{
            description = $targetDescription
            notes       = $targetNotes
        } | ConvertTo-Json -Depth 5 -Compress

        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($application.Id)" -Body $updateBody -ContentType 'application/json' -ErrorAction Stop | Out-Null

        if ($PSCmdlet.ParameterSetName -eq 'Restore')
        {
            if ($originalGroupGuidanceUrls)
            {
                $groupValues = @($groupSettings.values | ForEach-Object {
                    $valueName = $_.name
                    $value = if ($originalGroupGuidanceUrls.ContainsKey($valueName)) { $originalGroupGuidanceUrls[$valueName] } else { $_.value }
                    [ordered]@{
                        name  = $valueName
                        value = $value
                    }
                })
                $groupSettingsBody = @{ values = $groupValues } | ConvertTo-Json -Depth 8 -Compress
                Invoke-MgGraphRequest -Method PATCH -Uri "$groupSettingsUri/$($rollbackData.GroupSettingsId)" -Body $groupSettingsBody -ContentType 'application/json' -ErrorAction Stop | Out-Null
                Write-Host "Restored Group.Unified guidance URLs in '$EnvironmentName'." -ForegroundColor Green
            }

            if ($rollbackData.ConditionalAccessPolicyId)
            {
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($rollbackData.ConditionalAccessPolicyId)" -ErrorAction Stop | Out-Null
                Write-Host "Removed disabled test policy '$($rollbackData.ConditionalAccessPolicyName)'." -ForegroundColor Green
            }

            Write-Host "Restored application metadata and any saved Group.Unified guidance URLs for '$($application.DisplayName)' in '$EnvironmentName' from '$rollbackPath'." -ForegroundColor Green
        }
        else
        {
            $groupValues = @($groupSettings.values | ForEach-Object {
                $valueName = $_.name
                $value = if ($newGroupGuidanceUrls.ContainsKey($valueName)) { $newGroupGuidanceUrls[$valueName] } else { $_.value }
                [ordered]@{
                    name  = $valueName
                    value = $value
                }
            })
            $groupSettingsBody = @{ values = $groupValues } | ConvertTo-Json -Depth 8 -Compress
            Invoke-MgGraphRequest -Method PATCH -Uri "$groupSettingsUri/$($groupSettings.id)" -Body $groupSettingsBody -ContentType 'application/json' -ErrorAction Stop | Out-Null
            Write-Host "Updated Group.Unified guidance URLs to reserved .invalid addresses in '$EnvironmentName'." -ForegroundColor Yellow
            if ($conditionalAccessPolicySkipped)
            {
                Write-Host "Added application metadata markers and Group.Unified URL drift in '$EnvironmentName'. Conditional Access policy drift was skipped because the tenant is not licensed for the feature." -ForegroundColor Green
            }
            else
            {
                Write-Host "Added application metadata markers and disabled Conditional Access policy '$conditionalAccessPolicyName' in '$EnvironmentName'." -ForegroundColor Green
            }
            Write-Host "To undo it, run: .\lab\Azure\44 Introduce Delta Report Drift.ps1 -RestoreFrom '$rollbackPath'" -ForegroundColor Yellow
        }
    }
    elseif ($WhatIfPreference -and $PSCmdlet.ParameterSetName -eq 'Apply')
    {
        Write-Host "WhatIf: would change application Description/Notes, the two Group.Unified guidance URLs, and create disabled policy '$conditionalAccessPolicyName'. Original values would be backed up to '$rollbackPath'." -ForegroundColor Yellow
    }
}
finally
{
    Disconnect-MgGraph | Out-Null
}
