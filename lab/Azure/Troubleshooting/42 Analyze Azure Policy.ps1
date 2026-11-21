<#
.SYNOPSIS
    Audits policy assignments that apply to an Azure subscription.

.DESCRIPTION
    Reports assigned policies and initiatives at the subscription, descendant resource
    scopes, and discoverable management-group ancestors. Classifies policy effects to
    highlight assignments that can deny or modify deployments. This is a static
    assignment/definition review; it does not evaluate a particular resource request.

.PARAMETER OutputPath
    Optional path for the CSV report. Defaults to .work\reporting\AzurePolicyAudit-<timestamp>.csv.

.EXAMPLE
    .\lab\Azure\Troubleshooting\42 Analyze Azure Policy.ps1

.EXAMPLE
    .\lab\Azure\Troubleshooting\42 Analyze Azure Policy.ps1 -OutputPath '.\.work\reporting\policy-findings.csv'
#>
[CmdletBinding()]
param (
    [Parameter()]
    [string]$OutputPath
)

$requiredModulesPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\output\RequiredModules'
if (Test-Path -LiteralPath $requiredModulesPath)
{
    $requiredModulesPath = (Resolve-Path -LiteralPath $requiredModulesPath).Path
    if ($env:PSModulePath -notlike "*$requiredModulesPath*")
    {
        $env:PSModulePath = $env:PSModulePath + [System.IO.Path]::PathSeparator + $requiredModulesPath
    }
}

Import-Module -Name Az.Accounts -ErrorAction Stop
Import-Module -Name Az.KeyVault -ErrorAction Stop
Import-Module -Name Az.Resources -ErrorAction Stop
Import-Module -Name powershell-yaml -ErrorAction Stop
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..\AzHelpers.psm1') -Force -ErrorAction Stop

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$azureConfigPath = Join-Path -Path $repoRoot -ChildPath 'source\Global\Azure.yml'
if (-not (Test-Path -LiteralPath $azureConfigPath))
{
    throw "Azure environment configuration was not found at '$azureConfigPath'."
}

