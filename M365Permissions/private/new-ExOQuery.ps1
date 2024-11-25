
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
        [Switch]$NoPagination,
        $retryCount = 3
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

    $Headers = @{ 
        Authorization     = "Bearer $token"
        "Accept-Charset"   = "UTF-8"
        "X-ResponseFormat" = "json"
        "Accept" = "application/json"
        "X-ClientApplication" ="ExoManagementModule"
        "Prefer" = "odata.maxpagesize=1000"
        "X-CmdletName"= $cmdlet
        "X-SerializationLevel" = "Partial"
        'X-AnchorMailbox' = "UPN:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$($global:octo.OnMicrosoft)"
        "Content-Type" = "application/json"
    }

    $nextURL = "https://outlook.office365.com/adminapi/beta/$($global:octo.OnMicrosoft)/InvokeCommand"

    $ReturnedData = do {
        try {
            $attempts = 0
            while ($attempts -lt $retryCount) {
                try {
                    $Data = Invoke-RestMethod -Uri $nextURL -Method POST -Body $ExoBody -Headers $Headers -Verbose:$false         
                    $attempts = $retryCount
                }catch {
                    $attempts++
                    if ($attempts -eq $retryCount) {
                        $nextUrl = $null
                        Throw $_
                    }
                    $sleepTime = $attempts * 2
                    Write-Verbose "EXO request failed, sleeping for $sleepTime seconds..."
                    Start-Sleep -Seconds $sleepTime
                }
            }
            if($NoPagination){
                $nextURL = $null
            }elseif($Data.'@odata.nextLink'){
                $nextURL = $Data.'@odata.nextLink'  
            }elseif($Data.'odata.nextLink'){
                $nextURL = $Data.'odata.nextLink'  
            }else{
                $nextURL = $null 
            } 
            if($Data.psobject.properties.name -icontains 'value' -or $Data.Keys -icontains 'value'){
                ($Data.value)
            }else{         
                ($Data)
            }         
        }catch {
            $ReportedError = ($_.ErrorDetails | ConvertFrom-Json -ErrorAction SilentlyContinue)
            $Message = if ($ReportedError.error.details.message) { $ReportedError.error.details.message } else { $ReportedError.error.innererror.internalException.message }
            if ($null -eq $Message) { $Message = $($_.Exception.Message) }
            throw $Message
        }
    }until($null -eq $nextURL)

    [System.GC]::GetTotalMemory($true) | out-null
    [System.GC]::Collect()
    return $ReturnedData
}