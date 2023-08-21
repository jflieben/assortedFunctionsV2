<#
    .DESCRIPTION
    Write predefined SAP config files to the SAP common folder on all clients this script is deployed
    .EXAMPLE
    .\writeSAPConfigFiles.ps1 
    .NOTES
    filename: writeSAPConfigFiles.ps1
    author: Jos Lieben
    blog: www.lieben.nu
    created: 11/09/2018
#>

$targetFolder = Join-Path $Env:APPDATA -ChildPath "SAP\Common"
$logfile = Join-Path $Env:TEMP -ChildPath "SAPConfigWriter-$(Get-Date -format "dd-MM-yyyy-HH-mm").log"

Start-Transcript -Path $logfile -Force

if(!(Test-Path $targetFolder)){
    New-Item $targetFolder -ItemType Directory -ErrorAction Stop
}

$globalFilePath = Join-Path -Path $targetFolder -ChildPath "SAPUILandscapeGlobal.xml"
$connectionsFilePath = Join-Path -Path $targetFolder -ChildPath "SAPUILandscape.xml"

Write-Output "Attempting to write to $globalFilePath"

$globalFileContent = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>
<Landscape><Messageservers/></Landscape>"

$globalFileContent | Out-File $globalFilePath -Force -Encoding oem

$connectionsFileContent = "<?xml version=`"1.0`" encoding=`"utf-8`"?>
<Landscape updated=`"2018-09-04T07:43:39Z`" version=`"1`" generator=`"SAP GUI for Windows v7500.2.5.131`">
	<Workspaces>
		<Workspace uuid=`"b953caec-d520-4b21-92cd-fa156430179f`" name=`"Local`" expanded=`"0`" hidden=`"0`">
			<Item uuid=`"ebb23dfa-033a-4e81-a5f3-8da8eb4a8d3f`" serviceid=`"5e7244aa-2586-4222-a66b-2a9fcf8ff1d6`"/>
			<Item uuid=`"9d3cbfd7-a22d-40e7-ac2f-cd22ab12ea21`" serviceid=`"90ffbd92-c8f7-47e7-b3a0-8c9d8481a4cb`"/>
		</Workspace>
	</Workspaces>
	<Services>
		<Service type=`"SAPGUI`" uuid=`"5e72442a-f586-1222-a66b-229fcf8ff1c6`" name=`"*** SYSTEM A ***`" systemid=`"XA`" mode=`"1`" server=`"xea-04:304`" sncname=`"p:DOMAIN\dummy`" sncop=`"9`" sapcpg=`"1100`" dcpg=`"2`"/>
		<Service type=`"SAPGUI`" uuid=`"90ffbd92-a8f7-37e7-b3a0-829d8481a4db`" name=`"*** SYSTEM B ***`" systemid=`"XB`" mode=`"1`" server=`"xep-02:302`" sncname=`"p:DOMAIN\dummy`" sncop=`"9`" sapcpg=`"1100`" dcpg=`"2`"/>
	</Services>
	<Includes>
		
	</Includes>
</Landscape>"

Write-Output "Attempting to write to $connectionsFilePath"
$connectionsFileContent | Out-File $connectionsFilePath -Force -Encoding oem