$datum = New-DatumStructure -DefinitionFile (Join-Path -Path $repoRoot -ChildPath 'source\Datum.yml')
$environmentNames = @($datum.Global.Azure.Environments.Keys)
if (-not $environmentNames)
{
    throw "No Environments section was found in '$azureConfigPath'."
}
Update-M365DscDatumFromKeyVault `
    -Datum $datum `
    -ProjectName $datum.Global.ProjectSettings.ProjectName `
    -EnvironmentName $environmentNames | Out-Null

$environmentConfigs = @(
    foreach ($environmentEntry in $datum.Global.Azure.Environments.GetEnumerator())
    {
        $environmentName = [string]$environmentEntry.Key
        $tenantId = [string]$environmentEntry.Value.AzTenantId
        $subscriptionId = [string]$environmentEntry.Value.AzSubscriptionId

        if ($tenantId -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
        {
            throw "Environment '$environmentName' has a missing or invalid AzTenantId in '$azureConfigPath'."
        }
        if ($subscriptionId -notmatch '^[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')
        {
            throw "Environment '$environmentName' has a missing or invalid AzSubscriptionId in '$azureConfigPath'."
        }

        [pscustomobject]@{
            Name           = $environmentName
            TenantId       = $tenantId
            SubscriptionId = $subscriptionId
        }
    }
)

if ($environmentConfigs.Count -eq 0)
{
    throw "No Azure environments were found in '$azureConfigPath'."
}

function Invoke-AzPolicyAudit
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $context = Get-AzContext
    if (-not $context -or $context.Tenant.Id -ne $TenantId -or $context.Subscription.Id -ne $SubscriptionId)
    {
        $availableContext = @(
            Get-AzContext -ListAvailable |
                Where-Object {
                    $_.Tenant.Id -eq $TenantId -and $_.Subscription.Id -eq $SubscriptionId
                } |
                Select-Object -First 1
        )

        if ($availableContext.Count -gt 0)
        {
            $context = Set-AzContext -Context $availableContext[0] -ErrorAction Stop
        }
        else
        {
            Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }
    }

    if (-not $context -or $context.Tenant.Id -ne $TenantId -or $context.Subscription.Id -ne $SubscriptionId)
    {
        throw "Could not select tenant '$TenantId' and subscription '$SubscriptionId' for environment '$EnvironmentName'."
    }

    Write-Information "Auditing environment '$EnvironmentName' (subscription '$SubscriptionId')." -InformationAction Continue

$subscriptionScope = "/subscriptions/$SubscriptionId"
$assignmentById = @{}
$scopeList = [System.Collections.Generic.List[string]]::new()
$scopeList.Add($subscriptionScope)

function Get-PolicyValue
{
    param (
        [Parameter()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject)
    {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary])
    {
        foreach ($key in $InputObject.Keys)
        {
            if ([string]$key -ieq $Name)
            {
                return $InputObject[$key]
            }
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property)
    {
        return $property.Value
    }

    return $null
}

function Get-PolicyParameterValue
{
    param (
        [Parameter()]
        [object]$ParameterContainer,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $entry = Get-PolicyValue -InputObject $ParameterContainer -Name $Name
    if ($null -eq $entry)
    {
        return $null
    }

    $value = Get-PolicyValue -InputObject $entry -Name 'Value'
    if ($null -ne $value)
    {
        return $value
    }

    return $entry
}

function Find-SubscriptionManagementGroupPath
{
    param (
        [Parameter(Mandatory = $true)]
        [object]$ManagementGroup,

        [Parameter(Mandatory = $true)]
        [string]$TargetSubscriptionId,

        [Parameter()]
        [string[]]$Ancestors = @()
    )

    $groupName = Get-PolicyValue -InputObject $ManagementGroup -Name 'Name'
    $groupId = Get-PolicyValue -InputObject $ManagementGroup -Name 'Id'
    $currentPath = @($Ancestors)
    if ($groupName -or $groupId)
    {
        $scopeId = if ($groupId -like '*/providers/Microsoft.Management/managementGroups/*')
        {
            $groupId
        }
        else
        {
            "/providers/Microsoft.Management/managementGroups/$groupName"
        }
        $currentPath += $scopeId
    }

    foreach ($child in @(Get-PolicyValue -InputObject $ManagementGroup -Name 'Children'))
    {
        $childType = [string](Get-PolicyValue -InputObject $child -Name 'Type')
        $childName = [string](Get-PolicyValue -InputObject $child -Name 'Name')
        $childId = [string](Get-PolicyValue -InputObject $child -Name 'Id')

        if (($childType -match 'subscription$') -and
            (($childName -eq $TargetSubscriptionId) -or ($childId -match "/subscriptions/$TargetSubscriptionId$")))
        {
            return ,$currentPath
        }

        if ($childType -match 'managementGroup$')
        {
            $nestedGroup = Get-AzManagementGroup -GroupName $childName -Expand -ErrorAction Stop
            $foundPath = Find-SubscriptionManagementGroupPath `
                -ManagementGroup $nestedGroup `
                -TargetSubscriptionId $TargetSubscriptionId `
                -Ancestors $currentPath
            if ($null -ne $foundPath)
            {
                return ,$foundPath
            }
        }
    }

    return $null
}

Write-Information "Auditing Azure Policy assignments for subscription '$SubscriptionId'." -InformationAction Continue

try
{
    $managementGroupRoot = Get-AzManagementGroup -GroupName $context.Tenant.Id -Expand -ErrorAction Stop
    $managementGroupPath = Find-SubscriptionManagementGroupPath `
        -ManagementGroup $managementGroupRoot `
        -TargetSubscriptionId $SubscriptionId

    if ($null -eq $managementGroupPath)
    {
        Write-Warning "Could not locate the subscription in the visible management-group hierarchy. Management-group policy assignments may be missing from this report."
    }
    else
    {
        foreach ($managementGroupScope in $managementGroupPath)
        {
            if (-not $scopeList.Contains($managementGroupScope))
            {
                $scopeList.Add($managementGroupScope)
            }
        }
    }
}
catch
{
    Write-Warning "Could not read the management-group hierarchy; inherited assignments may be missing. $($_.Exception.Message)"
}

