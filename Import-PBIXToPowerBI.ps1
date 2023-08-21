function Import-PBIXToPowerBI{
      <#
      .DESCRIPTION
      Imports your PowerBI PBIX file to PowerBI online
      .EXAMPLE
      Import-PBIXToPowerBI -localPath c:\temp\myReport.pbix -graphToken eysakdjaskuoeiuw9839284234 -wait
      .PARAMETER localPath
      The full path to your PBIX file
      .PARAMETER graphToken
      A graph token, you'll need to use a app+user token https://docs.microsoft.com/en-us/power-bi/developer/walkthrough-push-data-get-token
      .PARAMETER groupId
      Optional, if not supplied the report will be imported to the token's user's workspace, otherwise it'll be imported into the supplied group's workspace
      .PARAMETER reportName
      Optional, if not supplied the report will get the same name as the file
      PARAMETER importMode
      Optional, overwrites by default, see https://docs.microsoft.com/en-us/rest/api/power-bi/imports/postimportingroup#importconflicthandlermode for valid values
      PARAMETER wait
      Optional, if supplied waits for the import to succeed. Note: could lock your flow, there is no timeout
      .NOTES
      filename: Import-PBIXToPowerBI.ps1
      author: Jos Lieben
      blog: www.lieben.nu
      created: 23/4/2019
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]$localPath, #path to (unencrypted!) PBIX file
        [Parameter(Mandatory=$true)]$graphToken, #token for the PowerBI API: https://docs.microsoft.com/en-us/power-bi/developer/walkthrough-push-data-get-token
        $groupId=$Null, #if a GUID of a O365 group / PowerBI workspace is supplied, import will be processed there
        $reportName=$Null, #optional, if not used, filename is used as report name
        $importMode="CreateOrOverwrite", #valid values: https://docs.microsoft.com/en-us/rest/api/power-bi/imports/postimportingroup#importconflicthandlermode
        [Switch]$wait #if supplied, waits for the import to complete by polling the API periodically, then returns importState value ("Succeeded" if completed correctly). Otherwise, just returns the import job ID
    )

    if(!$ReportName){
        $ReportName = (Get-Item -LiteralPath $localPath).BaseName
    }

    if($groupId){
        $uri = "https://api.powerbi.com/v1.0/myorg/groups/$templateGroupId/imports?datasetDisplayName=$ReportName&nameConflict=$importMode"
    }else{
        $uri = "https://api.powerbi.com/v1.0/myorg/imports?datasetDisplayName=$ReportName&nameConflict=$importMode"
    }
    
    $boundary = "---------------------------" + (Get-Date).Ticks.ToString("x")
    $boundarybytes = [System.Text.Encoding]::ASCII.GetBytes("`r`n--" + $boundary + "`r`n")
    $request = [System.Net.WebRequest]::Create($uri)
    $request.ContentType = "multipart/form-data; boundary=" + $boundary
    $request.Method = "POST"
    $request.KeepAlive = $true
    $request.Headers.Add("Authorization", "Bearer $graphToken")
    $rs = $request.GetRequestStream()
    $rs.Write($boundarybytes, 0, $boundarybytes.Length);
    $header = "Content-Disposition: form-data; filename=`"temp.pbix`"`r`nContent-Type: application / octet - stream`r`n`r`n"
    $headerbytes = [System.Text.Encoding]::UTF8.GetBytes($header)
    $rs.Write($headerbytes, 0, $headerbytes.Length);
    $fileContent = [System.IO.File]::ReadAllBytes($localPath)
    $rs.Write($fileContent,0,$fileContent.Length)
    $trailer = [System.Text.Encoding]::ASCII.GetBytes("`r`n--" + $boundary + "--`r`n");
    $rs.Write($trailer, 0, $trailer.Length);
    $rs.Flush()
    $rs.Close()
    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $streamReader = [System.IO.StreamReader]($stream)
    $content = $streamReader.ReadToEnd() | convertfrom-json
    $jobId = $content.id
    $streamReader.Close()
    $response.Close()
    $header = @{
        'Authorization' = 'Bearer ' + $graphToken}
    if($wait){
        while($true){
            $res = Invoke-RestMethod -Method GET -uri "https://api.powerbi.com/beta/myorg/imports/$jobId" -UseBasicParsing -Headers $header 
            if($res.ImportState -ne "Publishing"){
                Return $res.ImportState
            }
            Sleep -s 5
        }
    }else{
        Write-Output $($content.id)
    }    
}