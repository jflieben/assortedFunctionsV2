<#
    .LICENSE
    Free to use and modify non-commercially, leave headers intact. For commercial use, contact me or my employer
    .SYNOPSIS
    creates/updates/removes/reactivates Active Directory accounts for all users found in a SAP SuccessFactors CSV report from an sFTP server
    .DESCRIPTION
    SAP usually comes with an sFTP server, you can configure SAP SuccessFactors (in the PerformanceManager) to create CSV files with user info. This script will fetch that CSV file and
    create those users for your in your Active Directory depending on how you've configured field mapping

    This script requires WRITE access to the folder it is placed in as it will archive all CSV files to an archive folder
    Run it on a Active Directory connected server with the Activedirectory powershell module installed. Also install the Posh-SSH module, or run elevated on Powershell V5 to auto-install.

    Everything is logged to the script's folder, and all actions are emailed if you configure the script's email settings.
    .EXAMPLE
    .\sync-SuccessFactorsToAD.ps1
    .PARAMETER sFTPHost
    Hostname of your sFTP server, do not use folder paths or protocol names here! (ie: no slashes!)
    Example: prodftp2.successfactors.eu
    .PARAMETER sFTPFolderPath
    Optional parameter to supply a folder path in which your csv file reside, if not in the home folder of the user
    Example: /FEED/UPLOAD
    .PARAMETER sFTPFileName
    Filename of the csv report, if not specified, will use ALL files ending in .csv found in the folder path
    Example: userdelta.csv
    .PARAMETER csvIdentifingColumnName
    CSV column to identify the user, this column should exist in the CSV file and the value is used to generate a user's login and/or email address
    Example: "Email"
    .PARAMETER adIdentifingPropertyName
    Name of the active directory property that identifies the user, it'll be used when searching AD for certain other users (e.g. a user's manager)
    Example: "mail"
    .PARAMETER csvSourceAttributeNames
    Names of the CSV columns you wish to use to seed your AD with as an array (double quotes for each column, seperated by comma like the example)
    Example: "Firstname","Lastname","Position","Email-Manager","Location","Business Phone","Department"
    .PARAMETER adTargetAttributeNameNames
    Names of the Active Directory attributes you wish to seed with info from the CSV (use attribute editor to determine the names of fields)
    Make sure the ORDER of these is the same as csvSourceAttributeNames as they will be mapped as such. Seperate multiple by comma and enclose each field with double quotes like the example
    Example: "givenName","sn","title","manager","physicalDeliveryOfficeName","telephoneNumber","department"
    .PARAMETER MailServer
    hostname of your mailserver, if left empty, no notifications will be sent
    Example: "smtp.outlook.com"
    .PARAMETER MailTo
    Email addresses of users to send notifications to, seperate with comma if multiple recipients are desired
    Example: "jos.lieben@mail.com"
    Example: "jos.lieben@mail.com,servicedesk@company.com"
    .PARAMETER MailFrom
    Email address to send from
    Example: "info@mail.com"
    .NOTES
    filename: invoke-syncSuccessFactorsToActiveDirectory.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 16/07/2019
#>
Param(
    [String]$sFTPHost="prodftp2.successfactors.eu",
    [String]$sFTPFolderPath="FEED/",
    [String]$sFTPFileName,
    [String]$csvUserIdentifier = "UserID",
    [String]$csvManagerIdentifier = "ManagerUserID",
    [Array]$csvSourceAttributeNames = @("UserID","FirstName","LastName","Position","Department","Location","ITPack"),
    [Array]$adTargetAttributeNameNames = @("extensionAttribute4","givenName","sn","title","department","physicalDeliveryOfficeName","extensionAttribute5"),
    [String]$MailTo = "",
    [String]$MailFrom = "",
    [Switch]$readOnly
)

#non parameterized variables
$serviceNOWEmailAddress = ""
$sapIdAdProperty = "extensionAttribute4"
$MailServer = "smtp.office365.com"
$MailServerPort = 587
$MailUseSSL = $True
$mainOfficeOU = "OU=Employees,OU=Accounts,DC=contoso,DC=local"

#determine paths for various files
$startDateTime = Get-Date
$executionPath = [System.IO.Path]::GetDirectoryName($myInvocation.MyCommand.Definition)
$logFile = Join-Path $executionPath -ChildPath "sync-SuccessFactorsToAD.log"
$global:emailLog = @()
$archivePath = Join-Path $executionPath -ChildPath "Archive"
$managerMailTemplatePath = Join-Path $executionPath -ChildPath "managerMailTemplate.html"
$userMailTemplatePath = Join-Path $executionPath -ChildPath "welcomepackMailTemplate.html"
$nldWelcomePackPDF = Join-Path $executionPath -ChildPath "NLDwelcomepackMailAttachment.pdf"

#log everything using transcript built in method
Start-Transcript -Path $logFile -Force

#load custom modules and credentials
try{
    . CredMan.ps1

    $sftpCreds = Read-Creds -Target "LIEBENSCRIPTS_SF_FTP_PRD" #read credentials from credential store
    $o365Creds = Read-Creds -Target "LIEBENSCRIPTS_O365" #read credentials from credential store

    Remove-Variable -Name user

    . functions.ps1

    $sFTPLogin = $sftpCreds.UserName
    $sFTPPassword = $sftpCreds.CredentialBlob
    $sFTPCreds = New-Object System.Management.Automation.PSCredential ($sFTPLogin, (ConvertTo-SecureString $sFTPPassword -AsPlainText -Force))
    $MailServerUsername = $o365Creds.UserName
    $MailServerPassword = $o365Creds.CredentialBlob
    $mailServerCreds = New-Object System.Management.Automation.PSCredential ($MailServerUsername, (ConvertTo-SecureString $MailServerPassword -AsPlainText -Force))

    if($sFTPLogin.Length -lt 2 -or $MailServerUserName -lt 2){
        Throw "Credentials in store were empty"
    }
    Write-Output "will use $sFTPLogin as login for FTP and $MailServerUsername as login to O365"
}catch{
    Write-Error "Failed to retrieve credentials from credential store of the currently logged in user $_" -ErrorAction Stop
}