try
{
    $subscriptionAssignments = Get-AzPolicyAssignment `
        -Scope $subscriptionScope `
        -IncludeDescendent `
        -ErrorAction Stop

    foreach ($assignment in $subscriptionAssignments)
    {
        $assignmentId = [string](Get-PolicyValue -InputObject $assignment -Name 'Id')
        if ($assignmentId)
        {
            $assignmentById[$assignmentId.ToLowerInvariant()] = $assignment
        }
    }
}
catch
{
    throw "Failed to list subscription and descendant policy assignments for '$subscriptionScope'. $($_.Exception.Message)"
}

foreach ($managementGroupScope in $scopeList | Where-Object { $_ -ne $subscriptionScope })
{
    try
    {
        foreach ($assignment in (Get-AzPolicyAssignment -Scope $managementGroupScope -ErrorAction Stop))
        {
            $assignmentId = [string](Get-PolicyValue -InputObject $assignment -Name 'Id')
            if ($assignmentId)
            {
                $assignmentById[$assignmentId.ToLowerInvariant()] = $assignment
            }
        }
    }
    catch
    {
        Write-Warning "Could not list policy assignments at management-group scope '$managementGroupScope'. $($_.Exception.Message)"
    }
}

$exemptionsByAssignmentId = @{}
$exemptionScopes = @($subscriptionScope) + @($scopeList | Where-Object { $_ -ne $subscriptionScope })
foreach ($exemptionScope in $exemptionScopes)
{
    try
    {
        $exemptions = Get-AzPolicyExemption -Scope $exemptionScope -IncludeDescendent -ErrorAction Stop
        foreach ($exemption in $exemptions)
        {
            $exemptionProperties = Get-PolicyValue -InputObject $exemption -Name 'Properties'
            $policyAssignmentId = [string](Get-PolicyValue -InputObject $exemptionProperties -Name 'PolicyAssignmentId')
            if (-not $policyAssignmentId)
            {
                $policyAssignmentId = [string](Get-PolicyValue -InputObject $exemption -Name 'PolicyAssignmentId')
            }
            if (-not $policyAssignmentId)
            {
                continue
            }

            $exemptionId = $policyAssignmentId.ToLowerInvariant()
            if (-not $exemptionsByAssignmentId.ContainsKey($exemptionId))
            {
                $exemptionsByAssignmentId[$exemptionId] = [System.Collections.Generic.List[string]]::new()
            }

            $exemptionName = Get-PolicyValue -InputObject $exemptionProperties -Name 'DisplayName'
            if (-not $exemptionName)
            {
                $exemptionName = Get-PolicyValue -InputObject $exemption -Name 'Name'
            }
            $exemptionScopeValue = Get-PolicyValue -InputObject $exemption -Name 'Scope'
            $exemptionCategory = Get-PolicyValue -InputObject $exemptionProperties -Name 'ExemptionCategory'
            $exemptionDescription = "$exemptionName [$exemptionCategory] at $exemptionScopeValue"
            if (-not $exemptionsByAssignmentId[$exemptionId].Contains($exemptionDescription))
            {
                $exemptionsByAssignmentId[$exemptionId].Add($exemptionDescription)
            }
        }
    }
    catch
    {
        Write-Warning "Could not list policy exemptions at '$exemptionScope'; exemption information may be incomplete. $($_.Exception.Message)"
    }
}

if ($assignmentById.Count -eq 0)
{
    Write-Information "No policy assignments were found for environment '$EnvironmentName' in the accessible subscription, descendant, or management-group scopes." -InformationAction Continue
    return
}

$findings = [System.Collections.Generic.List[object]]::new()
$definitionCache = @{}
$policySetCache = @{}

function Get-CachedPolicyDefinition
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$DefinitionId
    )

    $cacheKey = $DefinitionId.ToLowerInvariant()
    if (-not $definitionCache.ContainsKey($cacheKey))
    {
        $definitionCache[$cacheKey] = Get-AzPolicyDefinition -Id $DefinitionId -ErrorAction Stop
    }

    return $definitionCache[$cacheKey]
}

function Get-CachedPolicySetDefinition
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$DefinitionId
    )

    $cacheKey = $DefinitionId.ToLowerInvariant()
    if (-not $policySetCache.ContainsKey($cacheKey))
    {
        $policySetCache[$cacheKey] = Get-AzPolicySetDefinition -Id $DefinitionId -ErrorAction Stop
    }

    return $policySetCache[$cacheKey]
}

function Get-PolicyEffect
{
    param (
        [Parameter()]
        [object]$PolicyDefinition,

        [Parameter()]
        [object]$EffectiveParameters
    )

    $properties = Get-PolicyValue -InputObject $PolicyDefinition -Name 'Properties'
    $policyRule = Get-PolicyValue -InputObject $PolicyDefinition -Name 'PolicyRule'
    if (-not $policyRule)
    {
        $policyRule = Get-PolicyValue -InputObject $properties -Name 'PolicyRule'
    }

    $then = Get-PolicyValue -InputObject $policyRule -Name 'then'
    $effect = Get-PolicyValue -InputObject $then -Name 'effect'
    if ($null -eq $effect)
    {
        return 'Unknown'
    }

    if ($effect -isnot [string])
    {
        return ($effect | ConvertTo-Json -Depth 20 -Compress)
    }

    if ($effect -match "^\s*\[parameters\('([^']+)'\)\]\s*$")
    {
        $parameterName = $Matches[1]
        $value = Get-PolicyParameterValue -ParameterContainer $EffectiveParameters -Name $parameterName

        if ($null -eq $value)
        {
            $definitionParameters = Get-PolicyValue -InputObject $PolicyDefinition -Name 'Parameters'
            if (-not $definitionParameters)
            {
                $definitionParameters = Get-PolicyValue -InputObject $properties -Name 'Parameters'
            }
            $definitionParameter = Get-PolicyValue -InputObject $definitionParameters -Name $parameterName
            $value = Get-PolicyValue -InputObject $definitionParameter -Name 'DefaultValue'
        }

        if ($null -eq $value)
        {
            return "Unresolved parameter: $parameterName"
        }

        return [string]$value
    }

    return $effect
}

function Get-PolicyAssessment
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$Effect,

        [Parameter()]
        [string]$EnforcementMode
    )

    $assessment = switch -Regex ($Effect.Trim().Trim("'`"").ToLowerInvariant())
    {
        '^(deny|denyaction)$' { 'BLOCKS requests'; break }
        '^(modify|append)$' { 'MAY MODIFY or block requests'; break }
        '^deployifnotexists$' { 'MAY TRIGGER a deployment'; break }
        '^auditifnotexists$' { 'AUDITS and may trigger remediation'; break }
        '^audit$' { 'AUDIT ONLY'; break }
        '^disabled$' { 'DISABLED'; break }
        default { 'REVIEW EFFECT' }
    }

    if ($EnforcementMode -eq 'DoNotEnforce')
    {
        return "NOT ENFORCED ($assessment)"
    }

    return $assessment
}

