<#
.DESCRIPTION
Sets required registry key to allow reuse of a hostname during AADJoin

.NOTES
author:         Jos Lieben (JSolve B.V.)
created:        22/11/2022
#>

Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\LSA" -Name "NetJoinLegacyAccountReuse" -Value 1 -Force     
