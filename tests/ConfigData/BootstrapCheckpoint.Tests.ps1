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

    $checkpointFunctions = $bootstrapAst.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $_.Name -in @(
                'Write-BootstrapPhase',
                'Complete-BootstrapPhase',
                'Test-SourceDependencyRestoreComplete',
                'Save-BootstrapCheckpoint',
                'Update-BootstrapCheckpointSchema',
                'Invoke-BootstrapStage',
                'Update-BootstrapRepositoryCheckpoint'
            )
        }
    foreach ($functionAst in $checkpointFunctions)
    {
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }
    $script:InitialPhaseActions = @{}
    $statements = $bootstrapAst.EndBlock.Statements
    for ($index = 0; $index -lt $statements.Count - 2; $index++)
    {
        if ($statements[$index] -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
        $command = $statements[$index].PipelineElements[0]
        if ($command -isnot [System.Management.Automation.Language.CommandAst] -or
            $command.GetCommandName() -ne 'Write-BootstrapPhase') { continue }
        $phaseIndex = [int]$command.CommandElements[2].Value
        $script:InitialPhaseActions[$phaseIndex] = [scriptblock]::Create(
            ($statements[$index..($index + 2)] | ForEach-Object { $_.Extent.Text }) -join "`n"
        )
    }
}

Describe 'Azure lab bootstrap checkpoint' {
    BeforeEach {
        $script:BootstrapPhaseCount = 13
        $script:BootstrapCheckpointPath = Join-Path -Path $TestDrive -ChildPath 'bootstrap-checkpoint.json'
        $script:BootstrapCheckpoint = @{
            SchemaVersion   = 3
            Fingerprint     = 'test'
            CompletedStages = @()
            CurrentStage    = $null
        }
        $script:StageActionCount = 0
        $script:PhaseMessages = [Collections.Generic.List[string]]::new()
        Mock Write-Host {
            param($Object)
            $script:PhaseMessages.Add([string]$Object)
        }
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

    It 'Updates the repository checkpoint after the import stage returns (already completed: <AlreadyCompleted>)' -ForEach @(
        @{ AlreadyCompleted = $false }
        @{ AlreadyCompleted = $true }
    ) {
        if ($AlreadyCompleted)
        {
            $script:BootstrapCheckpoint.CompletedStages = @('import-repository')
        }

        Invoke-BootstrapStage -Index 4 -Name 'import-repository' -Description 'Synchronize repository' -Action {}
        Update-BootstrapRepositoryCheckpoint -Commit 'synchronized-commit'

        (Get-Content -LiteralPath $script:BootstrapCheckpointPath -Raw | ConvertFrom-Json).RepositoryCommit |
            Should -Be 'synchronized-commit'
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

    It 'Reports timestamps and measured elapsed seconds for a successful phase <PhaseIndex>' -ForEach @(
        @{ PhaseIndex = 3 }
        @{ PhaseIndex = 13 }
    ) {
        Invoke-BootstrapStage -Index $PhaseIndex -Name 'timed-stage' -Description 'Timed stage' `
            -Action { [Threading.Thread]::Sleep(40) }

        $script:PhaseMessages | Where-Object { $_ -like 'Started:*' } |
            Should -Match '^Started: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2}$'
        $completion = @($script:PhaseMessages | Where-Object { $_ -like '*finished:*' })
        $completion.Count | Should -Be 1
        $completion[0] | Should -Match ('^Phase {0:D2}/13 finished: .* \| Status: Completed \| Elapsed: [0-9.,]+s$' -f $PhaseIndex)
        $elapsedText = [regex]::Match($completion[0], 'Elapsed: ([0-9.,]+)s').Groups[1].Value
        [double]::Parse($elapsedText) | Should -BeGreaterOrEqual 0.040
        $script:BootstrapPhaseTimer.IsRunning | Should -BeFalse
    }

    It 'Finishes the timer on an action or checkpoint failure (<FailureAt>) without reporting success' -ForEach @(
        @{ FailureAt = 'Action' }
        @{ FailureAt = 'Checkpoint' }
    ) {
        if ($FailureAt -eq 'Checkpoint')
        {
            Mock Save-BootstrapCheckpoint { throw 'Simulated timer failure' }
        }
        { Invoke-BootstrapStage -Index 9 -Name 'timed-stage' -Description 'Timed stage' `
                -Action { throw 'Simulated timer failure' } } | Should -Throw 'Simulated timer failure'

        $script:PhaseMessages | Where-Object { $_ -like '*finished:*' } |
            Should -Match 'Phase 09/13 finished: .*Status: Failed.*Elapsed: [0-9.,]+s'
        @($script:PhaseMessages | Where-Object { $_ -like '*Status: Completed*' }).Count | Should -Be 0
        $script:BootstrapPhaseTimer.IsRunning | Should -BeFalse
        $script:BootstrapCheckpoint.CompletedStages | Should -Not -Contain 'timed-stage'
    }

    It 'Reports a skipped phase without running its action' {
        $script:BootstrapCheckpoint.CompletedStages = @('timed-stage')

        Invoke-BootstrapStage -Index 9 -Name 'timed-stage' -Description 'Timed stage' `
            -Action { $script:StageActionCount++ }

        $script:StageActionCount | Should -Be 0
        @($script:PhaseMessages | Where-Object { $_ -like 'Started:*' }).Count | Should -Be 1
        $script:PhaseMessages | Where-Object { $_ -like '*finished:*' } |
            Should -Match 'Phase 09/13 finished: .*Status: Skipped.*Elapsed: [0-9.,]+s'
        $script:BootstrapPhaseTimer.IsRunning | Should -BeFalse
    }

    It 'Times phase 1 even when dependencies are already installed' {
        $repositoryRoot = $TestDrive
        $sourceRequiredModules = $TestDrive
        $ForceDependencyRestore = $false
        Mock Test-SourceDependencyRestoreComplete { $true }

        . ($script:InitialPhaseActions[1])

        $script:PhaseMessages | Where-Object { $_ -like '*finished:*' } |
            Should -Match 'Phase 01/13 finished: .*Status: Skipped.*Elapsed: [0-9.,]+s'
        $script:PhaseMessages | Should -Contain 'Skipping phase 01/13: all required dependency versions are already installed.'
        $script:BootstrapPhaseTimer.IsRunning | Should -BeFalse
    }

    It 'Finishes initial phase <PhaseIndex> timers when dependency or configuration loading fails' -ForEach @(
        @{ PhaseIndex = 1 }
        @{ PhaseIndex = 2 }
    ) {
        $repositoryRoot = $TestDrive
        $sourceRequiredModules = $TestDrive
        $ForceDependencyRestore = $false
        Mock Test-SourceDependencyRestoreComplete { throw 'Initial phase failure' }
        Mock Import-Module { throw 'Initial phase failure' }

        { . ($script:InitialPhaseActions[$PhaseIndex]) } | Should -Throw 'Initial phase failure'

        $script:PhaseMessages | Where-Object { $_ -like '*finished:*' } |
            Should -Match ('Phase {0:D2}/13 finished: .*Status: Failed.*Elapsed: [0-9.,]+s' -f $PhaseIndex)
        $script:BootstrapPhaseTimer.IsRunning | Should -BeFalse
    }
}
