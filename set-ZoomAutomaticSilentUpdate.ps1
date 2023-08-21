if(!(Test-Path -Path "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings\General")){
    New-Item -Path "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings\General" -force
}
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings\General" -Name "EnableClientAutoUpdate" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings\General" -Name "EnableSilentAutoUpdate" -Value 1 -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Zoom\Zoom Meetings\General" -Name "AlwaysCheckLatestVersion" -Value 1 -Force