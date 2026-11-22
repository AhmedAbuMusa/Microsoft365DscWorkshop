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
                'Invoke-BootstrapStage',
                'Update-BootstrapRepositoryCheckpoint'
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
            SchemaVersion   = 3
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

        $checkpoint.SchemaVersion | Should -Be 3
        $checkpoint.CompletedStages | Should -Be @('import-repository')
        $checkpoint.CurrentStage | Should -Be 'restore-target-dependencies'
        Update-BootstrapCheckpointSchema -Checkpoint $checkpoint | Should -BeFalse
    }

    It 'Invalidates import verification and build initialization from schema 2 without losing later completed work' {
        $checkpoint = @{
            SchemaVersion   = 2
            Fingerprint     = 'test'
            CompletedStages = @(
                'import-repository'
                'verify-import'
                'prepare-machine'
                'restore-target-dependencies'
                'initialize-target-build'
                'register-applications'
                'test-connections'
                'configure-devops'
            )
            CurrentStage    = 'create-vms'
        }

        Update-BootstrapCheckpointSchema -Checkpoint $checkpoint | Should -BeTrue

        $checkpoint.SchemaVersion | Should -Be 3
        $checkpoint.CompletedStages | Should -Be @(
            'import-repository'
            'prepare-machine'
            'restore-target-dependencies'
            'register-applications'
            'test-connections'
            'configure-devops'
        )
        $checkpoint.CurrentStage | Should -Be 'create-vms'
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

    It 'Invalidates downstream work when the synchronized GitHub revision changes' {
        $script:BootstrapCheckpoint['RepositoryCommit'] = 'old-commit'
        $script:BootstrapCheckpoint.CompletedStages = @(
            'bootstrap-project-settings', 'import-repository', 'verify-import',
            'restore-target-dependencies', 'register-applications', 'create-vms'
        )

        Update-BootstrapRepositoryCheckpoint -Commit 'new-commit'

        $script:BootstrapCheckpoint.CompletedStages | Should -Be @('bootstrap-project-settings', 'import-repository')
        (Get-Content -LiteralPath $script:BootstrapCheckpointPath -Raw | ConvertFrom-Json).RepositoryCommit |
            Should -Be 'new-commit'
    }

    It 'Preserves completed downstream work when GitHub has not changed' {
        $script:BootstrapCheckpoint['RepositoryCommit'] = 'same-commit'
        $script:BootstrapCheckpoint.CompletedStages = @('import-repository', 'register-applications')

        Update-BootstrapRepositoryCheckpoint -Commit 'same-commit'

        $script:BootstrapCheckpoint.CompletedStages | Should -Be @('import-repository', 'register-applications')
    }

    It 'Revalidates downstream work from checkpoints without a repository revision' {
        $script:BootstrapCheckpoint.CompletedStages = @('import-repository', 'initialize-target-build')

        Update-BootstrapRepositoryCheckpoint -Commit 'first-recorded-commit'

        $script:BootstrapCheckpoint.CompletedStages | Should -Be @('import-repository')
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