[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Web")
$res = [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12

$htmlContent = "<html><head><title>SF AD Integration Run Report</title></head><body>Hi,<br><br>"

#create archive path if it doesn't exist already
if(![System.IO.Directory]::Exists($archivePath)){
    Write-Output "Archive folder $archivePath does not yet exist, attempting to create..."
    try{
        New-Item -Path $executionPath -ItemType Directory -Name "Archive" -Force
        Write-Output "$archivePath folder created"
    }catch{
        Write-Error "Failed to create archive folder, script cannot continue, create this folder manually or adjust NTFS permissions"
        Throw $_
    }
}else{
    Write-Output "Archive folder detected at $archivePath"
}

Write-Output "Checking for SFTP PS Module"
$SFTPModule = Get-Module -Name "Posh-SSH" -ListAvailable
if ($Null -eq $SFTPModule) {
    write-Output "Posh-SSH Powershell module not installed...trying to Install, this will fail in an unelevated session"
    try{
        Install-Module Posh-SSH -SkipPublisherCheck -Force -Confirm:$False
        Write-Output "Posh-SSH module installed!"
    }catch{
        write-Error "Install by running 'Install-Module Posh-SSH' from an elevated PowerShell prompt"
        Throw
    }
}

Import-Module "Posh-SSH" -DisableNameChecking

Write-Output "Checking for Active Directory Module"
$ADModule = Get-Module -Name "ActiveDirectory" -ListAvailable
if ($Null -eq $ADModule) {
    write-Error "ActiveDirectory Powershell module not installed...please run this script on a machine that has the AD module installed!" -ErrorAction Stop
    Exit
}
Import-Module "ActiveDirectory" -DisableNameChecking

Write-Output "Loading country codes from CSV"
try{
    $countryCodesCSVPath = Join-Path $executionPath -ChildPath "countrycodes.csv"
    $countryCodes = Import-CSV -Path $countryCodesCSVPath -Encoding UTF8
    Write-Output "Loaded $($countryCodes.Count) countries from CSV at $countryCodesCSVPath"
    if(!$countryCodes[0].displayName -or !$countryCodes[0].TWO -or !$countryCodes[0].THREE){
        Throw "First row of CSV file does not contain the expected columns! $((($countryCodes[0].psobject.Properties | Where-Object {$_.MemberType -eq "NoteProperty"  }).Value -Join ","))"
    }
}catch{
    Write-Error "Failed to load country codes from CSV at $countryCodesCSVPath" -ErrorAction Continue
    Write-Error $_ -ErrorAction Stop
}
    
try{
    Write-Output "Connecting to sFTP host $sFTPHost..."
    $sFTPSession = New-SFTPSession -ComputerName $sFTPHost -Credential $sFTPCreds -AcceptKey -Verbose
    Write-Output "Connected!"
}catch{
    Write-Error $_ -ErrorAction Continue
    Throw "Script cannot continue"
}

if($sFTPFolderPath){
    try{
        Write-Output "Path $sFTPFolderPath was specified, attempting to retrieve contents"
        $sFTPContents = Get-SFTPChildItem -SessionId $sFTPSession.SessionId -Path $sFTPFolderPath -Verbose | Where-Object {$_.FullName.EndsWith(".csv")}
        Write-Output "Retrieved $($sFTPContents.Count) CSV files from $sFTPFolderPath"
    }catch{
        Write-Error "Failed to browse $sFTPFolderPath, please check if it exists and is accessible" -ErrorAction Continue
        Throw $_
    }
}else{
    try{
        Write-Output "No path was specified, attempting to retrieve contents of root folder"
        $sFTPContents = Get-SFTPChildItem -SessionId $sFTPSession.SessionId -Verbose | Where-Object {$_.FullName.EndsWith(".csv")}
        Write-Output "Retrieved $($sFTPContents.Count) CSV files from the root"
    }catch{
        Write-Error "Failed to retrieve files from root, please check the next logged error" -ErrorAction Continue
        Throw $_
    }
}

if($sFTPFileName){
    Write-Output "sFTPFileName was specified, applying filter"
    $sFTPContents = $sFTPContents | Where-Object {$_.FullName.EndsWith($sFTPFileName)}
    Write-Output "$($sFTPContents.Count) files remaining"
}

if(!$sFTPContents){
    write-output "No CSV files were detected on the FTP server, script will exit and log file will not be moved"
    Exit
}

#importing mail templates
try{
    Write-Output "Importing mail templates"
    $managerMailTemplate = Get-Content $managerMailTemplatePath -Raw
    $userMailTemplate = Get-Content $userMailTemplatePath -Raw
    Write-Output "Mail templates imported"
}catch{
    Throw
}

try{
    Write-Output "Loading required modules..."
    Import-Module MSOnline -erroraction Stop
    Connect-MsolService -Credential $mailServerCreds -erroraction Stop
    buildResilientExchangeOnlineSession -o365Creds $mailServerCreds -commandPrefix o365
    add-pssnapin Microsoft.Exchange.Management.PowerShell.E2010
}catch{
    Write-Error "Failed to load required modules" -ErrorAction Continue
    Write-Error $_ -ErrorAction Stop
}

try{
    Write-Output "Connecting to sFTP host $sFTPHost..."
    $sFTPSession = New-SFTPSession -ComputerName $sFTPHost -Credential $sFTPCreds -AcceptKey -Verbose
    Write-Output "Connected!"
}catch{
    Write-Error $_ -ErrorAction Continue
    Throw "Script cannot continue"
}

$htmlContent += "The following CSV files were processed from $sFTPHost<br><table border=`"1`"><tr><td><b>File</b></td><td><b>Records</b></td><td><b>Deleted from FTP?</b></td></tr>"

#download CSV files from SF
$csvFiles = @()
foreach($csvFile in $sFTPContents){ 
    $fileName = "$(Get-Date -format "dd-MM-yyyy-HH-mm")$($csvFile.FullName.Split("/")[-1])"
    $tempFilePath = Join-Path $archivePath -ChildPath $csvFile.FullName.Split("/")[-1]
    $fileDeletedFromFtp = "NO"
    try{
        Write-Output "Downloading $($csvFile.FullName) to $tempFilePath..."
        Get-SFTPFile -SessionId $sFTPSession.SessionId -RemoteFile $csvFile.FullName -LocalPath $archivePath -NoProgress -Overwrite -Verbose
        Rename-Item -Path $tempFilePath -NewName $fileName -Force
        Write-Output "Download completed"
        $finalPath = Join-Path $archivePath -ChildPath $fileName
        $csvFiles += $finalPath
        try{
            $recordCount = @(Import-CSV -Path $finalPath -Encoding UTF8).Count
        }catch{
            $recordCount = "ERROR parsing CSV"
        }
        try{
            if(!$readOnly){
                Remove-SFTPItem -SessionId $sFTPSession.SessionId -Path $csvFile.FullName -Force
            }
            Write-Output "File deleted from FTP server"
            $fileDeletedFromFtp = "YES"
        }catch{
            Write-Output "File not deleted from FTP server"
        }
    }catch{
        $recordCount = "ERROR downloading CSV! $($_.Exception)"
        Write-Error "Failed to download csv file! Ignoring this file" -ErrorAction Continue
        Write-Error $_ -ErrorAction Continue
    }
    $htmlContent += "<tr><td>$($csvFile.FullName)</td><td>$recordCount</td><td>$fileDeletedFromFtp</td></tr>"
}

$htmlContent += "</table>"



if($csvFiles.Count -le 0){
    Write-Output "No files were downloaded, script cannot continue"
    Exit
}

Write-Output "Downloaded $($csvFiles.Count) file(s) to $archivePath"

#seed a hashtable with actions that should be completed after sync
$pendingActions = @{}

$users = @()
foreach($csvFile in ($csvFiles | sort-object -Descending)){
    Write-Output "Opening $csvFile for processing"
    try{
        $csvFileContents = $Null;$csvFileContents = Import-CSV -Path $csvFile -Verbose -Encoding UTF8
        foreach($user in $csvFileContents){
            if($users.$csvUserIdentifier -notcontains $user.$csvUserIdentifier){
                $users += $user
            }else{
                Write-Output "duplicate of $($user.$csvUserIdentifier) detected, only using first occurence"
            }
        }
    }catch{
        $htmlContent += "<b><font color=`"red`">Failed to process csv file $csvFile! Ignoring this file</font></b><br>"
        Write-Error "Failed to process csv file $csvFile! Ignoring this file" -ErrorAction Continue
        Write-Error $_ -ErrorAction Continue
        Continue
    }
}

