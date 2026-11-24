BeforeAll {
    Import-Module "$PSScriptRoot\..\..\lab\BootstrapLogging.psm1" -Force
    if (-not ('BootstrapLoggingTestHost' -as [type]))
    {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Security;

public sealed class BootstrapLoggingTestHost : PSHost
{
    private readonly BootstrapLoggingTestUI ui = new BootstrapLoggingTestUI();
    private readonly Guid id = Guid.NewGuid();
    public BootstrapLoggingTestUI TestUI { get { return ui; } }
    public override PSHostUserInterface UI { get { return ui; } }
    public override Guid InstanceId { get { return id; } }
    public override string Name { get { return "Bootstrap logging test"; } }
    public override Version Version { get { return new Version(1, 0); } }
    public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
    public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
    public override void SetShouldExit(int exitCode) { }
    public override void EnterNestedPrompt() { throw new NotSupportedException(); }
    public override void ExitNestedPrompt() { throw new NotSupportedException(); }
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}

public sealed class BootstrapLoggingTestUI : PSHostUserInterface
{
    public readonly List<string> Writes = new List<string>();
    public override PSHostRawUserInterface RawUI { get { return null; } }
    public override string ReadLine() { return "synthetic-input-not-for-log"; }
    public override SecureString ReadLineAsSecureString()
    {
        var value = new SecureString();
        foreach (char character in ReadLine()) value.AppendChar(character);
        return value;
    }
    public override void Write(string value) { Writes.Add(value); }
    public override void Write(ConsoleColor foreground, ConsoleColor background, string value) { Writes.Add(value); }
    public override void WriteLine(string value) { Writes.Add(value); }
    public override void WriteErrorLine(string value) { Writes.Add(value); }
    public override void WriteDebugLine(string value) { Writes.Add(value); }
    public override void WriteVerboseLine(string value) { Writes.Add(value); }
    public override void WriteWarningLine(string value) { Writes.Add(value); }
    public override void WriteProgress(long sourceId, ProgressRecord record) { }
    public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> fields)
    {
        Writes.Add(message);
        var replies = new Dictionary<string, PSObject>();
        foreach (var field in fields)
        {
            Writes.Add(field.Label + " " + field.Name);
            replies[field.Name] = PSObject.AsPSObject(field.ParameterTypeFullName == typeof(SecureString).FullName
                ? (object)ReadLineAsSecureString() : ReadLine());
        }
        return replies;
    }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName)
    { throw new NotSupportedException(); }
    public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName,
        PSCredentialTypes types, PSCredentialUIOptions options)
    { throw new NotSupportedException(); }
    public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
    { throw new NotSupportedException(); }
}
'@
    }
    function Invoke-LoggingChildForTest
    {
        param([string]$ScriptPath, [hashtable]$Arguments = @{}, [string]$LogPath, [string]$InputText = '')
        $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardInput = $true
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            ($Arguments | ConvertTo-Json -Compress)))
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', "$PSScriptRoot\..\..\lab\Invoke Bootstrap Child.ps1",
                '-ScriptPath', $ScriptPath, '-EncodedArguments', $encoded, '-LogPath', $LogPath))
        {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        try
        {
            $output = $process.StandardOutput.ReadToEndAsync()
            $errors = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.WriteLine($InputText)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(30000)) { throw 'Logging child timed out.' }
            return @{ ExitCode = $process.ExitCode; Output = $output.GetAwaiter().GetResult(); Errors = $errors.GetAwaiter().GetResult() }
        }
        finally
        {
            if (-not $process.HasExited) { $process.Kill($true) }
            $process.Dispose()
        }
    }
}

