function Test-TransientPSResourceFailure
{
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $messages = [System.Collections.Generic.List[string]]::new()
    $exception = $ErrorRecord.Exception

    while ($null -ne $exception)
    {
        if ($exception.Message)
        {
            $messages.Add($exception.Message)
        }

        $statusCodeProperty = $exception.PSObject.Properties['StatusCode']
        if ($null -ne $statusCodeProperty -and $null -ne $statusCodeProperty.Value)
        {
            $statusCode = 0
            $hasStatusCode = if ($statusCodeProperty.Value -is [System.Enum])
            {
                $statusCode = [int]$statusCodeProperty.Value
                $true
            }
            else
            {
                [int]::TryParse([string]$statusCodeProperty.Value, [ref]$statusCode)
            }

            if ($hasStatusCode -and
                ($statusCode -eq 408 -or $statusCode -eq 429 -or ($statusCode -ge 500 -and $statusCode -le 599)))
            {
                return $true
            }
        }

        $exception = $exception.InnerException
    }

    $failureText = "$($ErrorRecord.FullyQualifiedErrorId) $($ErrorRecord.ToString()) $($messages -join ' ')"
    return $failureText -match '(?i)(?:\b408\b|\b429\b|\b5\d{2}\b|too many requests|service unavailable|temporarily unavailable|timed?\s*out|unable to connect|connection.*(?:reset|closed|refused|aborted)|(?:host|name) could not be resolved|no such host|name resolution|network is unreachable)'
}

function Invoke-SavePSResourceWithRetry
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameters,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ModuleName,

        [Parameter()]
        [ValidateRange(0, 8)]
        [int] $RetryCount = 4,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int] $InitialDelaySeconds = 5
    )

    $maximumAttempts = $RetryCount + 1
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++)
    {
        Write-Host "PowerShell Gallery restore: '$ModuleName', attempt $attempt/$maximumAttempts." -ForegroundColor Cyan

        $saveErrors = @()
        $saveError = $null
        try
        {
            $null = Save-PSResource @Parameters -ErrorAction Stop -ErrorVariable saveErrors
        }
        catch
        {
            $saveError = $_
        }

        if ($null -eq $saveError -and $saveErrors.Count -gt 0)
        {
            $saveError = $saveErrors[0]
        }

        if ($null -eq $saveError)
        {
            Write-Host "PowerShell Gallery restore succeeded for '$ModuleName' on attempt $attempt/$maximumAttempts." -ForegroundColor Green
            return
        }

        if (-not (Test-TransientPSResourceFailure -ErrorRecord $saveError))
        {
            throw $saveError.Exception
        }

        if ($attempt -eq $maximumAttempts)
        {
            throw [System.InvalidOperationException]::new(
                "Transient PowerShell Gallery failure restoring '$ModuleName' after $maximumAttempts attempts: $($saveError.Exception.Message)",
                $saveError.Exception
            )
        }

        $backoffSeconds = [int]($InitialDelaySeconds * [System.Math]::Pow(2, $attempt - 1))
        $jitterSeconds = Get-Random -Minimum 0 -Maximum 4
        $delaySeconds = [System.Math]::Min(60, $backoffSeconds + $jitterSeconds)
        Write-Warning "Transient PowerShell Gallery failure for '$ModuleName' on attempt $attempt/${maximumAttempts}: $($saveError.Exception.Message)"
        Write-Host "Retrying '$ModuleName' in $delaySeconds second(s); next attempt is $($attempt + 1)/$maximumAttempts." -ForegroundColor Yellow
        Start-Sleep -Seconds $delaySeconds
    }
}
