
function New-GraphQuery {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    Param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,    
        
        [Parameter(Mandatory = $false)]
        [string]$Body,        

        [Parameter(Mandatory = $false)]
        [Switch]$NoPagination,

        [Parameter(Mandatory = $false)]
        [Switch]$ComplexFilter,

        [Parameter(Mandatory = $false)]
        [Switch]$NoRetry,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 5,

        [Parameter(Mandatory = $false)]
        [String]$resource = "https://graph.microsoft.com",

        [Parameter(Mandatory = $false)]
        [Int]$expectedTotalResults = 0

    )

    $headers = get-AccessToken -resource $resource -returnHeader

    if($expectedTotalResults -gt 0){
        Write-Progress -Id 10 -Activity "Querying $resource API" -Status "Retrieving initial batch of $expectedTotalResults expected records" -PercentComplete 0
    }

    if($resource -eq "https://www.sharepoint.com"){
        $headers['Accept'] = "application/json;odata=nometadata"
    }    

    if ($ComplexFilter) {
        $headers['ConsistencyLevel'] = 'eventual'
        if ($uri -notlike "*`$count*") {
            $uri = $uri.Replace("?", "?`$count=true&")
        }
    }
    $nextURL = $uri

    if ($NoRetry) {
        $MaxAttempts = 1
    }

    if($Method -in ('POST', 'PATCH')){
        try {
            $attempts = 0
            while ($attempts -lt $MaxAttempts) {
                $attempts ++
                try {
                    [System.GC]::Collect()        
                    $Data = (Invoke-RestMethod -Uri $nextURL -Method $Method -Headers $headers -Body $Body -ContentType 'application/json; charset=utf-8' -ErrorAction Stop)
                }
                catch {
                    if ($attempts -ge $MaxAttempts) { 
                        Throw $_
                    }
                    Start-Sleep -Seconds (1 + (2 * $attempts))
                }     
            }
        }catch {
            $Message = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error.message
            if ($null -eq $Message) { $Message = $($_.Exception.Message) }
            throw $Message
        }                               
        return $Data
    }else{
        $totalResults = 0
        $ReturnedData = do {
            try {
                $attempts = 0
                while ($attempts -lt $MaxAttempts) {
                    $attempts ++
                    try {
                        [System.GC]::Collect()
                        $Data = (Invoke-RestMethod -Uri $nextURL -Method $Method -Headers $headers -ContentType 'application/json; charset=utf-8' -ErrorAction Stop -Verbose:$false)
                        $attempts = $MaxAttempts
                    }
                    catch {
                        if ($attempts -ge $MaxAttempts) { 
                            $nextURL = $null
                            Throw $_
                        }
                        Start-Sleep -Seconds (1 + (2 * $attempts))
                    }
                }
                if($resource -eq "https://www.sharepoint.com"){
                    $Data = $Data | ConvertFrom-Json -AsHashtable
                }

                if($Data.psobject.properties.name -icontains 'value' -or $Data.Keys -icontains 'value'){
                    $totalResults+=$Data.value.count
                    ($Data.value)
                }else{
                    $totalResults+=$Data.count                
                    ($Data)
                }
                if($expectedTotalResults -gt 0){
                    Try {$percentComplete = ($totalResults / $expectedTotalResults * 100)}Catch{$percentComplete = 0}
                    Write-Progress -Id 10 -Activity "Querying $resource API" -Status "Retrieved $totalResults of $expectedTotalResults items" -PercentComplete $percentComplete
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
            }
            catch {
                throw $_
            }
        } until ($null -eq $nextURL)
        Write-Progress -Id 10 -Completed -Activity "Querying $resource API"
        if ($ReturnedData -and !$ReturnedData.value -and $ReturnedData.PSObject.Properties["value"]) { return $null }
        [System.GC]::Collect()
        return $ReturnedData
    }
}