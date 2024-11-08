
function New-ExOQuery {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    [CmdletBinding()]
    Param(
        [parameter(Mandatory = $True)]$cmdlet,
        $cmdParams,
        $retryCount = 1
    )
    $token = Get-AccessToken -Resource "https://outlook.office365.com"
    if ($cmdParams) {
        $Params = $cmdParams
    }else {
        $Params = @{}
    }

    $ExoBody = ConvertTo-Json -Depth 15 -InputObject @{
        CmdletInput = @{
            CmdletName = $cmdlet
            Parameters = $Params
        }
    } 

    if(!$global:OnMicrosoft){
        $global:OnMicrosoft = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' | Where-Object -Property isInitial -EQ $true).id
    }
    
    $Headers = @{ 
        Authorization     = "Bearer $token"
        'X-AnchorMailbox' = "UPN:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$($global:OnMicrosoft)"
    }

    $attempts = 0
    try {
        while ($attempts -lt $retryCount) {
            try {
                $ReturnedData = Invoke-RestMethod "https://outlook.office365.com/adminapi/beta/$($OnMicrosoft)/InvokeCommand" -Method POST -Body $ExoBody -Headers $Headers -ContentType 'application/json; charset=utf-8'
                $attempts = $retryCount
            }
            catch {
                $attempts++
                if ($attempts -eq $retryCount) {
                    Throw $_
                }
                $sleepTime = $attempts * 2
                Write-Verbose "EXO request failed, sleeping for $sleepTime seconds..."
                Start-Sleep -Seconds $sleepTime
            }
        }
    }
    catch {
        $ReportedError = ($_.ErrorDetails | ConvertFrom-Json -ErrorAction SilentlyContinue)
        $Message = if ($ReportedError.error.details.message) { $ReportedError.error.details.message } else { $ReportedError.error.innererror.internalException.message }
        if ($null -eq $Message) { $Message = $($_.Exception.Message) }
        throw $Message
    }

    [System.GC]::GetTotalMemory($true) | out-null
    [System.GC]::Collect()
    return $ReturnedData.value
}