#Author: Jos Lieben
#https://www.lieben.nu
$path = "HKLM:\SOFTWARE\Policies\Microsoft"
$key = "PassportForWork"
 
New-Item -Path $path -Name $key –Force
 
New-ItemProperty -Path "$($path)\$($key)" -Name "Enabled" -Value 0 -PropertyType DWORD -Force