[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string] $RequiredModulesPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..')
$requiredModulesManifest = Import-PowerShellDataFile -Path (Join-Path -Path $repositoryRoot -ChildPath 'RequiredModules.psd1')
$microsoft365DscPin = $requiredModulesManifest['Microsoft365DSC']
$microsoft365DscVersion = if ($microsoft365DscPin -is [hashtable]) { $microsoft365DscPin.Version } else { [string]$microsoft365DscPin }

if ([string]::IsNullOrWhiteSpace($microsoft365DscVersion))
{
    throw "RequiredModules.psd1 does not contain an exact Microsoft365DSC version pin."
}

$moduleFile = Join-Path -Path $RequiredModulesPath -ChildPath "Microsoft365DSC\$microsoft365DscVersion\Classes\Part01.psm1"
if (-not (Test-Path -LiteralPath $moduleFile -PathType Leaf))
{
    throw "The pinned Microsoft365DSC class file was not found at '$moduleFile'."
}

$content = [System.IO.File]::ReadAllText($moduleFile)
$lineEnding = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
$content = $content.Replace("`r`n", "`n")
$classStart = $content.IndexOf('class AADGroupsSettings : M365DSCResourceBase', [System.StringComparison]::Ordinal)
$setMethodStart = if ($classStart -ge 0) { $content.IndexOf('[void] Set()', $classStart, [System.StringComparison]::Ordinal) } else { -1 }
$testMethodStart = if ($setMethodStart -ge 0) { $content.IndexOf('[bool] Test()', $setMethodStart, [System.StringComparison]::Ordinal) } else { -1 }

if ($classStart -lt 0 -or $setMethodStart -lt 0 -or $testMethodStart -lt 0)
{
    throw "Could not locate the AADGroupsSettings.Set method in '$moduleFile'."
}

$setMethodContent = $content.Substring($setMethodStart, $testMethodStart - $setMethodStart)
$policyCreationOriginal = '            $Policy = New-MgBetaDirectorySetting -TemplateId ''62375ab9-6b52-47ed-826b-58e47e0e304b'' | Out-Null' + "`n"
$policyCreationPatched = '            $Policy = New-MgBetaDirectorySetting -TemplateId ''62375ab9-6b52-47ed-826b-58e47e0e304b''' + "`n"
$originalPolicyCreationCount = [System.Text.RegularExpressions.Regex]::Matches(
    $setMethodContent,
    [System.Text.RegularExpressions.Regex]::Escape($policyCreationOriginal)
).Count
$patchedPolicyCreationCount = [System.Text.RegularExpressions.Regex]::Matches(
    $setMethodContent,
    [System.Text.RegularExpressions.Regex]::Escape($policyCreationPatched)
).Count
$changed = $false

if ($originalPolicyCreationCount -eq 1 -and $patchedPolicyCreationCount -eq 0)
{
    $setMethodContent = $setMethodContent.Replace($policyCreationOriginal, $policyCreationPatched)
    $content = $content.Substring(0, $setMethodStart) + $setMethodContent + $content.Substring($testMethodStart)
    $changed = $true
}
elseif ($originalPolicyCreationCount -ne 0 -or $patchedPolicyCreationCount -ne 1)
{
    throw "Cannot safely retain the created Group.Unified policy in '$moduleFile' (original matches: $originalPolicyCreationCount; patched matches: $patchedPolicyCreationCount)."
}

