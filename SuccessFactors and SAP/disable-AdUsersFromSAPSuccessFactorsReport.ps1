<#
    .SYNOPSIS
    disables Active Directory accounts of all AD users found in an SAP SuccessFactors CSV report from an sFTP server
    .DESCRIPTION
    SAP usually comes with an sFTP server, you can configure SAP SuccessFactors (in the PerformanceManager) to create CSV files with users whose contracts have been terminated. This script will fetch that CSV file and disable 
    those users for your in your Active Directory

    This script requires WRITE access to the folder it is placed in as it will archive all CSV files to an archive folder
    Run it on a Active Directory connected server with the Activedirectory powershell module installed. Also install the Posh-SSH module, or run elevated on Powershell V5 to auto-install.

    Everything is logged to the script's folder, and all actions are emailed if you configure the script's email settings.
    .EXAMPLE
    .\disable-AdUsersFromSAPSuccessFactorsReport.ps1 
    .PARAMETER sFTPLogin
    The login name to use for your sFTP server
    Example: USER
    .PARAMETER sFTPPassword
    Password for your sFTP server in plaintext
    Example: Welcome01
    .PARAMETER sFTPHost
    Hostname of your sFTP server, do not use folder paths or protocol names here! (ie: no slashes!)
    Example: prodftp2.successfactors.eu
    .PARAMETER sFTPFolderPath
    Optional parameter to supply a folder path in which your csv file reside, if not in the home folder of the user
    Example: /FEED/UPLOAD
    .PARAMETER sFTPFileName
    Filename of the csv report, if not specified, will use ALL files ending in .csv found in the folder path
    Example: userdelta.csv
    .PARAMETER csvColumnName
     CSV column to identity the user, this column should exist in the CSV file. The value is used to search your AD for this user.
    Example: "Email-User"
    .PARAMETER adAttributeName
    Name of the ad attribute to search by, e.g. if your CSV contains email addresses, set this to 'mail' to search AD for users with a mail attribute that matches the value in the CSV
    Example: "mail"
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
    .PARAMETER MailServerPort
    Mailserver port, if different from default of 25
    Example: 587
    .PARAMETER MailServerUsername
    If specified, will authenticate to mailserver using this username
    Example: jos.lieben@mail.com
    .PARAMETER MailServerPassword
    If specified together with MailServerUsername, will authenticate using this password
    Example: 523873221312
    .PARAMETER MailUseSSL
    Switch, if provided, mail connection will attempt to use SSL
    .PARAMETER readOnly
    Switch parameter, if specified, will only report but not actually disable any users and will not delete files from the ftp server
    .PARAMETER doNotWipeProcessedCsvFilesFromFTP
    if specified, will not wipe processed CSV files from the FTP server. Warning: this means the script may process the file each time it runs
    .PARAMETER writeNoteToDescriptionField
    if specified, will write to the AD description field that the user was disabled by this script
    .NOTES
    filename: disable-AdUsersFromSAPSuccessFactorsReport.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 04/09/2018
#>
Param(
    [Parameter(Mandatory=$true)][String]$sFTPLogin,
    [Parameter(Mandatory=$true)][String]$sFTPPassword,
    [Parameter(Mandatory=$true)][String]$sFTPHost,
    [String]$sFTPFolderPath,
    [String]$sFTPFileName,
    [String]$csvColumnName = "Email-User",
    [String]$adAttributeName = "mail",
    [String]$MailServer = "smtp.outlook.com",
    [String]$MailTo = "test@test.com",
    [String]$MailFrom = "info@mycompany.nl",
    [String]$MailServerPort = 25,
    [String]$MailServerUsername,
    [String]$MailServerPassword,
    [Switch]$MailUseSSL,
    [Switch]$readOnly,
    [Switch]$doNotWipeProcessedCsvFilesFromFTP,
    [Switch]$writeNoteToDescriptionField
)

$executionPath = [System.IO.Path]::GetDirectoryName($myInvocation.MyCommand.Definition)
$logFile = Join-Path $executionPath -ChildPath "disable-AdUsersFromSAPSfFTPSReport.log"
$archivePath = Join-Path $executionPath -ChildPath "Archive"
Start-Transcript -Path $logFile -Force

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
if ($SFTPModule -eq $null) {
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
if ($ADModule -eq $null) {
    write-Error "ActiveDirectory Powershell module not installed...please run this script on a machine that has the AD module installed!" -ErrorAction Stop
    Exit
}
Import-Module "ActiveDirectory" -DisableNameChecking

$sFTPCreds = New-Object System.Management.Automation.PSCredential ($sFTPLogin, (ConvertTo-SecureString $sFTPPassword -AsPlainText -Force))
    
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
    $sFTPContents = $sFTPContents | Where {$_.FullName.EndsWith($sFTPFileName)}
    Write-Output "$($sFTPContents.Count) files remaining"
}