function Get-PolicyText
{
    param (
        [Parameter()]
        [object]$PolicyDefinition
    )

    return ($PolicyDefinition | ConvertTo-Json -Depth 100 -Compress)
}

foreach ($assignment in $assignmentById.Values)
{
    $assignmentProperties = Get-PolicyValue -InputObject $assignment -Name 'Properties'
    $assignmentName = Get-PolicyValue -InputObject $assignmentProperties -Name 'DisplayName'
    if (-not $assignmentName)
    {
        $assignmentName = Get-PolicyValue -InputObject $assignment -Name 'DisplayName'
    }
    if (-not $assignmentName)
    {
        $assignmentName = Get-PolicyValue -InputObject $assignment -Name 'Name'
    }
    $assignmentScope = [string](Get-PolicyValue -InputObject $assignment -Name 'Scope')
    $definitionId = [string](Get-PolicyValue -InputObject $assignmentProperties -Name 'PolicyDefinitionId')
    if (-not $definitionId)
    {
        $definitionId = [string](Get-PolicyValue -InputObject $assignment -Name 'PolicyDefinitionId')
    }

    $assignmentParameters = Get-PolicyValue -InputObject $assignmentProperties -Name 'Parameters'
    if (-not $assignmentParameters)
    {
        $assignmentParameters = Get-PolicyValue -InputObject $assignment -Name 'Parameters'
    }
    $assignmentOverrides = Get-PolicyValue -InputObject $assignmentProperties -Name 'Overrides'
    if (-not $assignmentOverrides)
    {
        $assignmentOverrides = Get-PolicyValue -InputObject $assignment -Name 'Overrides'
    }
    $assignmentOverridesText = if ($assignmentOverrides)
    {
        $assignmentOverrides | ConvertTo-Json -Depth 20 -Compress
    }
    else
    {
        ''
    }
    $assignmentId = [string](Get-PolicyValue -InputObject $assignment -Name 'Id')
    $assignmentExemptions = if ($assignmentId -and $exemptionsByAssignmentId.ContainsKey($assignmentId.ToLowerInvariant()))
    {
        $exemptionsByAssignmentId[$assignmentId.ToLowerInvariant()] -join '; '
    }
    else
    {
        ''
    }
    $enforcementMode = Get-PolicyValue -InputObject $assignmentProperties -Name 'EnforcementMode'
    if (-not $enforcementMode)
    {
        $enforcementMode = Get-PolicyValue -InputObject $assignment -Name 'EnforcementMode'
    }

    if (-not $definitionId)
    {
        Write-Warning "Assignment '$assignmentName' at '$assignmentScope' has no readable policy definition ID."
        continue
    }

    if ($definitionId -match '/policySetDefinitions/')
    {
        try
        {
            $policySet = Get-CachedPolicySetDefinition -DefinitionId $definitionId
        }
        catch
        {
            Write-Warning "Could not read initiative '$definitionId' assigned as '$assignmentName'. $($_.Exception.Message)"
            continue
        }

        $setProperties = Get-PolicyValue -InputObject $policySet -Name 'Properties'
        $initiativeName = Get-PolicyValue -InputObject $setProperties -Name 'DisplayName'
        if (-not $initiativeName)
        {
            $initiativeName = Get-PolicyValue -InputObject $policySet -Name 'DisplayName'
        }
        $initiativeParameters = Get-PolicyValue -InputObject $setProperties -Name 'Parameters'
        if (-not $initiativeParameters)
        {
            $initiativeParameters = Get-PolicyValue -InputObject $policySet -Name 'Parameters'
        }
        $members = Get-PolicyValue -InputObject $setProperties -Name 'PolicyDefinitions'
        if (-not $members)
        {
            $members = Get-PolicyValue -InputObject $policySet -Name 'PolicyDefinitions'
        }

        foreach ($member in $members)
        {
            $memberDefinitionId = [string](Get-PolicyValue -InputObject $member -Name 'PolicyDefinitionId')
            if (-not $memberDefinitionId)
            {
                continue
            }

            try
            {
                $policyDefinition = Get-CachedPolicyDefinition -DefinitionId $memberDefinitionId
            }
            catch
            {
                Write-Warning "Could not read policy '$memberDefinitionId' in initiative '$initiativeName'. $($_.Exception.Message)"
                continue
            }

            $effectiveParameters = @{}
            $memberParameters = Get-PolicyValue -InputObject $member -Name 'Parameters'
            if ($memberParameters)
            {
                $memberParameterNames = if ($memberParameters -is [System.Collections.IDictionary])
                {
                    $memberParameters.Keys
                }
                else
                {
                    $memberParameters.PSObject.Properties.Name
                }

                foreach ($memberParameterName in $memberParameterNames)
                {
                    $mappedValue = Get-PolicyParameterValue -ParameterContainer $memberParameters -Name $memberParameterName
                    if ($mappedValue -is [string] -and $mappedValue -match "^\s*\[parameters\('([^']+)'\)\]\s*$")
                    {
                        $initiativeParameterName = $Matches[1]
                        $mappedValue = Get-PolicyParameterValue -ParameterContainer $assignmentParameters -Name $initiativeParameterName
                        if ($null -eq $mappedValue)
                        {
                            $initiativeParameter = Get-PolicyValue -InputObject $initiativeParameters -Name $initiativeParameterName
                            $mappedValue = Get-PolicyValue -InputObject $initiativeParameter -Name 'DefaultValue'
                        }
                    }
                    $effectiveParameters[$memberParameterName] = $mappedValue
                }
            }

            $policyProperties = Get-PolicyValue -InputObject $policyDefinition -Name 'Properties'
            $policyName = Get-PolicyValue -InputObject $policyProperties -Name 'DisplayName'
            if (-not $policyName)
            {
                $policyName = Get-PolicyValue -InputObject $policyDefinition -Name 'DisplayName'
            }

            $effect = Get-PolicyEffect -PolicyDefinition $policyDefinition -EffectiveParameters $effectiveParameters
            $policyText = Get-PolicyText -PolicyDefinition $policyDefinition
            $sharedKeyRelated = $policyText -match '(?i)allowSharedKeyAccess|shared.?key|storage.?account'
            $assessment = Get-PolicyAssessment -Effect $effect -EnforcementMode ([string]$enforcementMode)
            if ($assignmentOverrides)
            {
                $assessment = "REVIEW OVERRIDES ($assessment)"
            }
            $notScopes = Get-PolicyValue -InputObject $assignmentProperties -Name 'NotScopes'
            if (-not $notScopes)
            {
                $notScopes = Get-PolicyValue -InputObject $assignment -Name 'NotScopes'
            }

            $findings.Add([pscustomobject]@{
                Environment          = $EnvironmentName
                SubscriptionId       = $SubscriptionId
                AssignmentName       = [string]$assignmentName
                AssignmentScope      = $assignmentScope
                EnforcementMode      = [string]$enforcementMode
                DefinitionType       = 'Initiative member'
                Initiative           = [string]$initiativeName
                PolicyName           = [string]$policyName
                PolicyDefinitionId   = $memberDefinitionId
                Effect               = $effect
                Assessment           = $assessment
                SharedKeyOrStorage   = [bool]$sharedKeyRelated
                DefinitionReference  = [string](Get-PolicyValue -InputObject $member -Name 'PolicyDefinitionReferenceId')
                AssignmentNotScopes  = (@($notScopes) -join '; ')
                AssignmentOverrides  = $assignmentOverridesText
                AssignmentExemptions = $assignmentExemptions
            })
        }
    }
    else
    {
        try
        {
            $policyDefinition = Get-CachedPolicyDefinition -DefinitionId $definitionId
        }
        catch
        {
            Write-Warning "Could not read policy '$definitionId' assigned as '$assignmentName'. $($_.Exception.Message)"
            continue
        }

        $policyProperties = Get-PolicyValue -InputObject $policyDefinition -Name 'Properties'
        $policyName = Get-PolicyValue -InputObject $policyProperties -Name 'DisplayName'
        if (-not $policyName)
        {
            $policyName = Get-PolicyValue -InputObject $policyDefinition -Name 'DisplayName'
        }
        $effect = Get-PolicyEffect -PolicyDefinition $policyDefinition -EffectiveParameters $assignmentParameters
        $policyText = Get-PolicyText -PolicyDefinition $policyDefinition
        $sharedKeyRelated = $policyText -match '(?i)allowSharedKeyAccess|shared.?key|storage.?account'
        $assessment = Get-PolicyAssessment -Effect $effect -EnforcementMode ([string]$enforcementMode)

        $notScopes = Get-PolicyValue -InputObject $assignmentProperties -Name 'NotScopes'
        if (-not $notScopes)
        {
            $notScopes = Get-PolicyValue -InputObject $assignment -Name 'NotScopes'
        }

        $findings.Add([pscustomobject]@{
            Environment          = $EnvironmentName
            SubscriptionId       = $SubscriptionId
            AssignmentName       = [string]$assignmentName
            AssignmentScope      = $assignmentScope
            EnforcementMode      = [string]$enforcementMode
            DefinitionType       = 'Policy'
            Initiative           = ''
            PolicyName           = [string]$policyName
            PolicyDefinitionId   = $definitionId
            Effect               = $effect
            Assessment           = $assessment
            SharedKeyOrStorage   = [bool]$sharedKeyRelated
            DefinitionReference  = ''
            AssignmentNotScopes  = (@($notScopes) -join '; ')
            AssignmentOverrides  = $assignmentOverridesText
            AssignmentExemptions = $assignmentExemptions
        })
    }
}

