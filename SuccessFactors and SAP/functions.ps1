#Function that logs to the html log which is later used to send a summary email
function add-HTMLLogEntry{
    Param(
        [Parameter(Mandatory=$true)]$userID,
        $displayName,
        [Parameter(Mandatory=$true)]$logText,
        $sourceRow,
        [Switch]$warning,
        [Switch]$error
    )
    $color = "GREEN"
    $text = "SUCCEEDED"
    if($warning){
        $color = "yellow"
        $text = "WARNING"
    }
    if($error){
        $color = "red"
        $text = "ERROR"
        $logText += "$($global:Error[0].Exception) - $sourceRow"
        Write-Error $global:Error[0] -ErrorAction Continue
        Write-Error "$logText" -errorAction continue
    }else{
        Write-Output $logText
    }
    $global:emailLog += [PSCustomObject]@{"index"=[Int]$global:emailLog.Count;"id"=$userID;"name"=$displayName;"color"=$color;"category"=$text;"text"=$logText}
}

#Function that looks for a SINGLE user in AD using a given filter
function get-AdUserByFilter{
    Param(
        [Parameter(Mandatory=$true)]$filter
    )
    if($filter.Length -le 12){
        Throw "Invalid filter used in searching for ADObjects: $filter, aborting to prevent mass-selecting users"
    }
    Write-Verbose "Searching AD for users using filter $filter"
    $adUser = @(Get-ADObject -Filter $filter -ErrorAction Stop -Properties * | Where-Object {$_})
    if($adUser.Count -gt 1){
        Throw "Multiple users returned when searching by $filter, skipping this user"
    }
    if($adUser.Count -eq 1){
        $adUser = $adUser[0]
        Write-Verbose "Existing user found: $($adUser.displayName)"
        return $adUser
    }
    return $Null
} 


#Function that checks if an email address already exists in O365, it can generate a unique one or fail depending on the failIfAlreadyExists switch
function get-emailAddress{
    Param(
        [Parameter(Mandatory=$true)]$desiredAddress,     
        [Switch]$failIfAlreadyExists      
    )
    $count = 1
    $returnAddress = $desiredAddress
    while($true){
        $existingRecipients = Get-o365Recipient $returnAddress -IncludeSoftDeletedRecipients -ErrorAction SilentlyContinue
        $existingMsolUser = Get-MsolUser -UserPrincipalName $returnAddress -ErrorAction SilentlyContinue
        $existingDeletedMsolUser = Get-MsolUser -UserPrincipalName $returnAddress -ReturnDeletedUsers -ErrorAction SilentlyContinue
        if($existingRecipients -or $existingMsolUser -or $existingDeletedMsolUser){
            if($failIfAlreadyExists){
                Throw
            }
            $returnAddress = "$($desiredAddress.Split("@")[0])$($count)@$($desiredAddress.Split("@")[1])"
            $count++
        }else{
            return $returnAddress.ToLower()
        }
    }
}

#build authentication header for API requests to Okta
function new-OktaAuthHeader{
    Param(
        [Parameter(Mandatory=$true)]$oktaToken
    )    
    $authHeader = @{
    'Content-Type'='application/json'
    'Accept'='application/json'
    'Authorization'= 'SSWS '+$oktaToken
    }
    return $authHeader
}

function get-localEmailAddress{
    Param(
        [Parameter(Mandatory=$true)]$desiredAddress,     
        [Switch]$failIfAlreadyExists
    )
    $count = 1
    $returnAddress = $desiredAddress
    while($true){
        [Array]$existingRecipients = @(Get-aduser -Filter {mail -eq $returnAddress} -ErrorAction SilentlyContinue | Where-Object {$_})  
        if($existingRecipients.Count -eq 1){
            if($failIfAlreadyExists){
                Throw
            }
            $returnAddress = "$($desiredAddress.Split("@")[0])$($count)@$($desiredAddress.Split("@")[1])"
            $count++
        }else{
            return $returnAddress.ToLower()
        }
    }
}

function new-SAMAccountName{
    Param(
        [Parameter(Mandatory=$true)][String]$FirstName,
        [Parameter(Mandatory=$true)][String]$LastName
    )
    $count = 1
    $maxLength = 12

    #Remove any whitespace
    $FirstName = $FirstName -replace '\s',''
    $LastName = $LastName -replace '\s',''

    #Loop until we find a free username and return it, or throw an error
    while($True){
        try{
            #ensure the firstname + lastname is not longer than $maxLength
            try{
                $correctedFirstName = $FirstName.SubString(0,$maxLength-$count)
            }catch{
                $correctedFirstName = $FirstName
            }
            if($count -gt $LastName.Length){Throw}
	        $SamAccountName = "$($correctedFirstName.ToLower())$($LastName.SubString(0,$count).ToLower())"
        }catch{
            Throw "Failed to generate SAM AccountName with inputs $FirstName and $LastName"
        }
	    try{
		    $Null = Get-ADUser -identity $SamAccountName
	        $count++	    
        }catch{
		    return $SamAccountName
	    }
    }
}

