
function get-ExOAdminApiResult {
    <#
        Author               = "Jos Lieben (jos@lieben.nu)"
        CompanyName          = "Lieben Consultancy"
        Copyright            = "https://www.lieben.nu/liebensraum/commercial-use/"
    #>        
    [CmdletBinding()]
    Param(
        [parameter(Mandatory = $True)]$userPrincipalName,
        $folderId,
        [Switch]$NoPagination,
        $retryCount = 3
    )
    $token = Get-AccessToken -Resource "https://outlook.office365.com"

    if(!$global:OnMicrosoft){
        $global:OnMicrosoft = (New-GraphQuery -Method GET -Uri 'https://graph.microsoft.com/v1.0/domains?$top=999' | Where-Object -Property isInitial -EQ $true).id
    }
    
    $Headers = @{ 
        Authorization     = "Bearer $token"
        'X-AnchorMailbox' = "UPN:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$($global:OnMicrosoft)"
    }

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($userPrincipalName)
    $encodedUpn =[Convert]::ToBase64String($Bytes)
    if($folderId){
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($folderId)
        $encodedfolderId =[Convert]::ToBase64String($Bytes)        
        $nextURL = "https://outlook.office365.com/adminapi/beta/$($global:OnMicrosoft)/Mailbox('$encodedUpn')/MailboxFolder('$encodedfolderId')/MailboxFolderPermission?IsUsingMailboxFolderId=True&isEncoded=true"
    }else{
        $nextURL = "https://outlook.office365.com/adminapi/beta/$($global:OnMicrosoft)/Mailbox('$encodedUpn')/MailboxFolder/Exchange.GetMailboxFolderStatistics(folderscope=Exchange.ElcFolderType'All')?isEncoded=true"
    }

    $ReturnedData = do {
        try {
            $attempts = 0
            while ($attempts -lt $retryCount) {
                try {
                    $Data = Invoke-RestMethod -Uri $nextURL -Method GET -Headers $Headers -ContentType 'application/json; charset=utf-8'
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