#Author:           Jos Lieben (OGD)
#Author Company:   OGD (http://www.ogd.nl)
#Author Blog:      http://www.lieben.nu
#Date:             05-06-2018
#Purpose:          Configurable drivemapping to server shares with automatic querying for credentials

#REQUIRED CONFIGURATION
$driveLetter = "I" #change to desired driveletter (don't use double colon : )
$path = '\\nlfs01\Afdelingen' #change to desired server / share path
$shortCutTitle = "I-Drive" #this will be the name of the shortcut
$autosuggestLogin = $True #automatically prefills the login field of the auth popup with the user's O365 email (azure ad join)
$desiredShortcutLocation = [Environment]::GetFolderPath("Desktop") #you can also use MyDocuments or any other valid input for the GetFolderPath function

###START SCRIPT

$desiredMapScriptFolder = Join-Path $Env:LOCALAPPDATA -ChildPath "Lieben.nu"
$desiredMapScriptPath = Join-Path $desiredMapScriptFolder -ChildPath "SMBdriveMapper.ps1"

if(![System.IO.Directory]::($desiredMapScriptFolder)){
    New-Item -Path $desiredMapScriptFolder -Type Directory -Force
}

$scriptContent = "
Param(
    `$driveLetter,
    `$sourcePath
)

`$driveLetter = `$driveLetter.SubString(0,1)

`$desiredMapScriptFolder = Join-Path `$Env:LOCALAPPDATA -ChildPath `"Lieben.nu`"

Start-Transcript -Path (Join-Path `$desiredMapScriptFolder -ChildPath `"SMBdriveMapper.log`") -Force
"
if($autosuggestLogin){
    $scriptContent+= "
try{
    `$objUser = New-Object System.Security.Principal.NTAccount(`$Env:USERNAME)
    `$strSID = (`$objUser.Translate([System.Security.Principal.SecurityIdentifier])).Value
    `$basePath = `"HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\`$strSID\IdentityCache\`$strSID`"
    if((test-path `$basePath) -eq `$False){
        `$userId = `$Null
    }
    `$userId = (Get-ItemProperty -Path `$basePath -Name UserName).UserName
    Write-Output `"Detected user id: `$userId`"
}catch{
    Write-Output `"Failed to auto detect user id, will query`" 
    `$Null
}
"
}else{
    $scriptContent+= "
`$userId = `$null
    "
}

$scriptContent+= "
`$serverPath = `"`$(([URI]`$sourcePath).Host)`"
#check if other mappings share the same path, in that case we shouldn't need credentials
`$authRequired = `$true
try{
     `$count = @(get-psdrive -PSProvider filesystem | where-object {`$_.DisplayRoot -and `$_.DisplayRoot.Replace('\','').StartsWith(`$serverPath)}).Count
}catch{`$Null}

if(`$count -gt 0){
    Write-Output `"A drivemapping to this server already exists, so authentication should not be required`"
    `$authRequired = `$False
}

[void] [System.Reflection.Assembly]::LoadWithPartialName(`"System.Drawing`") 
[void] [System.Reflection.Assembly]::LoadWithPartialName(`"System.Windows.Forms`")

if(`$authRequired){
    `$form = New-Object System.Windows.Forms.Form
    `$form.Text = `"Connect to `$driveLetter drive`"
    `$form.Size = New-Object System.Drawing.Size(300,200)
    `$form.StartPosition = 'CenterScreen'
    `$form.MinimizeBox = `$False
    `$form.MaximizeBox = `$False

    `$OKButton = New-Object System.Windows.Forms.Button
    `$OKButton.Location = New-Object System.Drawing.Point(75,120)
    `$OKButton.Size = New-Object System.Drawing.Size(75,23)
    `$OKButton.Text = 'OK'
    `$OKButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    `$form.AcceptButton = `$OKButton
    `$form.Controls.Add(`$OKButton)

    `$CancelButton = New-Object System.Windows.Forms.Button
    `$CancelButton.Location = New-Object System.Drawing.Point(150,120)
    `$CancelButton.Size = New-Object System.Drawing.Size(75,23)
    `$CancelButton.Text = 'Cancel'
    `$CancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    `$form.CancelButton = `$CancelButton
    `$form.Controls.Add(`$CancelButton)

    `$label = New-Object System.Windows.Forms.Label
    `$label.Location = New-Object System.Drawing.Point(10,20)
    `$label.Size = New-Object System.Drawing.Size(280,20)
    `$label.Text = `"Username for `$driveLetter drive`"
    `$form.Controls.Add(`$label)

    `$textBox = New-Object System.Windows.Forms.TextBox
    `$textBox.Location = New-Object System.Drawing.Point(10,40)
    `$textBox.Size = New-Object System.Drawing.Size(260,20)
    `$textBox.Text = `$userId
    `$form.Controls.Add(`$textBox)

    `$label2 = New-Object System.Windows.Forms.Label
    `$label2.Location = New-Object System.Drawing.Point(10,60)
    `$label2.Size = New-Object System.Drawing.Size(280,20)
    `$label2.Text = 'Password:'
    `$form.Controls.Add(`$label2)

    `$textBox2 = New-Object System.Windows.Forms.MaskedTextBox
    `$textBox2.PasswordChar = '*'
    `$textBox2.Location = New-Object System.Drawing.Point(10,80)
    `$textBox2.Size = New-Object System.Drawing.Size(260,20)
    `$form.Controls.Add(`$textBox2)

    `$form.Topmost = `$true

    `$form.Add_Shown({`$textBox.Select()})
    `$result = `$form.ShowDialog()

    if (`$result -eq [System.Windows.Forms.DialogResult]::OK -and `$textBox2.Text.Length -gt 5 -and `$textBox.Text.Length -gt 4)
    {
        `$secpasswd = ConvertTo-SecureString `$textBox2.Text -AsPlainText -Force
        `$credentials = New-Object System.Management.Automation.PSCredential (`$textBox.Text, `$secpasswd)
    }else{
        `$OUTPUT= [System.Windows.Forms.MessageBox]::Show(`"`$driveLetter will not be available, as you did not enter credentials`", `"`$driveLetter error`" , 0) 
        Stop-Transcript
        Exit
    }
}
try{`Remove-PSDrive -Name `$driveLetter -Force}catch{`$Null}

try{
    if(`$authRequired){
        New-PSDrive -Name `$driveLetter -PSProvider FileSystem -Root `$sourcePath -Credential `$credentials -Persist -ErrorAction Stop
    }else{
        Throw
    }
}catch{
    try{
        New-PSDrive -Name `$driveLetter -PSProvider FileSystem -Root `$sourcePath -Persist -ErrorAction Stop
    }catch{
         `$OUTPUT= [System.Windows.Forms.MessageBox]::Show(`"Connection failed, technical reason: `$(`$Error[0])`", `"`$driveLetter error`" , 0) 
    }
}
Stop-Transcript
"

$scriptContent | Out-File $desiredMapScriptPath -Force

$driveLetter = $driveLetter.SubString(0,1)
$WshShell = New-Object -comObject WScript.Shell
$Shortcut = $WshShell.CreateShortcut((Join-Path $desiredShortcutLocation -ChildPath "$($shortCutTitle).lnk"))
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.WorkingDirectory = "%SystemRoot%\WindowsPowerShell\v1.0\"
$Shortcut.Arguments =  "-WindowStyle Hidden -ExecutionPolicy ByPass -File `"$desiredMapScriptPath`" $driveLetter `"$path`""
$Shortcut.IconLocation = "explorer.exe ,0"
$shortcut.WindowStyle = 7
$Shortcut.Save()