if(!$sFTPContents){
    write-output "No CSV files were detected on the FTP server, script will exit"
    Exit
}

$htmlContent = "<html><head><title>FTP SAP CSV Processing Report</title></head><body>Hi,<br><br>The following CSV files were processed from $sFTPHost<br><table border=`"1`"><tr><td><b>File</b></td><td><b>Records</b></td><td><b>Deleted from FTP?</b></td></tr>"

$csvFiles = @()
foreach($csvFile in $sFTPContents){
    $fileName = "$(Get-Date -format "dd-MM-yyyy-HH-mm")$($csvFile.FullName.Split("/")[-1])"
    $tempFilePath = Join-Path $archivePath -ChildPath $csvFile.FullName.Split("/")[-1]
    $fileDeletedFromFtp = "NO"
    try{
        $recordCount = "ERROR"
        Write-Output "Downloading $($csvFile.FullName) to $tempFilePath..."
        Get-SFTPFile -SessionId $sFTPSession.SessionId -RemoteFile $csvFile.FullName -LocalPath $archivePath -NoProgress -Overwrite -Verbose
        Rename-Item -Path $tempFilePath -NewName $fileName -Force
        Write-Output "Download completed"
        $finalPath = Join-Path $archivePath -ChildPath $fileName
        $csvFiles += $finalPath
        try{
            $recordCount = (Import-CSV -Path $finalPath).Count
        }catch{$NULL}
        try{
            if(!$doNotWipeProcessedCsvFilesFromFTP){
                if(!$readOnly){Remove-SFTPItem -SessionId $sFTPSession.SessionId -Path $csvFile.FullName -Force}
            }else{
                Throw
            }
            Write-Output "File deleted from FTP server"
            $fileDeletedFromFtp = "YES"
        }catch{
            Write-Output "File not deleted from FTP server"
        }
    }catch{
        
        Write-Error "Failed to download csv file! Ignoring this file" -ErrorAction Continue
        Write-Error $_ -ErrorAction Continue
    }
    $htmlContent += "<tr><td>$($csvFile.FullName)</td><td>$recordCount</td><td>$fileDeletedFromFtp</td></tr>"
}

$htmlContent += "</table>"

$userReport = "Users processed:<br><table border=`"1`"><tr><td><b>CSV Identifier</b></td><td><b>AD Name</b></td><td><b>Status</b></td><td><b>Details</b></td></tr>"

if($csvFiles.Count -le 0){
    Write-Output "No files were downloaded, script cannot continue"
    Exit
}

Write-Output "Downloaded $($csvFiles.Count) file(s) to $archivePath"

