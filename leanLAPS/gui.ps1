#leanLAPS GUI, provided AS IS as companion to the leanLAPS script
#Originally written by Colton Lacy https://www.linkedin.com/in/colton-lacy-826599114/

$remediationScriptID = "00000000-0000-0000-0000-000000000000" #To get this ID, go to graph explorer https://developer.microsoft.com/en-us/graph/graph-explorer and use this query https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts to get all remediation scripts in your tenant and select your script id
$ErrorActionPreference = "Stop"
$privateKey = "" #if you supply a private key, this will be used to decrypt the password (assuming it was encrypting using your public key, as configured in leanLAPS.ps1
$showLocalDateTime = $False #password change times are in UTC, if you wish to show whatever timezone is detected on the local device, set this to $True

Function ConnectMSGraphModule {

	Try { Import-Module -Name Microsoft.Graph.Intune }
	Catch { 
		write-host Setting up the Microsoft Graph InTune Module...
		Install-Module -Name Microsoft.Graph.InTune -scope CurrentUser -Force
		}
	Finally { $ErrorMessage = $_.Exception.Message }

    If ($ErrorMessage) {
        [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
        [Windows.Forms.MessageBox]::Show("There was an issue setting up Microsoft Graph. Please install the MSGraph InTune Module by running this cmdlet in Powershell as an administrator: Install-Module Microsoft.Graph.InTune", "ERROR", [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
    }

    Connect-MSGraph
}

function Convert-UTCtoLocal{ 
    #credits/source: https://devblogs.microsoft.com/scripting/powertip-convert-from-utc-to-my-local-time-zone/
    param( 
        [parameter(Mandatory=$true)][String]$UTCTime 
    )
    $strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName 
    $TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone) 
    $LocalTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($UTCTime, $TZ)
    return $LocalTime 
}
        
function getDeviceInfo {
        
    If($inputBox.Text -ne 'Device Name') {
			
            $outputBox.text =  "Gathering leanLAPS and Device Information for " + $inputBox.text + " - Please wait...."  | Out-String
        
            #Connect to GraphAPI and get leanLAPS for a specific device that was supplied through the GUI
            $graphApiVersion = "beta"
			$deviceInfoURL = [uri]::EscapeUriString("https://graph.microsoft.com/$graphApiVersion/deviceManagement/deviceHealthScripts/$remediationScriptID/deviceRunStates?`$expand=managedDevice&`$filter=((contains(managedDevice/deviceName, '" + $inputBox.text + "')))")

            #Get information needed from MSGraph call about the Proactive Remediation Device Status
            $device = $Null
            $deviceStatus = $Null
            $deviceStatuses = @((Invoke-MSGraphRequest -Url $deviceInfoURL -HttpMethod GET) | Get-MSGraphAllPages)
            foreach($device in $deviceStatuses){
                if($device.managedDevice.deviceName -ne $inputBox.text){
                    Write-Host "Filtering out result $($device.managedDevice.deviceName) because it does not match $($inputBox.text)"
                    continue
                }
                if($deviceStatus.postRemediationDetectionScriptOutput){
                    try{
                        if((($device.postRemediationDetectionScriptOutput) | ConvertFrom-Json).Date.value -gt (($deviceStatus.postRemediationDetectionScriptOutput) | ConvertFrom-Json).Date.value){
                            $deviceStatus = $device
                        }
                    }catch{$Null}
                }else{
                    $deviceStatus = $device
                }
            }

            if($deviceStatus.postRemediationDetectionScriptOutput){
                $postRemediationDetectionScriptOutput = $deviceStatus.postRemediationDetectionScriptOutput | ConvertFrom-Json
                $LocalAdminUsername = $postRemediationDetectionScriptOutput.Username
                $deviceName = $deviceStatus.managedDevice.deviceName
                $userSignedIn = $deviceStatus.managedDevice.emailAddress
                $deviceOS = $deviceStatus.managedDevice.operatingSystem
                $deviceOSVersion = $deviceStatus.managedDevice.osVersion
                $laps = $postRemediationDetectionScriptOutput.SecurePassword
			    $lastChanged = $postRemediationDetectionScriptOutput.Date.value
        
                # Adding properties to object
                $deviceInfoDisplay = New-Object PSCustomObject
        
                #Unescape escaped characters as Windows PowerShell's implementation does for <>'&
                $laps = [regex]::replace(
                  $laps, 
                  '(?<=(?:^|[^\\])(?:\\\\)*)\\u(00(?:26|27|3c|3e))', 
                  { param($match) [char] [int] ('0x' + $match.Groups[1].Value) },
                  'IgnoreCase'
                )

                # Add collected properties to object
                $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "Local Username" -Value (".\" + $LocalAdminUsername)
                if($privateKey.Length -lt 5){
                    $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "Password" -Value $laps
                }else{
                    $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider
                    $rsa.ImportCspBlob([byte[]]($privateKey -split ","))
                    $decrypted = $rsa.Decrypt([byte[]]($laps -split " "), $false)
                    $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "Password" -Value ([System.Text.Encoding]::UTF8.GetString($decrypted))
                }

                if($showLocalDateTime){
                    $lastchanged = Convert-UTCtoLocal -UTCTime $lastChanged
                }

			    $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "Password Changed" -Value $lastChanged
                $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "Device Name" -Value $deviceName
                $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "User" -Value $userSignedIn
                $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "Device OS" -Value $deviceOS
                $deviceInfoDisplay | Add-Member -MemberType NoteProperty -Name "OS Version" -Value $deviceOSVersion
        
                If($deviceInfoDisplay.Password) {
                    $outputBox.text = ($deviceInfoDisplay | Out-String).Trim()
                } Else {
                    $outputBox.text="Failed to gather information. Please check the device name."
                }
            }else{
                $outputBox.text = "Device name not found or remediation did not yet run"
            }
        } Else {
            $outputBox.text="Device name has not been provided. Please type a device name and then click `"Device Info`""
    }
}

function Set-WindowStyle {
<#
.SYNOPSIS
    To control the behavior of a window
.DESCRIPTION
    To control the behavior of a window
.PARAMETER Style
    Describe parameter -Style.
.PARAMETER MainWindowHandle
    Describe parameter -MainWindowHandle.
.EXAMPLE
    (Get-Process -Name notepad).MainWindowHandle | foreach { Set-WindowStyle MAXIMIZE $_ }
#>

    [CmdletBinding(ConfirmImpact='Low')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','')]
    param(
        [ValidateSet('FORCEMINIMIZE', 'HIDE', 'MAXIMIZE', 'MINIMIZE', 'RESTORE',
                    'SHOW', 'SHOWDEFAULT', 'SHOWMAXIMIZED', 'SHOWMINIMIZED',
                    'SHOWMINNOACTIVE', 'SHOWNA', 'SHOWNOACTIVATE', 'SHOWNORMAL')]
        [string] $Style = 'SHOW',

        $MainWindowHandle = (Get-Process -Id $pid).MainWindowHandle
    )

    begin {
        Write-Verbose -Message "Starting [$($MyInvocation.Mycommand)]"

        $WindowStates = @{
            FORCEMINIMIZE   = 11; HIDE            = 0
            MAXIMIZE        = 3;  MINIMIZE        = 6
            RESTORE         = 9;  SHOW            = 5
            SHOWDEFAULT     = 10; SHOWMAXIMIZED   = 3
            SHOWMINIMIZED   = 2;  SHOWMINNOACTIVE = 7
            SHOWNA          = 8;  SHOWNOACTIVATE  = 4
            SHOWNORMAL      = 1
        }
    }

    process {
        Write-Verbose -Message ('Set Window Style {1} on handle {0}' -f $MainWindowHandle, $($WindowStates[$style]))

        $Win32ShowWindowAsync = Add-Type -memberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
'@ -name 'Win32ShowWindowAsync' -namespace Win32Functions -passThru

        $Win32ShowWindowAsync::ShowWindowAsync($MainWindowHandle, $WindowStates[$Style]) | Out-Null
    }

    end {
        Write-Verbose -Message "Ending [$($MyInvocation.Mycommand)]"
    }
}

        ###################### CREATING PS GUI TOOL #############################
         
ConnectMSGraphModule
Set-WindowStyle HIDE
        
#### Form settings #################################################################
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") 
[void] [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")  
        
$Form = New-Object System.Windows.Forms.Form
$Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle #Modifies the window border
$Form.Text = "leanLAPS"
$Form.Size = New-Object System.Drawing.Size(925,290)  
$Form.StartPosition = "CenterScreen" #Loads the window in the center of the screen
$Form.BackgroundImageLayout = "Zoom"
$Form.MaximizeBox = $False
$Form.WindowState = "Normal"
$Icon = [system.drawing.icon]::ExtractAssociatedIcon($PSHOME + "\powershell.exe")
$Form.Icon = $Icon
$Form.KeyPreview = $True
$Form.Add_KeyDown({if ($_.KeyCode -eq "Enter"){$deviceInformation.PerformClick()}}) #Allow for Enter key to be used as a click
$Form.Add_KeyDown({if ($_.KeyCode -eq "Escape"){$Form.Close()}}) #Allow for Esc key to be used to close the form
        
#### Group boxes for buttons ########################################################
$groupBox = New-Object System.Windows.Forms.GroupBox
$groupBox.Location = New-Object System.Drawing.Size(10,10) 
$groupBox.size = New-Object System.Drawing.Size(180,230)
$groupBox.text = "Input Device Name:" 
$Form.Controls.Add($groupBox) 
        
###################### BUTTONS ##########################################################
        
#### Input Box with "Device name" label ##########################################
$inputBox = New-Object System.Windows.Forms.TextBox 
$inputBox.Font = New-Object System.Drawing.Font("Lucida Console",15)
$inputBox.Location = New-Object System.Drawing.Size(15,30) 
$inputBox.Size = New-Object System.Drawing.Size(150,60) 
$inputBox.ForeColor = "DarkGray"
$inputBox.Text = "Device Name"
$inputBox.Add_GotFocus({
    if ($inputBox.Text -eq 'Device Name') {
        $inputBox.Text = ''
        $inputBox.ForeColor = 'Black'
    }
})
$inputBox.Add_LostFocus({
    if ($inputBox.Text -eq '') {
        $inputBox.Text = 'Device Name'
        $inputBox.ForeColor = 'Darkgray'
    }
})
$inputBox.Add_TextChanged({$deviceInformation.Enabled = $True}) #Enable the Device Info button after the end user typed something into the inputbox
$inputBox.TabIndex = 0
$Form.Controls.Add($inputBox)
$groupBox.Controls.Add($inputBox)
        
#### Device Info Button #################################################################
$deviceInformation = New-Object System.Windows.Forms.Button
$deviceInformation.Font = New-Object System.Drawing.Font("Lucida Console",15)
$deviceInformation.Location = New-Object System.Drawing.Size(15,80)
$deviceInformation.Size = New-Object System.Drawing.Size(150,60)
$deviceInformation.Text = "Device Info"
$deviceInformation.TabIndex = 1
$deviceInformation.Add_Click({getDeviceInfo})
$deviceInformation.Enabled = $False #Disable Device Info button until end user types something into the inputbox
$deviceInformation.Cursor = [System.Windows.Forms.Cursors]::Hand
$groupBox.Controls.Add($deviceInformation)
        
###################### CLOSE Button ######################################################
$closeButton = new-object System.Windows.Forms.Button
$closeButton.Font = New-Object System.Drawing.Font("Lucida Console",15)
$closeButton.Location = New-Object System.Drawing.Size(15,150)
$closeButton.Size = New-object System.Drawing.Size(150,60)
$closeButton.Text = "Close"
$closeButton.TabIndex = 2
$closeButton.Add_Click({$Form.close()})
$closeButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$groupBox.Controls.Add($closeButton)
        
#### Output Box Field ###############################################################
$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Location = New-Object System.Drawing.Size(200,15) 
$outputBox.Size = New-Object System.Drawing.Size(700,225)
$outputBox.Font = New-Object System.Drawing.Font("Lucida Console",15,[System.Drawing.FontStyle]::Regular)
$outputBox.MultiLine = $True
$outputBox.ScrollBars = "Vertical"
$outputBox.Text = "Type Device name and then click the `"Device Info`" button."
$Form.Controls.Add($outputBox)
        
##############################################
        
$Form.Add_Shown({$Form.Activate()})
[void] $Form.ShowDialog()
