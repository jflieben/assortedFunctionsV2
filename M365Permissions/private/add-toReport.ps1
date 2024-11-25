function add-toReport{
    param(
        [string]$subject,
        [parameter(Mandatory=$true)][array]$formats,
        [array]$permissions,
        [parameter(Mandatory=$true)][string]$category
    )

    if((get-location).Path){
        $basePath = Join-Path -Path (get-location).Path -ChildPath "M365Permissions.@@@"
    }else{
        $basePath = Join-Path -Path (Split-Path -Path $MyInvocation.MyCommand.Definition -Parent) -ChildPath "M365Permissions.@@@"
    }

    function Export-WithRetry{
        Param(
            [parameter(Mandatory=$true)][string]$targetPath,
            [parameter(Mandatory=$true)][string]$category,
            [parameter(Mandatory=$true)][object]$data,
            $type = "XLSX"
        )
        $maxRetries = 60
        $attempts = 0
        while($attempts -lt $maxRetries){
            $attempts++
            try{
                switch($type){
                    "XLSX" {$data | Export-Excel -NoNumberConversion "Module version" -Path $targetPath -WorksheetName $($category) -TableName $($category) -TableStyle Medium10 -Append -AutoSize}
                    "CSV" {$data | Export-Csv -Path $targetPath -NoTypeInformation -Append}
                }
                $attempts = $maxRetries
            }catch{
                if($attempts -eq $maxRetries){
                    Throw
                }else{
                    Write-Verbose "File locked, waiting..."
                    Start-Sleep -s (Get-Random -Minimum 1 -Maximum 3)
                }
            }
        }      
    }

    
    foreach($format in $formats){
        switch($format){
            "XLSX" { 
                $targetPath = $basePath.Replace("@@@","xlsx")
                if($permissions){
                    Export-WithRetry -targetPath $targetPath -category $category -data $permissions  
                }
                if($subject){
                    Export-WithRetry -targetPath $targetPath -category "Statistics" -data @($global:unifiedStatistics.$category.$subject)
                }
                Write-Host "$category line written to $targetPath"
            }
            "CSV" { 
                if($permissions){
                    $targetPath = $basePath.Replace(".@@@","$($category).csv")
                    Export-WithRetry -targetPath $targetPath -category "Statistics" -data $permissions -type "CSV"
                    Write-Host "$category line written to $targetPath"
                }else{
                    Write-Warning "No permissions found to save to CSV"
                }
            }
            "Default" { 
                if($permissions){
                    $permissions | out-gridview 
                }else{
                    Write-Warning "No permissions found to display"
                }
            }
        }
    }
}