Describe 'Bootstrap detailed output routing' {
    BeforeEach {
        $logPath = Join-Path $TestDrive 'detail.log'
        $console = [Collections.Generic.List[string]]::new()
        Mock Write-Host -ModuleName BootstrapLogging { $console.Add([string]$Object) }
    }
    It 'Keeps routine streams in the detailed log while displaying milestones, warnings and errors' {
        @(
            'native routine output'
            [Management.Automation.InformationRecord]::new('ordinary host message', 'test')
            [Management.Automation.VerboseRecord]::new('verbose diagnostic')
            [Management.Automation.DebugRecord]::new('debug diagnostic')
            [Management.Automation.WarningRecord]::new('The names of some imported commands include unapproved verbs.')
            [Management.Automation.WarningRecord]::new('The VM quota needs attention.')
            [Management.Automation.InformationRecord]::new('[Environment: Dev] Configuring agents', 'test')
            [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Synthetic failure'), 'SyntheticError',
                [Management.Automation.ErrorCategory]::InvalidOperation, $null)
        ) | Write-M365DscBootstrapOutput -LogPath $logPath
        $log = Get-Content -LiteralPath $logPath -Raw
        foreach ($detail in 'native routine output','ordinary host message','verbose diagnostic','debug diagnostic','unapproved verbs')
        {
            $log | Should -Match ([regex]::Escape($detail))
            ($console -join "`n") | Should -Not -Match ([regex]::Escape($detail))
        }
        $console | Should -Contain 'WARNING: The VM quota needs attention.'
        $console | Should -Contain '[Environment: Dev] Configuring agents'
        $console | Should -Contain 'ERROR: Synthetic failure'
    }
    It 'Displays device-login instructions without persisting their code' {
        $instruction = 'To sign in, use https://microsoft.com/devicelogin and enter the code SYNTHETIC-CODE.'
        $instruction | Write-M365DscBootstrapOutput -LogPath $logPath
        $console | Should -Contain $instruction
        (Get-Content -LiteralPath $logPath -Raw) | Should -Not -Match 'SYNTHETIC-CODE'
    }
    It 'Logs all native stderr progress records without mislabeling them as errors' {
        & (Get-Command pwsh).Source -NoLogo -NoProfile -Command '
            [Console]::Error.WriteLine("Synthetic fetch progress");
            [Console]::Error.WriteLine("Synthetic push progress");
            exit 0
        ' *>&1 | Write-M365DscBootstrapOutput -LogPath $logPath
        $LASTEXITCODE | Should -Be 0
        $log = Get-Content -LiteralPath $logPath -Raw
        $log | Should -Match '\[Detail\] Synthetic fetch progress'
        $log | Should -Match '\[Detail\] Synthetic push progress'
        ($console -join "`n") | Should -Not -Match 'ERROR:|Synthetic fetch progress|Synthetic push progress'
    }
    It 'Fails explicitly when detailed output cannot be persisted' {
        { 'routine detail' | Write-M365DscBootstrapOutput -LogPath (Join-Path $TestDrive 'missing\detail.log') } |
            Should -Throw
    }
    It 'Creates a private log accessible only to the current Windows user and SYSTEM' {
        $path = Initialize-M365DscBootstrapLog
        try
        {
            $acl = Get-Acl -LiteralPath $path
            $acl.AreAccessRulesProtected | Should -BeTrue
            $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]).IdentityReference.Value)
            $sids.Count | Should -Be 2
            $sids | Should -Contain ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            $sids | Should -Contain 'S-1-5-18'
        }
        finally { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    }
}