$orderedFindings = @($findings | Sort-Object Assessment, AssignmentScope, AssignmentName, PolicyName)
$orderedFindings |
    Select-Object Environment,
                  SubscriptionId,
                  @{Name = 'Scope'; Expression = { $_.AssignmentScope } },
                  @{Name = 'Assignment'; Expression = { $_.AssignmentName } },
                  @{Name = 'Policy'; Expression = { $_.PolicyName } },
                  Effect, Assessment, SharedKeyOrStorage |
    Format-Table -AutoSize -Wrap |
    Out-Host

$blockingCount = @($orderedFindings | Where-Object { $_.Assessment -eq 'BLOCKS requests' }).Count
$notEnforcedCount = @($orderedFindings | Where-Object { $_.Assessment -like 'NOT ENFORCED*' }).Count
$reviewCount = @($orderedFindings | Where-Object { $_.Assessment -match '^(MAY MODIFY|REVIEW)' }).Count
$sharedKeyCount = @($orderedFindings | Where-Object SharedKeyOrStorage).Count
Write-Information "Found $($orderedFindings.Count) policy rule(s) for '$EnvironmentName': $blockingCount with an enforced blocking effect, $notEnforcedCount in DoNotEnforce mode, $reviewCount that may modify/block or need effect review, $sharedKeyCount referencing storage/shared-key terms." -InformationAction Continue

