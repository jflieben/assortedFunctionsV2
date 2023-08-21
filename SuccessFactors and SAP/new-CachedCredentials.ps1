#Run this script once when configuring scripts that use credentials from the credential vault. Run it under the user that will run the scripts (scheduled, serviceaccount) set the correct credentials and path below. 
. CredMan.ps1

Start-Transcript log.txt

$CREDPREFIX = "LIEBEN_"

##ENTER CREDENTIALS (REMOVE AFTER RUNNING ONCE UNDER THE SRV ACCOUNT)
#Write-Creds -Target "$($CREDPREFIX)SF_FTP_PRD" -UserName "XXXX" -Password "XXXX"
#Write-Creds -Target "$($CREDPREFIX)O365" -UserName "XXXXX" -Password "XXXX"
#Write-Creds -Target "$($CREDPREFIX)OKTA" -UserName "none_required" -Password "XXX"

##UNCOMMENT FOR TEST, LOG WILL SHOW CREDENTIALS
Read-Creds -Target "$($CREDPREFIX)SF_FTP_PRD"
Read-Creds -Target "$($CREDPREFIX)O365"
Read-Creds -Target "$($CREDPREFIX)OKTA"


