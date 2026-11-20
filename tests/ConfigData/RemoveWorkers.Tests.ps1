BeforeAll {
    $cleanupPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Azure\96 Remove Workers.ps1'
    $tokens = $null
    $parseErrors = $null
    $cleanupAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $cleanupPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $cleanupFunction = $cleanupAst.Find({
            param($astNode)
            $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $astNode.Name -eq 'Remove-M365DscAgentPoolAgents'
        }, $true)
    . ([scriptblock]::Create($cleanupFunction.Extent.Text))

    function Get-M365DscAgentVmName
    {
        param (
            [string]$ProjectName,
            [string]$EnvironmentName
        )

        return "Lcm$ProjectName$EnvironmentName"
    }
}

Describe 'Azure DevOps worker agent cleanup' {
    BeforeEach {
        $script:deletedAgentUris = @()
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get' -and $Uri -match '/pools\?')
            {
                return @{ value = @(@{ id = 14; name = 'DSC-AzurePool' }) }
            }
            if ($Method -eq 'Get')
            {
                return @{
                    value = @(
                        @{ id = 21; name = 'LcmDSC-AzureDev-1'; status = 'offline' }
                        @{ id = 22; name = 'LcmDSC-AzureDev-2'; status = 'online' }
                        @{ id = 23; name = 'LcmDSC-AzureTest-1'; status = 'offline' }
                        @{ id = 24; name = 'UnrelatedAgent-1'; status = 'offline' }
                        @{ id = 25; name = 'LcmDSC-AzureDev-3'; status = 'offline' }
                    )
                }
            }

            $script:deletedAgentUris += $Uri
        }
    }

    It 'Removes only offline agents belonging to the selected environment' {
        Remove-M365DscAgentPoolAgents `
            -OrganizationName 'workshop-org' `
            -AgentPoolName 'DSC-AzurePool' `
            -PersonalAccessToken 'test-token' `
            -ProjectName 'DSC-Azure' `
            -EnvironmentName 'Dev'

        $script:deletedAgentUris | Should -HaveCount 2
        $script:deletedAgentUris[0] | Should -Match '/pools/14/agents/21\?api-version=7\.1$'
        $script:deletedAgentUris[1] | Should -Match '/pools/14/agents/25\?api-version=7\.1$'
    }
}