Describe 'Prompt-safe child PowerShell logging' {
    It 'Launches bootstrap children in the current checkout and preserves their exit code' {
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            "$PSScriptRoot\..\..\lab\Start Azure Lab.ps1", [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $helper = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BootstrapChildScript'
        }, $true).Body.GetScriptBlock()
        $script:pwshCommand = Get-Command pwsh
        $script:BootstrapLogPath = Join-Path $TestDrive 'parent child.log'
        $path = Join-Path $TestDrive 'check working directory.ps1'
        @'
param([string]$ExpectedDirectory)
if ((Get-Location).ProviderPath -ne $ExpectedDirectory) { throw 'Child started outside the current checkout.' }
Write-Host 'Verified child working directory'
exit 7
'@ | Set-Content -LiteralPath $path
        Push-Location $TestDrive
        try
        {
            & $helper -Path $path -Arguments @{ ExpectedDirectory = $TestDrive }
            $LASTEXITCODE | Should -Be 7
            (Get-Content -LiteralPath $script:BootstrapLogPath -Raw) | Should -Match 'Verified child working directory'
        }
        finally { Pop-Location }
    }
    It 'Keeps secure Read-Host prompts on the host and out of the logging pipeline' {
        $path = Join-Path $TestDrive 'secure prompt.ps1'
        $logPath = Join-Path $TestDrive 'secure prompt.log'
        @'
$answer = Read-Host -Prompt 'Visible secure credential prompt' -AsSecureString
try {
    if ([Net.NetworkCredential]::new('', $answer).Password -ne 'synthetic-input-not-for-log') { throw 'Incorrect secure input.' }
    Write-Host 'ordinary detail after secure input'
    Write-Host '[Environment: Dev] Secure input completed'
}
finally { $answer.Dispose() }
'@ | Set-Content -LiteralPath $path
        $testHost = [BootstrapLoggingTestHost]::new()
        $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($testHost)
        $runspace.Open()
        $powershell = [Management.Automation.PowerShell]::Create()
        $powershell.Runspace = $runspace
        try
        {
            $null = $powershell.AddCommand("$PSScriptRoot\..\..\lab\Invoke Bootstrap Child.ps1").
                AddParameter('ScriptPath', $path).
                AddParameter('EncodedArguments', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{}'))).
                AddParameter('LogPath', $logPath)
            $powershell.Invoke() | Out-Null
            $powershell.HadErrors | Should -BeFalse -Because ($powershell.Streams.Error -join "`n")
            ($testHost.TestUI.Writes -join "`n") | Should -Match 'Visible secure credential prompt'
            ($testHost.TestUI.Writes -join "`n") | Should -Match '\[Environment: Dev\] Secure input completed'
            ($testHost.TestUI.Writes -join "`n") | Should -Not -Match 'ordinary detail after secure input'
            (Get-Content -LiteralPath $logPath -Raw) | Should -Not -Match 'synthetic-input-not-for-log'
        }
        finally { $powershell.Dispose(); $runspace.Dispose() }
    }
    It 'Preserves prompts and arguments containing spaces while routing host and native chatter to the log' {
        $path = Join-Path $TestDrive 'child script.ps1'
        $logPath = Join-Path $TestDrive 'child detail.log'
        @'
param([string]$Label)
if ($Label -ne 'value with spaces') { throw 'Incorrect argument forwarding.' }
Write-Host 'Select the Azure subscription for this environment:'
Write-Host '[1] Synthetic subscription option'
Write-Host 'ordinary child host output'
& (Get-Command pwsh).Source -NoLogo -NoProfile -Command "Write-Output 'ordinary native output'"
$answer = Read-Host -Prompt 'Interactive test input'
if ($answer -ne 'synthetic-input-not-for-log') { throw 'Prompt response was not delivered.' }
Write-Host '[Environment: Dev] Child completed'
'@ | Set-Content -LiteralPath $path
        $result = Invoke-LoggingChildForTest -ScriptPath $path -Arguments @{ Label = 'value with spaces' } `
            -LogPath $logPath -InputText 'synthetic-input-not-for-log'
        $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.Errors)
        $result.Output | Should -Match '\[Environment: Dev\] Child completed'
        $result.Output | Should -Match 'Select the Azure subscription for this environment:'
        $result.Output | Should -Match '\[1\] Synthetic subscription option'
        $result.Output | Should -Not -Match 'ordinary child host output|ordinary native output'
        $log = Get-Content -LiteralPath $logPath -Raw
        $log | Should -Match 'ordinary child host output'
        $log | Should -Match 'ordinary native output'
        $log | Should -Not -Match 'synthetic-input-not-for-log'
    }
    It 'Keeps child failure exits nonzero and records their diagnostic details' -ForEach @(
        @{ Body = "throw 'Synthetic child failure'"; ExpectedExit = 1 }
        @{ Body = "Write-Host 'child exited deliberately'; exit 7"; ExpectedExit = 7 }
    ) {
        $path = Join-Path $TestDrive 'failed child.ps1'
        $logPath = Join-Path $TestDrive 'failed child.log'
        $Body | Set-Content -LiteralPath $path
        $result = Invoke-LoggingChildForTest -ScriptPath $path -LogPath $logPath
        $result.ExitCode | Should -Be $ExpectedExit
        (Get-Content -LiteralPath $logPath -Raw) | Should -Match 'Synthetic child failure|child exited deliberately'
    }
}
