function Start-SPFixScan {
    <#
    .SYNOPSIS
        Starts a scan for files and folders with long paths in SharePoint Online.
    .PARAMETER SiteUrls
        Specific site URLs to scan. If omitted, scans all sites in the tenant.
    .PARAMETER MaxPathLength
        Maximum allowed path length. Items exceeding this are flagged. Uses config default if not specified.
    .PARAMETER ExtensionFilter
        Comma-separated list of extensions to scan (e.g. ".xlsx,.docx"). Empty = all files.
    .EXAMPLE
        Start-SPFixScan
    .EXAMPLE
        Start-SPFixScan -SiteUrls "https://contoso.sharepoint.com/sites/Project1"
    .EXAMPLE
        Start-SPFixScan -SiteUrls "https://contoso.sharepoint.com/sites/Project1","https://contoso.sharepoint.com/sites/Project2" -MaxPathLength 400
    #>
    [CmdletBinding()]
    param(
        [string[]]$SiteUrls,
        [int]$MaxPathLength,
        [string]$ExtensionFilter
    )

    $engine = Get-SPFixEngine
    $request = [SPPathFixer.Engine.Models.ScanRequest]::new()
    if ($SiteUrls) { $request.SiteUrls = [System.Collections.Generic.List[string]]::new($SiteUrls) }
    if ($MaxPathLength -gt 0) { $request.MaxPathLength = $MaxPathLength }
    if ($ExtensionFilter) { $request.ExtensionFilter = $ExtensionFilter }

    $scanId = $engine.StartScan($request)
    Write-Host "Scan started (ID: $scanId). Use Get-SPFixScanStatus to monitor progress." -ForegroundColor Cyan
    return $scanId
}