:usersloop foreach($user in $users){
    #Generate a string value for each CSV row for logging purposes
    try{
        $rowToString = $((($user.psobject.Properties | Where-Object {$_.MemberType -eq "NoteProperty"  }).Value -Join ","))
    }catch{
        $rowToString = "Unknown"
    }

    try{
        #fail this row if the CSV row is missing columns that are required
        if(!$user.$csvUserIdentifier -or !$user."FirstName" -or !$user."LastName" -or !$user.$csvManagerIdentifier -or !$user.'Location' -or !$user.'ITPack' -or $user.Department.Length -le 2){
            Throw "The CSV file did not have one of more of the required columns for this row"
        }
        #fail if SF id is not numeric
        if($user.$csvUserIdentifier -notmatch "^[\d\.]+$"){
            Throw "This row's SF ID is NOT numeric"
        }
        #fail if no manager
        if($user.$csvManagerIdentifier -notmatch "^[\d\.]+$" -and $user.ManagerEmail -notlike "*@*"){
            Throw "This row's managerID and managerEmail are not known"
        }
    }catch{
        add-HTMLLogEntry -userID $csvUserIdentifier -displayName $user.$csvUserIdentifier -logText "CSV Row Validation Error" -error -sourceRow $rowToString
        continue
    }

    $sfId = $user.$csvUserIdentifier

    #add a row to the pendingActions array and configure defaults
    $pendingActions.$sfId = @{
        "originalRow" = $user
        "email"=$user.Email
        "SFStatus"=$user.Status
        "actionType"=$Null
        "actionCompleted"=$False
        "requiresSync"=$False
        "displayName"=$Null
        "password"=$Null
        "countryName"=$Null
        "countryTwoLetterCode"=$Null
        "managerSFID"=$user.$csvManagerIdentifier
        "managerEmail"=$user.ManagerEmail
        "DateStart"=$user.RecruitDate
        "DateEnd"=$user.TerminationDate
        "existsInAd"=$False
        "adObject"=$Null
        "existsInO365"=$False
        "o365Object" = $False
        "office365Groups"=@{
            "NLD-EMS-LEVEL1" = 0;
            "O365-NLD-E3" = 0;
            "O365-NLD-E2" = 0;
            "O365-NLD-EMS_E3" = 0;
            "NLD - All Employees" = 0;  
        };
        "activeDirectoryGroups"=@{
            "O365 ONL AuthOnly" = 0;
            "RemoteGG" = 0;
        }
    }

    #Create filter to search for existing user in AD
    if($pendingActions.$sfId.email -match ".+\@.+\..+"){
        Write-Output "This row has an email address specified, using it in our filter"
        $filter = "(($sapIdAdProperty -eq `"$($sfId)`" -or mail -eq `"$($pendingActions.$sfId.email)`") -and objectClass -eq `"User`" -and objectCategory -eq `"Person`")"
    }else{
        $filter = "($sapIdAdProperty -eq `"$($sfId)`" -and objectClass -eq `"User`" -and objectCategory -eq `"Person`")"
    }
    
    #perform a search for the user
    try{
        $adUser = get-AdUserByFilter -filter $filter
        if($adUser){
            Write-Output "Existing user found: $($adUser.displayName)"
            $pendingActions.$sfId.existsInAd = $True
            $pendingActions.$sfId.adObject = $adUser
            $pendingActions.$sfId.email = $adUser.mail
        }else{
            Write-Output "No user found in AD"
            $pendingActions.$sfId.existsInAd = $False 
        }
    }catch{
        add-HTMLLogEntry -userID $sfId -displayName "Unknown" -logText "Failed trying to find an existing user in AD" -error -sourceRow $rowToString
        Continue
    }

    #check O365 for existing user
    try{
        if($pendingActions.$sfId.email.Length -match ".+\@.+\..+"){
            $userRes = Get-MsolUser -UserPrincipalName $pendingActions.$sfId.email -ErrorAction Stop
            Write-Output "User $($pendingActions.$sfId.email) found in Office 365"
            if(!$userRes) {Throw}
            $pendingActions.$sfId.existsInO365 = $True
            $pendingActions.$sfId.o365Object = $userRes
        }
    }catch{
        Write-Output "$($pendingActions.$sfId.email) not found in Office 365..."
    }

    #Create filter to search for existing manager in AD
    $filter = "($sapIdAdProperty -eq `"$($pendingActions.$sfId.managerSFID)`" -and objectClass -eq `"User`" -and objectCategory -eq `"Person`")"
    
    #perform a search for the manager
    try{
        $manager = get-AdUserByFilter -filter $filter
        #manager found in AD -> compare with SF and use this
        if($manager){
            Write-Output "Existing manager found: $($manager.displayName)"
            if($pendingActions.$sfId.ManagerEmail -match ".+\@.+\..+" -and $pendingActions.$sfId.ManagerEmail -ne $manager.mail){
                add-HTMLLogEntry -userID $sfId -displayName $adUser.displayName -logText "SF Export says this user's manager's email should be $($pendingActions.$sfId.ManagerEmail) but in Active Directory it is $($manager.mail). Maybe update SF? Script will use $($manager.mail)" -warning -sourceRow $rowToString
                $pendingActions.$sfId.ManagerEmail = $manager.mail
            }
        }else{
            #no manager in AD, check O365 and use if found, fail if not
            if($pendingActions.$sfId.ManagerEmail -match ".+\@.+\..+"){
                try{
                    $managerEmail = get-emailAddress -desiredAddress $pendingActions.$sfId.ManagerEmail -failIfAlreadyExists
                    add-HTMLLogEntry -userID $sfId -displayName $adUser.displayName -logText "Could not get user's manager in AD OR Office 365, no credentials will be sent!" -error -sourceRow $rowToString  
                }catch{
                    Write-Output "Could not get user's manager in AD, but did find one in O365"        
                }
            }else{
                Throw "and in O365 because the row did not contain a proper manager emailaddress"
            }
        }
    }catch{
        add-HTMLLogEntry -userID $sfId -displayName $adUser.displayName -logText "Failed trying to find manager in AD" -sourceRow $rowToString -error
    }

    #determine other properties
    $newPassword = New-RandomPassword -intPasswordLength 12
    $user."FirstName" = Remove-Diacritics -inputString ($user."FirstName")
    $user."LastName" = Remove-Diacritics -inputString $user."LastName"
    $pendingActions.$sfId.displayName = "$($user."FirstName") $($user."LastName")"

    #extract the location from the user location field
    try{
        #find last index of a ) symbol
        Write-Output "Parsing user location (country)..."
        $userLocation = $user.Location.SubString($user.Location.LastIndexOf(")")-7,7)
        if($userLocation.Length -ne 7){
            Throw "Invalid location in CSV for this user"
        }
        $pendingActions.$sfId.countryTwoLetterCode = get-twoLetterCountryCode -inputCode $userLocation.SubString(0,3)
        $pendingActions.$sfId.countryName = get-countryName -inputCode $userLocation.SubString(0,3)

        Write-Output "Country code $($pendingActions.$sfId.countryTwoLetterCode) found"
    }catch{
        #fail if we cannot extract the user's location from the CSV file
        add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Could not parse user location from CSV $($user.Location)" -sourceRow $rowToString -error
        Continue                
    }

    #set groups depending on ITPack
    Switch($user.'ITPack'){
        "Standard"{
            $pendingActions.$sfId.office365Groups."O365-NLD-E3" = 1
            $pendingActions.$sfId.office365Groups."O365-NLD-EMS_E3" = 1
            if($adUser -and $adUser.extensionAttribute5 -eq "Basic"){ #if the user exists and currently has a Basic IT Pack that is being upgraded to Standard, add to LEVEL1
                $pendingActions.$sfId.office365Groups."NLD-EMS-LEVEL1" = 1 #0 means do not assign, 1 means assign always, 2 means assign only at create / reactivation of the user
            }else{
                $pendingActions.$sfId.office365Groups."NLD-EMS-LEVEL1" = 2
            }
            $pendingActions.$sfId.activeDirectoryGroups."O365 ONL AuthOnly" = 1
        }
        "Basic"{
            $pendingActions.$sfId.office365Groups."O365-NLD-E2" = 1
            $pendingActions.$sfId.activeDirectoryGroups."O365 ONL AuthOnly" = 1
        }
        "Block"{
            $pendingActions.$sfId.office365Groups."O365-NLD-E2" = 1 #blocking a user through the IT pack means a downgrade to e2 license
            $pendingActions.$sfId.activeDirectoryGroups."O365 ONL AuthOnly" = 1  
            $pendingActions.$sfId.actionType = "deactivate" #by setting the actionType here, the script will not automatically determine the actionType
        }
        Default{
            Write-Output "$($pendingActions.$sfId.displayName) does not have a known ITPack configured: $($user.'ITPack')"
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Employee ITPack type is unknown" -sourceRow $rowToString -error
            continue usersloop
        }
    }

    $targetOU = $mainOfficeOU

    $pendingActions.$sfId.office365Groups."NLD-EMS-THEHAGUEUSERS" = 1
    $pendingActions.$sfId.activeDirectoryGroups."RemoteGG" = 2
    $email = "$($user."FirstName").$($user."LastName")@xxx.nl"

    #if user is voice.global, override email address suffix
    if($user."Department" -like "*50009286*"){
        $email = "$($user."FirstName").$($user."LastName")@voice.global"            
    }

    $email = $email.Replace(" ",".") #replace spaces with dots

    if($pendingActions.$sfId.existsInAd -and $adUser.mail -ne $email){
        Write-Output "I think this user's email should be $email, but user already exists and has $($adUser.mail) as email, script will not change this automatically"
    }

    #determine what we should do with this csv row    
    if($pendingActions.$sfId.actionType -eq $Null){
        if($pendingActions.$sfId.existsInAd){
            if($user.TerminationDate -and [DateTime]$user.TerminationDate -le ((Get-Date).AddDays(-1))){
                $pendingActions.$sfId.actionType = "deactivate"
            }else{
                if((($adUser.UserAccountControl -band 2) -eq 0 -or $adUser.Enabled)){ #account is active
                    $pendingActions.$sfId.actionType = "update" 
                }else{
                    $pendingActions.$sfId.actionType = "activate"    
                }            
            }
        }else{
            if($user.TerminationDate -and [DateTime]$user.TerminationDate -le ((Get-Date).AddDays(-1))){
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User does not exist in AD, so was not disabled, potential issue with SF source data?" -warning
                continue
            }
            $pendingActions.$sfId.actionType = "create"    
        }    
        Write-Output "Calculated user action to be: $($pendingActions.$sfId.actionType)"    
    }else{
        Write-Output "Set user action to be: $($pendingActions.$sfId.actionType)"  
    }

    #activate and move the user if the user already exists but is inactive
    if($pendingActions.$sfId.actionType -eq "activate"){
        try{
            Write-Output "Moving user to $targetOU"
            if(!$readOnly){
                Move-ADObject -TargetPath $targetOU -Identity $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
            }
        }catch{
            Write-Error "Failed to move user to $targetOU" -ErrorAction Continue
            Write-Error $_ -ErrorAction Continue
        }

        try{
            Write-Output "Enabling account of $($adUser.mail)"
            if(!$readOnly){
                Enable-ADAccount -Identity $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
            }
            $pendingActions.$sfId.requiresSync=$True
            $pendingActions.$sfId.actionCompleted = $True
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Reactivated account in AD" -sourceRow $rowToString
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Could not reactivate account in AD, skipping this user" -sourceRow $rowToString -error
            Continue                 
        }

        try{
            Write-Output "Unhide from address book (without checking if this worked)"
            if(!$readOnly){
                Set-ADUser -identity $adUser.ObjectGUID -Replace @{msExchHideFromAddressLists=$False}
            }
        }catch{$Null}

        try{
            Write-Output "Resetting password of $($adUser.mail)"
            if(!$readOnly){
                Set-ADAccountPassword -Reset -newpassword (ConvertTo-SecureString $newPassword -AsPlainText -force) -Identity $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
                Set-ADObject -Identity $adUser.ObjectGUID -Description "User re-enabled from SuccessFactors on $(Get-Date)" -Confirm:$False -ErrorAction Continue
            }
            Write-Output "Password reset"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Could not reset password" -sourceRow $rowToString -error
            Continue                 
        }

        $pendingActions.$sfId.password = $newPassword
    }
    
    if($pendingActions.$sfId.actionType -eq "create"){
        ##Create new AD account in the correct OU
        Write-Output "Discovering available SAMAccountName for user..."
        $samAccountName = new-SAMAccountName -FirstName $user."FirstName" -LastName $user."LastName"
        Write-Output "$samAccountName will be used"

        #check if a user already exists in local AD with this email address and append an integer if needed
        try{
            Write-Output "Checking local AD for $email"
            $email = get-localEmailAddress -desiredAddress $email
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "This user's email address could not be checked for duplicates in local AD, the user will be skipped" -sourceRow $rowToString -error
            Continue                 
        }

        #check if a user already exists in O365 with this email address and fail
        try{
            Write-Output "Checking O365 for $email"
            $email = get-emailAddress -desiredAddress $email -failIfAlreadyExists
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "This user's email address already exists in Office 365: the user already has an account in O365 from somewhere else OR has not been properly deleted from O365 yet. User account will not be created." -sourceRow $rowToString -error
            Continue                  
        }

        $pendingActions.$sfId.email = $email
        Write-Output "$email will be used for this user, and the user will be created in $targetOU"

        try{
            Write-Output "Creating user in AD..."
            $targetCN = get-availableAdName -OUPath $targetOU -Name $pendingActions.$sfId.displayName
            if(!$readOnly){
                $adUser = New-ADUser -Name $targetCN -Surname $user."LastName" -AccountPassword (ConvertTo-SecureString $newPassword -AsPlainText -force) -GivenName $user."FirstName" -Country $($pendingActions.$sfId.countryTwoLetterCode) -DisplayName $pendingActions.$sfId.displayName -SamAccountName $samAccountName -UserPrincipalName $email -EmailAddress $email -Path $targetOU -PassThru -Enabled $True -Description "User auto created from SuccessFactors on $(Get-Date)"
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Created a new account in AD" -sourceRow $rowToString
            $pendingActions.$sfId.requiresSync=$True
            $pendingActions.$sfId.actionCompleted = $True
            $pendingActions.$sfId.existsInAd = $True
            $pendingActions.$sfId.adObject = $adUser
            $pendingActions.$sfId.password = $newPassword
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Could not create a new account in AD" -sourceRow $rowToString -error
            Continue                
        }

        #activeer als lokale remote mailbox
        try{
            Write-Output "Enabling user email properties...."
            if(!$readOnly){
                Start-Sleep -s 120 #sleep due to replication issues
                ##$null = Enable-RemoteMailbox -Id $samAccountName -RemoteRoutingAddress "$($samAccountName)_xxxx@tenantNAME.mail.onmicrosoft.com" -PrimarySmtpAddress $email -Alias "$($samAccountName)_xxxxx"
                Start-Sleep -s 30 #wait for enablement because DC's sometimes sync slowly
                ##$null = Set-RemoteMailbox -Id $samAccountName -EmailAddresses @{Add="$($samAccountName)_xxxx@tenantNAME.mail.onmicrosoft.com"} #add the routing address as a proxy address as this seems to be required
            }
            Write-Output "User configured as RemoteMailbox (Office 365)"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to set up email address sync to Office 365, this means the email properties of this user won't be manageable through AD" -sourceRow $rowToString -warning
        }
    }

    if($pendingActions.$sfId.actionType -eq "deactivate"){

        if((($adUser.UserAccountControl -band 2) -eq 0 -or $adUser.Enabled)){
            $pendingActions.$sfId.requiresSync=$True
        }else{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User has already been deactivated"
            continue
        }
        
        try{
            if(!$readOnly){
                Disable-ADAccount -Identity $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
                Set-ADObject -Identity $adUser.ObjectGUID -Description "User deactivated from SuccessFactors on $(Get-Date)"-Confirm:$False -ErrorAction Continue
            }
            $pendingActions.$sfId.actionCompleted = $True
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Disabled user account" -sourceRow $rowToString
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to disable user" -sourceRow $rowToString -error
        }

        try{
            #determine current OU path and check if there is a disabled OU one level higher
            $UserDNComponents = $adUser.DistinguishedName.Split(",")
            if($UserDNComponents[1] -eq "OU=Employees"){
                #user is in Employees OU, and should be moved to a DISABLED OU
                #strip OU components of employees and replace with _DISABLED
                $DisabledOuPath = "OU=_DISABLED,$($UserDNComponents[2..$($UserDNcomponents.Count)] -Join ",")"
                if([adsi]::Exists("LDAP://$DisabledOuPath")){
                    if(!$readOnly){
                        Move-ADObject -Identity $adUser.ObjectGUID -TargetPath $DisabledOuPath -ErrorAction Stop
                    }
                    add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User moved to the _DISABLED OU" -sourceRow $rowToString
                }else{
                    Throw "No _DISABLED OU found one level above the current user's OU of $($adUser.DistinguishedName)"
                }
            }
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User could not be moved to the _DISABLED OU" -sourceRow $rowToString -error
        }
    }

    #add or remove from local AD group(s)
    foreach($adGroup in $pendingActions.$sfId.activeDirectoryGroups.Keys){
        #skip this group if it is a onetime group (value 2) and user is not being created/reactivated
        if($pendingActions.$sfId.activeDirectoryGroups.$adGroup -eq 2 -and ($pendingActions.$sfId.actionType -eq "deactivate" -or $pendingActions.$sfId.actionType -eq "update")){
            Continue 
        }
        $isMember = $False
        #check if group exists
        try{
            $localGroup = Get-ADGroup -Filter {displayName -eq $adGroup -or cn -eq $adGroup}
            if(!$localGroup){
                Throw "no group with name $adGroup found in local AD"
            }
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Cannot process user local AD group assignments" -sourceRow $rowToString -error
            Continue             
        }
            
        #check if the user is already a member
        $filter = "(objectClass -eq `"user`" -and ObjectGuid -eq `"$($adUser.ObjectGUID)`" -and memberOf -eq `"$($localGroup.DistinguishedName)`")"
        if(@(Get-ADObject -Filter $filter -ErrorAction Stop -Properties * | Where-Object {$_}).Count -eq 1){
            $isMember = $True
        }  
                 
        #user is not a member, but should be
        if(!$isMember -and $pendingActions.$sfId.activeDirectoryGroups.$adGroup -gt 0){
            $pendingActions.$sfId.requiresSync=$True
            try{
                Write-Output "Adding $($pendingActions.$sfId.displayName) to $adGroup"
                if(!$readOnly){
                    Add-AdGroupMember -identity $localGroup.objectGUID -Members $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
                }
                $pendingActions.$sfId.requiresSync=$True
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User added to $adGroup local AD group" -sourceRow $rowToString
            }catch{
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to add user to $adGroup AD group" -sourceRow $rowToString -error
            }
        }

        #user is a member, but should not be
        if($isMember -and $pendingActions.$sfId.activeDirectoryGroups.$adGroup -eq 0){
            $pendingActions.$sfId.requiresSync=$True
            try{
                Write-Output "Removing $($pendingActions.$sfId.displayName) from $adGroup"
                if(!$readOnly){
                    Remove-AdGroupMember -identity $localGroup.objectGUID -Members $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
                }
                $pendingActions.$sfId.requiresSync=$True
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User removed from $adGroup local AD group" -sourceRow $rowToString
            }catch{
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to remove user from $adGroup AD group" -sourceRow $rowToString -error
            }
        }
    }

    #update 'normal' attributes as needed
    for($i=0; $i -lt $csvSourceAttributeNames.Count;$i++){
        $sourceAttributeValue = $user."$($csvSourceAttributeNames[$i])"
        $targetAttributeName = $adTargetAttributeNameNames[$i]
        if($sourceAttributeValue.Length -gt 1 -and $targetAttributeName -and $adUser."$targetAttributeName" -ne $sourceAttributeValue){
            try{
                if(!$readOnly){
                    Set-ADObject -Identity $adUser.ObjectGUID -Replace @{$targetAttributeName=$sourceAttributeValue} -Confirm:$False
                }
                $pendingActions.$sfId.requiresSync=$True
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "$targetAttributeName updated to $sourceAttributeValue" -sourceRow $rowToString
            }catch{
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "$targetAttributeName could not be updated to $sourceAttributeValue" -sourceRow $rowToString -error
                Continue
            }
        }
    }

    #update user manager if needed
    if($manager -and $adUser.manager -ne $manager.distinguishedName){
        try{
            if(!$readOnly){
                Set-ADObject -Identity $adUser.ObjectGUID -Replace @{manager=$manager.distinguishedName} -Confirm:$False
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Manager updated to $($manager.Name)" -sourceRow $rowToString
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to update manager to $($manager.Name)" -sourceRow $rowToString -error
        }
    }

    #update display name if needed
    if($pendingActions.$sfId.displayName -ne $adUser.displayName){
        try{
            if(!$readOnly){
                Set-ADObject -Identity $adUser.ObjectGUID -Replace @{displayName=$pendingActions.$sfId.displayName} -Confirm:$False
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Updated display name to $($pendingActions.$sfId.displayName)" -sourceRow $rowToString
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to update display name to $($pendingActions.$sfId.displayName)" -sourceRow $rowToString -error
        }
    }

    #update cached AD user object data if object was changed, required later for SAP export
    if($pendingActions.$sfId.requiresSync){
        if($pendingActions.$sfId.actionType -eq "update"){
            $pendingActions.$sfId.actionCompleted = $True
        }
        try{
            $filter = "($sapIdAdProperty -eq `"$($sfId)`" -and objectClass -eq `"User`" -and objectCategory -eq `"Person`")"
            $adUser = get-AdUserByFilter -filter $filter
            $pendingActions.$sfId.existsInAd = $True
            $pendingActions.$sfId.adObject = $adUser
            write-output "user ad object re-cached"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User could not be found by SF ID anymore after user was updated, this could mean the user has been moved/deleted in the mean time. Please investigate" -sourceRow $rowToString -error   
        }
    }else{
        Write-Output "No actions taken in local AD"
    }           
}

#Wait for sync to Office 365 if any users were actually added
Write-Output "Waiting 1 hour for Okta/AADConnect sync..."
if(!$readOnly -and ($pendingActions.Keys | Where-Object {$pendingActions.$_.requiresSync}).Count -gt 0){
    Start-Sleep -Seconds 3500
}

Write-Output "Reconnecting to Exchange Online to prevent issues with stale sessions"
buildResilientExchangeOnlineSession -o365Creds $mailServerCreds -commandPrefix o365
Connect-MsolService -Credential $mailServerCreds -erroraction Stop
Write-Output "Users should have been synced now, processing pending actions"

foreach($sfId in $pendingActions.Keys){
    if($pendingActions.$sfId.actionCompleted -eq $False -and $pendingActions.$sfId.actionType -ne "update"){
        add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "No actions taken in O365 because of an earlier issue during local AD account creation, reactivation or deactivation" -error   
        continue 
    }

    if($pendingActions.$sfId.actionType -eq $Null){
        add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "No actions taken in O365 because we could not determine what type of action to take for this CSV row" -error   
        continue 
    }

    if($pendingActions.$sfId.actionType -eq "deactivate"){
        add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "No actions taken in O365 because this account was disabled"   
        continue 
    }

    $changedInO365 = $false
    try{
        Write-Output "Searching for $($pendingActions.$sfId.email) in Office 365..."
        $userRes = Get-MsolUser -UserPrincipalName $pendingActions.$sfId.email -ErrorAction Stop
        Write-Output "User $($pendingActions.$sfId.email) found in Office 365"
        if(!$userRes) {Throw}
        $pendingActions.$sfId.existsInO365 = $True
    }catch{
        add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "User was not synced to Office 365 within the alloted time of 60 minutes, group and license assignments were not processed" -error
    }

    if($pendingActions.$sfId.existsInO365){
        #For reactivated users, ensure the is no receive restriction on the mailbox
        if($pendingActions.$sfId.actionType -eq "activate"){
            try{
                if(!$readOnly){
                    $Null = set-o365MailBox -Identity $pendingActions.$sfId.email -AcceptMessagesOnlyFrom $Null -Confirm:$False -ErrorAction Stop
                }
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Removed incoming mail restriction from existing mailbox"
            }catch{$Null} #most users don't have this restriction as it was only set in the past, so errors will happen often and don't have to be logged.
        }

        #Process group mutations
        foreach($groupName in $pendingActions.$sfId.office365Groups.Keys){
            #skip this group if it is a onetime group (value 2) and user is not being created/reactivated
            if($pendingActions.$sfId.office365Groups.$groupName -eq 2 -and ($pendingActions.$sfId.actionType -eq "deactivate" -or $pendingActions.$sfId.actionType -eq "update")){
                Continue 
            }
            $isMember = $False
            $groupType = "unknown"
            #check if the user is a member and the group exists
            try{
                $groupRes = Get-MsolGroup -SearchString $groupName -MaxResults 1 -ErrorAction Stop
                if($groupRes){
                    if($groupRes.GroupType.ToString().StartsWith("Mail") -or $groupRes.GroupType.ToString().StartsWith("Distribution")){
                        $groupType = "mail"
                    }else{
                        $groupType = "msol"
                    }
                    if(@(Get-MsolGroupMember -GroupObjectId $groupRes.ObjectId -All -ErrorAction SilentlyContinue | where {$_.EmailAddress -eq $pendingActions.$sfId.email}).Count -gt 0){
                        $isMember = $True
                    }
                }
            }catch{
                add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Could not process group assignments for $groupName" -error
                Continue
            }

            #process user removals
            if($pendingActions.$sfId.office365Groups.$groupName -eq 0 -and $isMember){
                if($groupType -eq "mail"){    
                    try{
                        Write-Output "Attempting to remove $($userRes.displayName) from $groupName"
                        $groupRes = Get-o365DistributionGroup -Identity $groupName -ResultSize 1 -ErrorAction Stop
                        if(!$readOnly){
                            Remove-o365DistributionGroupMember -Identity $groupRes.Identity -Member $($pendingActions.$sfId.email) -Confirm:$False -BypassSecurityGroupManagerCheck:$True -ErrorAction Stop
                        }
                        $changedInO365=$True
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Removed from distribution group $groupName"
                    }catch{
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Failed to remove user from $groupName" -error
                        Continue
                    }
                }
                if($groupType -eq "msol"){
                     try{
                        if(!$readOnly){
                            Remove-MsolGroupMember -GroupObjectId $groupRes.objectId -GroupMemberType User -GroupMemberObjectId $userRes.objectId -ErrorAction Stop
                        }
                        $changedInO365=$True
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Removed from msol group $groupName"
                     }catch{
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Failed to remove user from $groupName" -error
                        Continue
                    }
                }
            }elseif($pendingActions.$sfId.office365Groups.$groupName -gt 0 -and $isMember -eq $False){
                #process group adds
                if($groupType -eq "mail"){
                     try{
                        Write-Output "Attempting to make $($userRes.displayName) a member of $groupName"
                        $groupRes = Get-o365DistributionGroup -Identity $groupName -ResultSize 1 -ErrorAction Stop
                        if(!$readOnly){
                            Add-o365DistributionGroupMember -Identity $groupRes.Identity -Member $($pendingActions.$sfId.email) -Confirm:$False -BypassSecurityGroupManagerCheck:$True -ErrorAction Stop
                        }
                        $changedInO365=$True
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Added to distribution group $groupName"
                    }catch{
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Failed to add user to $groupName" -error
                        Continue
                    }
                }
                if($groupType -eq "msol"){
                     try{
                        if(!$readOnly){
                            Add-MsolGroupMember -GroupObjectId $groupRes.objectId -GroupMemberType User -GroupMemberObjectId $userRes.objectId -ErrorAction Stop
                        }
                        $changedInO365=$True
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Added to msol group $groupName"
                     }catch{
                        add-HTMLLogEntry -userID $sfId -displayName $userRes.displayName -logText "Failed to add user to $groupName" -error
                    }
                }
            }
        }

        if(!$changedInO365){
            Write-Output "No actions taken in O365"
        }

        #send Welcome Pack
        Write-Output "Sending welcome pack to $($pendingActions.$sfId.email)"
        try{
            if(!$readOnly){
                $Null = Send-MailMessage -BodyAsHtml $userMailTemplate.Replace("%USERDISPLAYNAME%",$userRes.DisplayName) -From $MailFrom -SmtpServer $MailServer -UseSsl:$MailUseSSL -Port $MailServerPort -Subject "Welcome to XXXX" -To $($pendingActions.$sfId.email) -Credential $mailServerCreds -Attachments $nldWelcomePackPDF -ErrorAction Stop
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Emailed Welcome Pack"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.displayName -logText "Failed to email welcome pack to user" -error
        }

        #send email to manager
        if(($pendingActions.$sfId.actionType -eq "create" -or $pendingActions.$sfId.actionType -eq "activate") -and $pendingActions.$sfId.actionCompleted){
            if($pendingActions.$sfId.ManagerEmail -match ".+\@.+\..+"){
                $targetMail = $pendingActions.$sfId.managerEmail
                $subText = "manager: "
            }else{
                $targetMail = $MailTo
                $subText = "ALTERNATE ADDRESS: because manager of this user is unknown"
            }
            if($pendingActions.$sfId.actionType -eq "create"){
                $subject = "New user account created"
                $reportText = "Sent new account email to $subText $targetMail"
            }else{
                $subject = "User account activated"
                $reportText = "Sent account reactivation email to $subText $targetMail"
            }
        
            try{
                if(!$readOnly){
                    foreach($addressee in $MailTo.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)){
                        $Null = Send-MailMessage -BodyAsHtml $managerMailTemplate.Replace("%USERDISPLAYNAME%",$pendingActions.$sfId.displayName).Replace("%USERLOGIN%",$($pendingActions.$sfId.email)).Replace("%USERPASSWORD%",$pendingActions.$sfId.password) -From $MailFrom -SmtpServer $MailServer -UseSsl -Port $MailServerPort -Subject $subject -To $addressee -Credential $mailServerCreds -ErrorAction Stop
                    }
                }
                if($pendingActions.$sfId.ManagerEmail -match ".+\@.+\..+"){
                    add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "$reportText"
                }else{
                    add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "$reportText" -error
                }
            }catch{
                add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Failed to send account info email to $($pendingActions.$sfId.managerEmail)" -error
            }
        }
    }
}

##send commands to ServiceNOW for created and reactivated users
foreach($sfId in ($pendingActions.Keys | Where-Object {($pendingActions.$_.actionType -eq "create" -or $pendingActions.$_.actionType -eq "deactivate") -and $pendingActions.$_.actionCompleted})){
    if($pendingActions.$sfId.actionType -eq "create"){
        #Send new equipment request to Servicenow
        try{
            if(!$readOnly){
                $Null = Send-MailMessage -Subject "[Provide IT equipment] - [IT] - [$($pendingActions.$sfId.countryName)]" -BodyAsHtml "request_type:Provide IT equipment<br>task_type:IT<br>country:$($pendingActions.$sfId.countryName)<br><br>Please provide IT equipment to $($pendingActions.$sfId.displayName)" -From $MailFrom -SmtpServer $MailServer -UseSsl -Port $MailServerPort -To $serviceNOWEmailAddress -Credential $mailServerCreds -ErrorAction Stop
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Sent request to ServiceNOW for IT equipment"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Failed to send request to ServiceNOW for IT equipment" -error
        }     
        #Send provide building access request to Servicenow  
        try{
            if(!$readOnly){
                $Null = Send-MailMessage -Subject "[Provide building access] - [Facilities] - [$($pendingActions.$sfId.countryName)]" -BodyAsHtml "request_type:Provide building access<br>task_type:Facilities<br>country:$($pendingActions.$sfId.countryName)<br><br>Please provide building access to $($pendingActions.$sfId.displayName)" -From $MailFrom -SmtpServer $MailServer -UseSsl -Port $MailServerPort -To $serviceNOWEmailAddress -Credential $mailServerCreds -ErrorAction Stop
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Send request to ServiceNOW for building access"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Failed to send request to ServiceNOW for building access" -error
        }   
    }
    if($pendingActions.$sfId.actionType -eq "deactivate"){
        #Send revoke equipment request to Servicenow
        try{
            if(!$readOnly){
                $Null = Send-MailMessage -Subject "[Revoke IT equipment] - [IT] - [$($pendingActions.$sfId.countryName)]" -BodyAsHtml "request_type:Revoke IT equipment<br>task_type:IT<br>country:$($pendingActions.$sfId.countryName)<br><br>Please revoke IT equipment from $($pendingActions.$sfId.displayName)" -From $MailFrom -SmtpServer $MailServer -UseSsl -Port $MailServerPort -To $serviceNOWEmailAddress -Credential $mailServerCreds -ErrorAction Stop
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Send request to ServiceNOW to revoke IT equipment"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Failed to send request to ServiceNOW to revoke IT equipment" -error
        }        
        #Send revoke building access request to Servicenow
        try{
            if(!$readOnly){
                $Null = Send-MailMessage -Subject "[Revoke building access] - [Facilities] - [$($pendingActions.$sfId.countryName)]" -BodyAsHtml "request_type:Revoke building access<br>task_type:Facilities<br>country:$($pendingActions.$sfId.countryName)<br><br>Please revoke building access from $($pendingActions.$sfId.displayName)" -From $MailFrom -SmtpServer $MailServer -UseSsl -Port $MailServerPort -To $serviceNOWEmailAddress -Credential $mailServerCreds -ErrorAction Stop
            }
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Send request to ServiceNOW to revoke building access"
        }catch{
            add-HTMLLogEntry -userID $sfId -displayName $pendingActions.$sfId.email -logText "Failed to send request to ServiceNOW to revoke building access" -error
        } 
    }
}

$htmlContent += "<br><br>Users processed:<br><table border=`"1`"><tr><td><b>CSV Identifier</b></td><td><b>AD Name</b></td><td><b>Status</b></td><td><b>Details</b></td></tr>"
$global:emailLog = $global:emailLog | sort-object -Property @{"Expression"={$_.id}},@{"Expression"={[Int]$_.index}}
foreach($entry in $global:emailLog){
    $htmlContent += "<tr><td>$($entry.id)</td><td>$($entry.name)</td><td><font color=`"$($entry.color)`">$($entry.category)</font></td><td>$($entry.text)</td></tr>"
}
$htmlContent += "</table>"

$htmlContent += "<br><br>Processing time: $((New-TimeSpan -start $startDateTime).ToString())<br><br>End of report</body></html>"

#send END OF SCRIPT report to mail recipients
Write-Output "Mailserver specified, preparing report for $MailTo"
foreach($addressee in $MailTo.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)){
    try{
        $Null = Send-MailMessage -BodyAsHtml $htmlContent -From $MailServerUsername -SmtpServer $MailServer -UseSsl:$MailUseSSL -Port $MailServerPort -Subject "SF AD Integration Run Report (PRD)" -To $addressee -Credential $mailServerCreds -ErrorAction Stop
        Write-Output "Report sent to $addressee"
    }catch{
        Write-Error "Error sending report to $addressee" -ErrorAction Continue
        Write-Error $_ -ErrorAction Continue
    }
}

Write-Output "Script finished, csv and log files will be moved to the Archive folder"

Stop-Transcript

Start-Sleep -s 1

#move all log / csv files to the archive folder
Move-Item -Path $logFile -Destination (Join-Path -Path $archivePath -ChildPath "$(Get-Date -format "dd-MM-yyyy-HH-mm")sync-SuccessFactorsToAD.log") -Force