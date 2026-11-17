BeforeAll {
    $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\..\lab\Start Azure Lab.ps1'
    $tokens = $null
    $parseErrors = $null
    $bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $bootstrapPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    $checkpointFunctions = $bootstrapAst.FindAll({
            param($astNode)
            $astNode -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $astNode.Name -in @(
                'Write-BootstrapPhase',
                'Save-BootstrapCheckpoint',
                'Update-BootstrapCheckpointSchema',
                'Invoke-BootstrapStage'
            )
        }, $true)
    foreach ($functionAst in $checkpointFunctions)
    {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
}

Describe 'Azure lab bootstrap checkpoint' {
    BeforeEach {
        $script:BootstrapPhaseCount = 12
        $script:BootstrapCheckpointPath = Join-Path -Path $TestDrive -ChildPath 'bootstrap-checkpoint.json'
        $script:BootstrapCheckpoint = @{
            SchemaVersion   = 2
            Fingerprint     = 'test'
            CompletedStages = @()
            CurrentStage    = $null
        }
        $script:StageActionCount = 0
    }

    It 'Migrates old checkpoints and retries machine preparation once' {
        $checkpoint = '{"SchemaVersion":1,"Fingerprint":"test","CompletedStages":["import-repository","prepare-machine","verify-import"],"CurrentStage":"restore-target-dependencies"}' |
            ConvertFrom-Json -AsHashtable

        Update-BootstrapCheckpointSchema -Checkpoint $checkpoint | Should -BeTrue

        $checkpoint.SchemaVersion | Should -Be 2
        $checkpoint.CompletedStages | Should -Be @('import-repository', 'verify-import')
        $checkpoint.CurrentStage | Should -Be 'restore-target-dependencies'
        Update-BootstrapCheckpointSchema -Checkpoint $checkpoint | Should -BeFalse
    }

    It 'Skips a stage after its completion was persisted' {
        $action = { $script:StageActionCount++ }

        Invoke-BootstrapStage -Index 3 -Name 'test-stage' -Description 'Test stage' -Action $action
        Invoke-BootstrapStage -Index 3 -Name 'test-stage' -Description 'Test stage' -Action $action

        $script:StageActionCount | Should -Be 1
        $script:BootstrapCheckpoint.CompletedStages | Should -Contain 'test-stage'
        (Get-Content -LiteralPath $script:BootstrapCheckpointPath -Raw | ConvertFrom-Json).CompletedStages |
            Should -Contain 'test-stage'
    }

    It 'Retries an interrupted stage and clears its current-stage marker after success' {
        { Invoke-BootstrapStage -Index 3 -Name 'test-stage' -Description 'Test stage' -Action { throw 'Simulated failure' } } |
            Should -Throw 'Simulated failure'

        $script:BootstrapCheckpoint.CurrentStage | Should -Be 'test-stage'

        Invoke-BootstrapStage -Index 3 -Name 'test-stage' -Description 'Test stage' -Action { $script:StageActionCount++ }

        $script:StageActionCount | Should -Be 1
        $script:BootstrapCheckpoint.CurrentStage | Should -BeNullOrEmpty
        $script:BootstrapCheckpoint.CompletedStages | Should -Contain 'test-stage'
    }
}
