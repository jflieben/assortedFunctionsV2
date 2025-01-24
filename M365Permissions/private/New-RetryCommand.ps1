
function New-RetryCommand {
    Param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments,

        [Parameter(Mandatory = $false)]
        [int]$MaxNumberOfRetries = 5,

        [Parameter(Mandatory = $false)]
        [int]$RetryDelayInSeconds = 30
    )

    $RetryCommand = $true
    $RetryCount = 0
    $RetryMultiplier = 1

    while ($RetryCommand) {
        try {
            & $Command @Arguments
            $RetryCommand = $false
        }catch {
            if ($RetryCount -le $MaxNumberOfRetries) {
                Write-Verbose "$Command failed, retrying in $($RetryDelayInSeconds * $RetryMultiplier) seconds..."
                Start-Sleep -Seconds ($RetryDelayInSeconds * $RetryMultiplier)
                $RetryMultiplier *= 1.2
                $RetryCount++
            }else {
                Write-Verbose "$Command failed permanently after $RetryCount attempts"
                throw $_
            }
        }
    }
}