function New-RandomPassword ([int]$intPasswordLength)
{
   $strNumbers = "123456789"
   $strCapitalLetters = "ABCDEFGHJKMNPQRSTUVWXYZ"
   $strLowerLetters = "abcdefghjkmnpqrstuvwxyz"
   $rand = new-object random

   for ($a=1; $a -le $intPasswordLength; $a++)
      {
         if ($a -gt 3)
           {
      	      $b = $rand.next(0,3) + $a
      	      $b = $b % 3 + 1
      	   } else { $b = $a }
      	 switch ($b)
      	   {
      	      "1" {$b = "$strNumbers"}
      	      "2" {$b = "$strCapitalLetters"}
      	      "3" {$b = "$strLowerLetters"}
      	   }
         $charset = $($b)
         $number = $rand.next(0,$charset.Length)
         $RandomPassword += $charset[$number]
      }
   return $RandomPassword
}

function buildResilientExchangeOnlineSession {
    Param(
        [Parameter(Mandatory=$true)]$o365Creds,
        $commandPrefix
    )
    Write-Verbose "Connecting to Exchange Online"
    Set-Variable -Scope Global -Name o365Creds -Value $o365Creds -Force
    $Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri https://outlook.office365.com/powershell-liveid/ -Credential $o365Creds -Authentication Basic -AllowRedirection
    Import-PSSession $Session -AllowClobber -DisableNameChecking
    Write-Verbose "Connected to Exchange Online, exporting module..."
    $temporaryModulePath = (Join-Path $Env:TEMP -ChildPath "temporaryEXOModule")
    $Null = Export-PSSession -Session $Session -CommandName * -OutputModule $temporaryModulePath -AllowClobber -Force
    $temporaryModulePath = Join-Path $temporaryModulePath -ChildPath "temporaryEXOModule.psm1"
    Write-Verbose "Rewriting Exchange Online module, please wait..."
    $regex=’^.*\bhost\.UI\.PromptForCredential\b.*$’
    (Get-Content $temporaryModulePath) -replace $regex, "-Credential `$global:o365Creds ``" | Set-Content $temporaryModulePath
    $Session | Remove-PSSession -Confirm:$False
    Write-Verbose "Module rewritten, re-importing..."
    if($commandPrefix){
        Import-Module -Name $temporaryModulePath -Prefix $commandPrefix -DisableNameChecking -WarningAction SilentlyContinue -Force
        Write-Verbose "Module imported, you may now use all Exchange Online commands using $commandPrefix as prefix"
    }else{
        Import-Module -Name $temporaryModulePath -DisableNameChecking -WarningAction SilentlyContinue -Force
        Write-Verbose "Module imported, you may now use all Exchange Online commands"
    }
    return $temporaryModulePath
}

function get-availableAdName{
    Param(
        $OUPath,
        $Name
    )
    $newName = $Name
    $count = 0
    while($true){
        $existingUser = Get-ADUser -SearchBase $targetOU -Filter {cn -eq $newName}
        if($existingUser.Count -eq 0){
            return $newName
        }else{
            $count++
            $newName = "$Name ($count)"
            if($count -gt 10){
                Throw "Could not find a unique name after 10 attempts to find a unique name for $Name in $OUPath"
            }
        }
    }
}

function get-twoLetterCountryCode{
    Param(
        $inputCode
    )
    $code = @($countryCodes | Where-Object {$_.THREE -eq $inputCode -and $_})
    if($code.Count -eq 1 -and $code.TWO){
        return $code.TWO
    }else{
        Throw "No or too many country codes found while searching CSV for $inputCode"
    }
}

function get-countryName{
    Param(
        $inputCode
    )
    $code = @($countryCodes | Where-Object {$_.THREE -eq $inputCode -and $_})
    if($code.Count -eq 1 -and $code.displayName){
        return $code.displayName
    }else{
        Throw "No or too many country codes found while searching CSV for $inputCode"
    }
}

function Remove-Diacritics
{
    Param(
        [String]$inputString,
        [switch]$andSpaces
    )
    #replace diacritics
    $sb = [Text.Encoding]::ASCII.GetString([Text.Encoding]::GetEncoding("Cyrillic").GetBytes($inputString))

    #remove spaces and anything the above function may have missed
    if($andSpaces){
        return($sb -replace '[^a-zA-Z0-9]', '')
    }else{
        return($sb -replace '[^a-zA-Z0-9 ]', '')
    }
}