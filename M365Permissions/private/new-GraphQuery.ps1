
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
        [String]$resource = "https://graph.microsoft.com" 
    )

    $headers = get-AccessToken -resource $resource -returnHeader

    if($resource -eq "https://www.sharepoint.com"){
        $headers['Accept'] = "application/json;odata=verbose"
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
        $ReturnedData = do {
            try {
                $attempts = 0
                while ($attempts -lt $MaxAttempts) {
                    $attempts ++
                    try {
                        [System.GC]::Collect()
                        $Data = (Invoke-RestMethod -Uri $nextURL -Method $Method -Headers $headers -ContentType 'application/json; charset=utf-8' -ErrorAction Stop)
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
                    $Data = ($Data | convertfrom-json -Depth 999 -AsHashtable).d
                    ($Data.Keys -icontains 'results') ? ($Data.results) : ($Data)
                    ($NoPagination) ? $($nextURL = $null) : $($nextURL = $Data.__next)
                }else{
                    ($Data.psobject.properties.name -icontains 'value') ? ($Data.value) : ($Data)
                    ($NoPagination) ? $($nextURL = $null) : $($nextURL = $Data.'@odata.nextLink')
                }
            }
            catch {
                throw $Message
            }
        } until ($null -eq $nextURL)

        if ($ReturnedData -and !$ReturnedData.value -and $ReturnedData.PSObject.Properties["value"]) { return $null }
        [System.GC]::Collect()
        return $ReturnedData
    }
}