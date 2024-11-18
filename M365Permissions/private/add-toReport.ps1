function add-toReport{
    param(
        [array]$statistics,
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
        $maxRetries = 30
        $attempts = 0
        while($attempts -lt $maxRetries){
            $attempts++
            try{
                switch($type){
                    "XLSX" {$data | Export-Excel -Path $targetPath -WorksheetName $($category) -TableName $($category) -TableStyle Medium10 -Append -AutoSize}
                    "CSV" {$data | Export-Csv -Path $targetPath -NoTypeInformation -Append}
                }
                $attempts = $maxRetries
            }catch{
                if($attempts -eq $maxRetries){
                    Throw
                }else{
                    Write-Verbose "File locked, waiting..."
                    Start-Sleep -s 1
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
                if($statistics){
                    Export-WithRetry -targetPath $targetPath -category "Statistics" -data $statistics          
                }
                Write-Host "XLSX report saved to $targetPath"
            }
            "CSV" { 
                if($permissions){
                    $targetPath = $basePath.Replace(".@@@","$($category).csv")
                    Export-WithRetry -targetPath $targetPath -category "Statistics" -data $statistics -type "CSV"
                    Write-Host "CSV report saved to $targetPath"
                }else{
                    Write-Warning "No permissions found to save to CSV"
                }
            }
            "Default" { 
                if($permissions){
                    $permissionRows | out-gridview 
                }else{
                    Write-Warning "No permissions found to display"
                }
            }
        }
    }
}