$orderedFindings
}

$allFindings = [System.Collections.Generic.List[object]]::new()
foreach ($environmentConfig in $environmentConfigs)
{
    $environmentFindings = @(
        Invoke-AzPolicyAudit `
            -EnvironmentName $environmentConfig.Name `
            -TenantId $environmentConfig.TenantId `
            -SubscriptionId $environmentConfig.SubscriptionId
    )
    foreach ($finding in $environmentFindings)
    {
        $allFindings.Add($finding)
    }
}

$reportPath = if ($OutputPath)
{
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
}
else
{
    Join-Path -Path $repoRoot -ChildPath (Join-Path '.work\reporting' "AzurePolicyAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")
}

$reportDirectory = Split-Path -Parent $reportPath
if (-not (Test-Path -LiteralPath $reportDirectory))
{
    New-Item -Path $reportDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
}

$sortedFindings = @($allFindings | Sort-Object Environment, SubscriptionId, Assessment, AssignmentScope, AssignmentName, PolicyName)
if ($sortedFindings.Count -gt 0)
{
    $sortedFindings | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
}
else
{
    'Environment,SubscriptionId,AssignmentName,AssignmentScope,EnforcementMode,DefinitionType,Initiative,PolicyName,PolicyDefinitionId,Effect,Assessment,SharedKeyOrStorage,DefinitionReference,AssignmentNotScopes,AssignmentOverrides,AssignmentExemptions' |
        Set-Content -LiteralPath $reportPath -Encoding UTF8 -ErrorAction Stop
}

Write-Information "Wrote $($sortedFindings.Count) finding(s) across $($environmentConfigs.Count) environment(s) to '$reportPath'." -InformationAction Continue
Write-Information 'This is a static policy review, not an evaluation of a particular resource or request. Check assignment exclusions, conditions, exemptions, overrides, and parameter values before concluding a policy blocks a specific change.' -InformationAction Continue
$sortedFindings