$replacements = @(
    @{
        Name     = 'Handle a missing EnableGroupCreation value'
        Original = 'EnableGroupCreation       = [Boolean]::Parse($valueEnableGroupCreation.Value)'
        Patched  = 'EnableGroupCreation       = if ([System.String]::IsNullOrEmpty($valueEnableGroupCreation.Value)) { $null } else { [Boolean]::Parse($valueEnableGroupCreation.Value) }'
    },
    @{
        Name     = 'Handle a missing EnableMIPLabels value'
        Original = 'EnableMIPLabels           = [Boolean]::Parse($valueEnableMIPLabels.Value)'
        Patched  = 'EnableMIPLabels           = if ([System.String]::IsNullOrEmpty($valueEnableMIPLabels.Value)) { $null } else { [Boolean]::Parse($valueEnableMIPLabels.Value) }'
    },
    @{
        Name     = 'Handle a missing AllowGuestsToBeGroupOwner value'
        Original = 'AllowGuestsToBeGroupOwner = [Boolean]::Parse($valueAllowGuestsToBeGroupOwner.Value)'
        Patched  = 'AllowGuestsToBeGroupOwner = if ([System.String]::IsNullOrEmpty($valueAllowGuestsToBeGroupOwner.Value)) { $null } else { [Boolean]::Parse($valueAllowGuestsToBeGroupOwner.Value) }'
    },
    @{
        Name     = 'Handle a missing AllowGuestsToAccessGroups value'
        Original = 'AllowGuestsToAccessGroups = [Boolean]::Parse($valueAllowGuestsToAccessGroups.Value)'
        Patched  = 'AllowGuestsToAccessGroups = if ([System.String]::IsNullOrEmpty($valueAllowGuestsToAccessGroups.Value)) { $null } else { [Boolean]::Parse($valueAllowGuestsToAccessGroups.Value) }'
    },
    @{
        Name     = 'Handle a missing AllowToAddGuests value'
        Original = 'AllowToAddGuests          = [Boolean]::Parse($valueAllowToAddGuests.Value)'
        Patched  = 'AllowToAddGuests          = if ([System.String]::IsNullOrEmpty($valueAllowToAddGuests.Value)) { $null } else { [Boolean]::Parse($valueAllowToAddGuests.Value) }'
    },
    @{
        Name     = 'Skip EnableGroupCreation when it is omitted'
        Original = 'if ($property.Name -eq ''EnableGroupCreation'')'
        Patched  = 'if ($property.Name -eq ''EnableGroupCreation'' -and $null -ne $this.EnableGroupCreation)'
    },
    @{
        Name     = 'Skip EnableMIPLabels when it is omitted'
        Original = 'elseif ($property.Name -eq ''EnableMIPLabels'')'
        Patched  = 'elseif ($property.Name -eq ''EnableMIPLabels'' -and $null -ne $this.EnableMIPLabels)'
    },
    @{
        Name     = 'Skip AllowGuestsToBeGroupOwner when it is omitted'
        Original = 'elseif ($property.Name -eq ''AllowGuestsToBeGroupOwner'')'
        Patched  = 'elseif ($property.Name -eq ''AllowGuestsToBeGroupOwner'' -and $null -ne $this.AllowGuestsToBeGroupOwner)'
    },
    @{
        Name     = 'Skip AllowGuestsToAccessGroups when it is omitted'
        Original = 'elseif ($property.Name -eq ''AllowGuestsToAccessGroups'')'
        Patched  = 'elseif ($property.Name -eq ''AllowGuestsToAccessGroups'' -and $null -ne $this.AllowGuestsToAccessGroups)'
    },
    @{
        Name     = 'Skip GuestUsageGuidelinesUrl when it is omitted'
        Original = 'elseif ($property.Name -eq ''GuestUsageGuidelinesUrl'')'
        Patched  = 'elseif ($property.Name -eq ''GuestUsageGuidelinesUrl'' -and $null -ne $this.GuestUsageGuidelinesUrl)'
    },
    @{
        Name     = 'Skip GroupCreationAllowedGroupId when its name is omitted'
        Original = 'elseif ($property.Name -eq ''GroupCreationAllowedGroupId'')'
        Patched  = 'elseif ($property.Name -eq ''GroupCreationAllowedGroupId'' -and $null -ne $this.GroupCreationAllowedGroupName)'
    },
    @{
        Name     = 'Skip AllowToAddGuests when it is omitted'
        Original = 'elseif ($property.Name -eq ''AllowToAddGuests'')'
        Patched  = 'elseif ($property.Name -eq ''AllowToAddGuests'' -and $null -ne $this.AllowToAddGuests)'
    },
    @{
        Name     = 'Skip UsageGuidelinesUrl when it is omitted'
        Original = 'elseif ($property.Name -eq ''UsageGuidelinesUrl'')'
        Patched  = 'elseif ($property.Name -eq ''UsageGuidelinesUrl'' -and $null -ne $this.UsageGuidelinesUrl)'
    },
    @{
        Name     = 'Skip NewUnifiedGroupWritebackDefault when it is omitted'
        Original = 'elseif ($property.Name -eq ''NewUnifiedGroupWritebackDefault'')'
        Patched  = 'elseif ($property.Name -eq ''NewUnifiedGroupWritebackDefault'' -and $null -ne $this.NewUnifiedGroupWritebackDefault)'
    }
)

foreach ($replacement in $replacements)
{
    $originalCount = [System.Text.RegularExpressions.Regex]::Matches(
        $content,
        [System.Text.RegularExpressions.Regex]::Escape($replacement.Original)
    ).Count
    $patchedCount = [System.Text.RegularExpressions.Regex]::Matches(
        $content,
        [System.Text.RegularExpressions.Regex]::Escape($replacement.Patched)
    ).Count

    if ($originalCount -eq 1 -and $patchedCount -eq 0)
    {
        $content = $content.Replace($replacement.Original, $replacement.Patched)
        $changed = $true
    }
    elseif ($originalCount -ne 0 -or $patchedCount -ne 1)
    {
        throw "Cannot safely apply Microsoft365DSC AADGroupsSettings workaround '$($replacement.Name)' to '$moduleFile' (original matches: $originalCount; patched matches: $patchedCount)."
    }
}

if ($changed)
{
    [System.IO.File]::WriteAllText(
        $moduleFile,
        $content.Replace("`n", $lineEnding),
        [System.Text.UTF8Encoding]::new($true)
    )
    Write-Host "Applied the AADGroupsSettings null-safety workaround to Microsoft365DSC $microsoft365DscVersion."
}
else
{
    Write-Host "The AADGroupsSettings null-safety workaround is already applied to Microsoft365DSC $microsoft365DscVersion."
}
