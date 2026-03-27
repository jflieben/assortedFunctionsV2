using System.Text.Json.Serialization;

namespace SPPathFixer.Engine.Models;

public class ApiResponse
{
    public bool Success { get; set; }
    public object? Data { get; set; }
    public string? Error { get; set; }

    public static ApiResponse Ok(object? data = null) => new() { Success = true, Data = data };
    public static ApiResponse Fail(string error) => new() { Success = false, Error = error };
}

public class AppConfig
{
    public int GuiPort { get; set; } = 8090;
    public int MaxPathLength { get; set; } = 256;
    public int MaxPathLengthSpecial { get; set; } = 218;
    public string SpecialExtensions { get; set; } = ".xlsx,.xls";
    public string ExtensionFilter { get; set; } = "";
    public int MaxThreads { get; set; } = 3;
    public string OutputFormat { get; set; } = "XLSX";
}

public class StatusResponse
{
    public bool Connected { get; set; }
    public string? TenantDomain { get; set; }
    public string? UserPrincipalName { get; set; }
    public string AuthMode { get; set; } = "None";
    public string ModuleVersion { get; set; } = "";
    public bool Scanning { get; set; }
    public long? ActiveScanId { get; set; }
    public bool Fixing { get; set; }
    public long? ActiveFixBatchId { get; set; }
}

public class ScanRequest
{
    public string[]? SiteUrls { get; set; }
    public bool AllSites { get; set; }
    public int MaxPathLength { get; set; } = 256;
    public int? MaxPathLengthSpecial { get; set; }
    public string? SpecialExtensions { get; set; }
    public string? ExtensionFilter { get; set; }
}

public class ScanInfo
{
    public long Id { get; set; }
    public string StartedAt { get; set; } = "";
    public string? CompletedAt { get; set; }
    public string Status { get; set; } = "";
    public string? SiteFilter { get; set; }
    public string? ExtensionFilter { get; set; }
    public int MaxPathLength { get; set; }
    public string? SpecialExtensions { get; set; }
    public int? MaxPathLengthSpecial { get; set; }
    public int TotalSites { get; set; }
    public int TotalLibraries { get; set; }
    public int TotalItemsScanned { get; set; }
    public int TotalLongPaths { get; set; }
    public string? Notes { get; set; }
}

public class LongPathItem
{
    public long Id { get; set; }
    public long ScanId { get; set; }
    public string SiteUrl { get; set; } = "";
    public string LibraryTitle { get; set; } = "";
    public string LibraryServerRelativeUrl { get; set; } = "";
    public string ItemId { get; set; } = "";
    public string ItemUniqueId { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string ItemExtension { get; set; } = "";
    public string ItemType { get; set; } = "";
    public string FileRef { get; set; } = "";
    public string FullUrl { get; set; } = "";
    public int PathTotalLength { get; set; }
    public int PathParentLength { get; set; }
    public int PathLeafLength { get; set; }
    public int MaxAllowed { get; set; }
    public int Delta { get; set; }
    public int DeepestChildDepth { get; set; }
    public string FixStatus { get; set; } = "pending";
    public string? FixStrategy { get; set; }
    public string? FixNewName { get; set; }
    public string? FixResult { get; set; }
    public string? FixAppliedAt { get; set; }
}

public class ScanProgress
{
    public long ScanId { get; set; }
    public string Status { get; set; } = "";
    public int TotalSites { get; set; }
    public int ProcessedSites { get; set; }
    public int TotalLibraries { get; set; }
    public int TotalItemsScanned { get; set; }
    public int TotalLongPaths { get; set; }
    public int OverallPercent { get; set; }
    public string CurrentSite { get; set; } = "";
    public string CurrentLibrary { get; set; } = "";
    public List<LogEntry> RecentLogs { get; set; } = new();
}

public class LogEntry
{
    public string Timestamp { get; set; } = "";
    public string Message { get; set; } = "";
    public string Level { get; set; } = "info";
}

public class FixRequest
{
    public string Strategy { get; set; } = "";
    public long[]? ItemIds { get; set; }
    public bool ApplyToAll { get; set; }
    public int? TargetMaxLength { get; set; }
    public int? TargetMaxLengthSpecial { get; set; }
    public string? SpecialExtensions { get; set; }
    public string? TargetFolder { get; set; }
    public bool WhatIf { get; set; }
}

public class FixBatchInfo
{
    public long Id { get; set; }
    public long ScanId { get; set; }
    public string Strategy { get; set; } = "";
    public string StartedAt { get; set; } = "";
    public string? CompletedAt { get; set; }
    public string Status { get; set; } = "";
    public int TotalItems { get; set; }
    public int FixedItems { get; set; }
    public int FailedItems { get; set; }
}

public class FixProgressResponse
{
    public long BatchId { get; set; }
    public long ScanId { get; set; }
    public string Status { get; set; } = "idle";
    public string Strategy { get; set; } = "";
    public int TotalItems { get; set; }
    public int FixedItems { get; set; }
    public int FailedItems { get; set; }
    public int OverallPercent { get; set; }
    public List<LogEntry> RecentLogs { get; set; } = new();
}

public class PermissionCheckResult
{
    public bool HasRequiredPermissions { get; set; }
    public string AuthMode { get; set; } = "";
    public string[] MissingPermissions { get; set; } = Array.Empty<string>();
    public string[] GrantedPermissions { get; set; } = Array.Empty<string>();
    public string Guidance { get; set; } = "";
}

public class ScanResultsPage
{
    public List<LongPathItem> Items { get; set; } = new();
    public int TotalCount { get; set; }
    public int Page { get; set; }
    public int PageSize { get; set; }
    public int TotalPages { get; set; }
}

public class ScanSummary
{
    public int TotalItems { get; set; }
    public int FileCount { get; set; }
    public int FolderCount { get; set; }
    public int CriticalCount { get; set; }
    public int WarningCount { get; set; }
    public int AvgPathLength { get; set; }
    public int MaxPathLengthFound { get; set; }
    public int FixedCount { get; set; }
    public int UniqueSites { get; set; }
    public int UniqueExtensions { get; set; }
    public Dictionary<string, int> BySite { get; set; } = new();
    public Dictionary<string, int> ByExtension { get; set; } = new();
    public Dictionary<string, int> ByFixStatus { get; set; } = new();
}