foreach($csvFile in $csvFiles){
    Write-Output "Opening $csvFile for processing"
    try{
        $csvFileContents = $Null;$csvFileContents = Import-CSV -Path $csvFile -Verbose
    }catch{
        $htmlContent += "<b><font color=`"red`">Failed to process csv file $csvFile! Ignoring this file</font></b><br>"
        Write-Error "Failed to process csv file $csvFile! Ignoring this file" -ErrorAction Continue
        Write-Error $_ -ErrorAction Continue
        Continue
    }
    foreach($user in $csvFileContents){
        try{
            $rowToString = $((($user[0].psobject.Properties | where {$_.MemberType -eq "NoteProperty"  }).Value -Join ","))
        }catch{
            $rowToString = "Unknown"
        }
        if(!$user.$csvColumnName){
            $userReport += "<tr><td>$csvColumnName</td><td>Unknown</td><td><font color=`"red`">FAILED</font></td><td>The CSV file did not have a column named $($csvColumnName): $rowToString</td></tr>"
            Write-Error "Did not detect proper column $csvColumnName in CSV file for this row: $user" -ErrorAction Continue
            Continue
        }
        $filter = "($adAttributeName -eq `"$($user.$csvColumnName)`" -and objectClass -eq `"User`" -and objectCategory -eq `"Person`")"
        try{
            if($filter.Length -le 12){
                Throw "Invalid filter used in searching for ADObjects: $filter, aborting to prevent mass-selecting users"
            }
            Write-Verbose "Searching AD for users using filter $filter"
            $adUser = Get-ADObject -Filter $filter -ErrorAction Stop -Properties *
            if($adUser.Count -gt 1){
                Throw "Multiple users returned when searching by $filter, skipping this user"
            }
            if($adUser.Count -eq 0){
                $userReport += "<tr><td>$($user.$csvColumnName)</td><td>Unknown</td><td><font color=`"orange`">FAILED</font></td><td>Could not find a user in AD searching for a user with $adAttributeName = $($user.$csvColumnName). CSV content: $rowToString</td></tr>"
                Write-Output "Did not find a user in AD when searching using filter $filter"
                continue
            }
            Write-Output "$($adUser.Name) found in AD"
        }catch{
            $userReport += "<tr><td>$($user.$csvColumnName)</td><td>Unknown</td><td><font color=`"red`">FAILED</font></td><td>Could not find a user in AD because of an error: $($_.Exception), see log for details. CSV content: $rowToString</td></tr>"
            Write-Error "Failed to retrieve user, skipping" -ErrorAction Continue
            Write-Error $_ -ErrorAction Continue
            Continue
        }
        if($adUser.userAccountControl -band 2){
            $userReport += "<tr><td>$($user.$csvColumnName)</td><td>$($adUser.Name)</td><td><font color=`"green`">SUCCEEDED</font></td><td>User was already disabled</td></tr>"
            Write-Output "User already disabled"
        }else{
            Write-Output "User not yet disabled! Disabling user..."
            try{
                if(!$readOnly){
                    Disable-ADAccount -Identity $adUser.ObjectGUID -Confirm:$False -ErrorAction Stop
                    if($writeNoteToDescriptionField){
                        Set-ADObject -Identity $adUser.ObjectGUID -Description "User deactivated from SuccessFactors on $(Get-Date)"-Confirm:$False -ErrorAction Continue
                    }
                }
                $userReport += "<tr><td>$($user.$csvColumnName)</td><td>$($adUser.Name)</td><td><font color=`"green`">SUCCEEDED</font></td><td>User disabled</td></tr>"
                Write-Output "$($adUser.Name) disabled"
            }catch{
                $userReport += "<tr><td>$($user.$csvColumnName)</td><td>$($adUser.Name)</td><td><font color=`"red`">FAILED</font></td><td>User could not be disabled because of an error: $($_.Exception), see log for details</td></tr>"
                Write-Error "Failed to disable this user" -ErrorAction Continue
                Write-Error $_
                Continue
            }
        }
    }
}

$userReport += "</table>"

$htmlContent += $userReport

$htmlContent += "<br><br>End of report</body></html>"

#send report to mail recipients
if($MailServer -and $MailTo){
    Write-Output "Mailserver specified, preparing report for $MailTo"
    if($MailServerUsername){
        $mailServerCreds = New-Object System.Management.Automation.PSCredential ($MailServerUsername, (ConvertTo-SecureString $MailServerPassword -AsPlainText -Force))
    }
    foreach($addressee in $MailTo.Split(",",[System.StringSplitOptions]::RemoveEmptyEntries)){
        try{
            if($MailServerUsername){
                $res = Send-MailMessage -BodyAsHtml $htmlContent -From $MailFrom -SmtpServer $MailServer -UseSsl:$MailUseSSL -Port $MailServerPort -Subject "SAP SF AD Disabled Users Report" -To $addressee -Credential $mailServerCreds -ErrorAction Stop
            }else{
                $res = Send-MailMessage -BodyAsHtml $htmlContent -From $MailFrom -SmtpServer $MailServer -UseSsl:$MailUseSSL -Port $MailServerPort -Subject "SAP SF AD Disabled Users Report" -To $addressee -ErrorAction Stop
            }
            Write-Output "Report sent to $addressee"
        }catch{
            Write-Error "Error sending report to $addressee" -ErrorAction Continue
            Write-Error $_ -ErrorAction Continue
        }
    }
}

Stop-Transcript

Sleep -s 1

Move-Item -Path $logFile -Destination (Join-Path -Path $archivePath -ChildPath "$(Get-Date -format "dd-MM-yyyy-HH-mm")disable-AdUsersFromSAPSfFTPSReport.log") -Force