function Export-WithRetry{
    Param(
        [parameter(Mandatory=$true)][string]$category,
        [parameter(Mandatory=$true)][object]$data
    )

    $basePath = Join-Path -Path $global:octo.outputFolder -ChildPath "M365Permissions_$((Get-Date).ToString("yyyyMMdd")).@@@"

    switch($global:octo.outputFormat){
        "XLSX" { 
            $targetPath = $basePath.Replace("@@@","xlsx")
        }
        "CSV" { 
            $targetPath = $basePath.Replace(".@@@","$($category).csv")
        }
    }           

    try{
        if($global:octo.outputFormat -eq "XLSX"){
            $lock = New-ReportFileLock
        }        
        $maxRetries = 60
        $attempts = 0
        while($attempts -lt $maxRetries){
            $attempts++
            try{
                switch($global:octo.outputFormat){
                    "XLSX" {$data | Export-Excel -NoNumberConversion "Module version" -Path $targetPath -WorksheetName $($category) -TableName $($category) -TableStyle Medium10 -Append -AutoSize}
                    "CSV" {$data | Export-Csv -Path $targetPath -NoTypeInformation -Append}
                }
                $attempts = $maxRetries
                Write-Output "Wrote $($data.count) rows for $category to $targetPath"
            }catch{
                if($attempts -eq $maxRetries){
                    Throw
                }else{
                    Write-Verbose "File locked, waiting..."
                    Start-Sleep -s (Get-Random -Minimum 1 -Maximum 3)
                }
            }
        }
    }catch{
        Write-Error $_ -ErrorAction Continue
        Write-Error "Failed to write to $targetPath" -ErrorAction Stop
    }Finally{
        if($global:octo.outputFormat -eq "XLSX"){
            Remove-ReportFileLock -lock $lock
        }
    }
}