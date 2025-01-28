function Add-ToReportQueue{
    param(
        [array]$statistics,
        [array]$permissions,
        [Parameter(Mandatory=$true)]
        [string]$category
    )

    Write-Verbose "Adding $category report to write queue..."

    #add report to queue
    if($statistics -or $permissions){
        if($category -and ($permissions -or $statistics)){
            if(!(Test-Path $global:octo.outputTempFolder)){
                $Null = New-Item -Path $global:octo.outputTempFolder -ItemType Directory -Force

            }
            $randomId = Get-Random -Minimum 100000 -Maximum 9999999999
            [PSCustomObject]@{
                statistics = $statistics
                permissions = $permissions
                category = $category
            } | Export-Clixml -Path (Join-Path -Path $global:octo.outputTempFolder -ChildPath "$((Get-Date).ToString("HHmmss"))$($randomId).xml") -Depth 99 -Force
            [System.GC]::Collect()
       }
    }
}