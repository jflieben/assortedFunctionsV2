function Add-ToReportQueue{
    param(
        [array]$statistics,
        [array]$permissions,
        [Parameter(Mandatory=$true)]
        [string]$category
    )

    #add report to queue
    if($statistics -or $permissions){
        if($category -and ($permissions -or $statistics)){
            $global:octo.reportWriteQueue += [PSCustomObject]@{
                statistics = $statistics | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 #ensure pointers are not passed
                permissions = $permissions | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100 #ensure pointers are not passed
                category = $category
            }
        }
    }


}