using System.Text.Json;
using SPPathFixer.Engine.Auth;
using SPPathFixer.Engine.Database;
using SPPathFixer.Engine.Graph;
using SPPathFixer.Engine.Models;

namespace SPPathFixer.Engine.Scanning;

public sealed class ScanOrchestrator
{
    private readonly ScanRepository _scanRepo;
    private readonly ItemRepository _itemRepo;
    private readonly ProgressRepository _progressRepo;
    private readonly GraphClient _graphClient;
    private readonly SharePointAuth _auth;

    private CancellationTokenSource? _cts;
    private Task? _scanTask;
    private Task? _fixTask;
    private long _activeScanId;
    private long _activeFixBatchId;

    // Live counters for progress
    private int _totalSites;
    private int _processedSites;
    private int _totalLibraries;
    private int _totalItemsScanned;
    private int _totalLongPaths;
    private string _currentSite = "";
    private string _currentLibrary = "";

    public bool IsScanning => _scanTask != null && !_scanTask.IsCompleted;
    public long ActiveScanId => _activeScanId;
    public bool IsFixing => _fixTask != null && !_fixTask.IsCompleted;
    public long ActiveFixBatchId => _activeFixBatchId;

    public ScanOrchestrator(ScanRepository scanRepo, ItemRepository itemRepo,
        ProgressRepository progressRepo, GraphClient graphClient, SharePointAuth auth)
    {
        _scanRepo = scanRepo;
        _itemRepo = itemRepo;
        _progressRepo = progressRepo;
        _graphClient = graphClient;
        _auth = auth;
    }

    public long StartScan(ScanRequest request)
    {
        if (IsScanning) throw new InvalidOperationException("A scan is already in progress.");

        var scanId = _scanRepo.CreateScan(request);
        _activeScanId = scanId;
        _cts = new CancellationTokenSource();

        _scanTask = Task.Run(async () =>
        {
            try
            {
                await RunScanAsync(scanId, request, _cts.Token);
                _scanRepo.CompleteScan(scanId, "completed");
                _progressRepo.AddLog(scanId, "Scan completed successfully.", "info");
            }
            catch (OperationCanceledException)
            {
                _scanRepo.CompleteScan(scanId, "cancelled");
                _progressRepo.AddLog(scanId, "Scan was cancelled.", "warning");
            }
            catch (Exception ex)
            {
                _scanRepo.CompleteScan(scanId, "failed");
                _progressRepo.AddLog(scanId, $"Scan failed: {ex.Message}", "error");
            }
        });

        return scanId;
    }

    public void CancelScan()
    {
        _cts?.Cancel();
    }

    public ScanProgress GetProgress()
    {
        return new ScanProgress
        {
            ScanId = _activeScanId,
            Status = IsScanning ? "running" : (_scanRepo.GetScan(_activeScanId)?.Status ?? "idle"),
            TotalSites = _totalSites,
            ProcessedSites = _processedSites,
            TotalLibraries = _totalLibraries,
            TotalItemsScanned = _totalItemsScanned,
            TotalLongPaths = _totalLongPaths,
            OverallPercent = _totalSites > 0 ? (int)((double)_processedSites / _totalSites * 100) : 0,
            CurrentSite = _currentSite,
            CurrentLibrary = _currentLibrary,
            RecentLogs = _activeScanId > 0 ? _progressRepo.GetRecentLogs(_activeScanId) : new()
        };
    }

    private async Task RunScanAsync(long scanId, ScanRequest request, CancellationToken ct)
    {
        _totalSites = 0;
        _processedSites = 0;
        _totalLibraries = 0;
        _totalItemsScanned = 0;
        _totalLongPaths = 0;

        var specialExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(request.SpecialExtensions))
        {
            foreach (var ext in request.SpecialExtensions.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                specialExtensions.Add(ext.StartsWith('.') ? ext : $".{ext}");
        }

        var extensionFilter = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(request.ExtensionFilter))
        {
            foreach (var ext in request.ExtensionFilter.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                extensionFilter.Add(ext.StartsWith('.') ? ext : $".{ext}");
        }

        _progressRepo.AddLog(scanId, "Discovering sites...", "info");

        // Discover sites
        var siteUrls = new List<string>();
        if (request.SiteUrls != null && request.SiteUrls.Length > 0)
        {
            siteUrls.AddRange(request.SiteUrls.Where(u => !string.IsNullOrWhiteSpace(u)));
            _progressRepo.AddLog(scanId, $"Scanning {siteUrls.Count} specified site(s).");
        }
        else
        {
            // Enumerate all sites via Graph (search=* works with both delegated and app-only)
            _progressRepo.AddLog(scanId, "Enumerating all sites in tenant...");
            await foreach (var site in _graphClient.GetPagedAsync("sites?search=*&$select=id,displayName,webUrl&$top=999", ct))
            {
                ct.ThrowIfCancellationRequested();
                if (site.TryGetProperty("webUrl", out var urlProp))
                {
                    var url = urlProp.GetString();
                    if (!string.IsNullOrEmpty(url) && !url.Contains("-my.sharepoint.com", StringComparison.OrdinalIgnoreCase))
                        siteUrls.Add(url);
                }
            }
            _progressRepo.AddLog(scanId, $"Found {siteUrls.Count} site(s).");
        }

        _totalSites = siteUrls.Count;

        for (int i = 0; i < siteUrls.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var siteUrl = siteUrls[i];
            _currentSite = siteUrl;
            _processedSites = i;
            _progressRepo.AddLog(scanId, $"Processing site {i + 1}/{siteUrls.Count}: {siteUrl}");

            try
            {
                await ScanSiteAsync(scanId, siteUrl, request.MaxPathLength,
                    request.MaxPathLengthSpecial, specialExtensions, extensionFilter, ct);
            }
            catch (Exception ex)
            {
                _progressRepo.AddLog(scanId, $"Error scanning site {siteUrl}: {ex.Message}", "error");
            }
        }

        _processedSites = siteUrls.Count;
        _scanRepo.UpdateScanStats(scanId, _totalSites, _totalLibraries, _totalItemsScanned, _totalLongPaths);
    }

    private async Task ScanSiteAsync(long scanId, string siteUrl, int maxPathLength,
        int? maxPathLengthSpecial, HashSet<string> specialExtensions, HashSet<string> extensionFilter,
        CancellationToken ct)
    {
        // Resolve Graph site ID from URL
        var siteId = await ResolveSiteIdAsync(siteUrl, ct);
        if (siteId == null)
        {
            _progressRepo.AddLog(scanId, $"Could not resolve site ID for {siteUrl}, skipping.", "warning");
            return;
        }

        // Get document libraries
        var drives = new List<(string DriveId, string Name, string WebUrl)>();
        await foreach (var drive in _graphClient.GetPagedAsync($"sites/{siteId}/drives?$select=id,name,webUrl,driveType", ct))
        {
            ct.ThrowIfCancellationRequested();
            var driveType = drive.TryGetProperty("driveType", out var dt) ? dt.GetString() : "";
            if (driveType == "documentLibrary" || driveType == "business")
            {
                var id = drive.GetProperty("id").GetString()!;
                var name = drive.TryGetProperty("name", out var n) ? n.GetString() ?? id : id;
                var webUrl = drive.TryGetProperty("webUrl", out var wu) ? wu.GetString() ?? "" : "";
                drives.Add((id, name, webUrl));
            }
        }

        _totalLibraries += drives.Count;

        foreach (var (driveId, driveName, driveWebUrl) in drives)
        {
            ct.ThrowIfCancellationRequested();
            _currentLibrary = driveName;
            _progressRepo.AddLog(scanId, $"  Scanning library: {driveName}");

            try
            {
                await ScanDriveAsync(scanId, siteUrl, driveId, driveName, driveWebUrl,
                    maxPathLength, maxPathLengthSpecial, specialExtensions, extensionFilter, ct);
            }
            catch (Exception ex)
            {
                _progressRepo.AddLog(scanId, $"  Error scanning library {driveName}: {ex.Message}", "error");
            }
        }
    }

    private async Task ScanDriveAsync(long scanId, string siteUrl, string driveId, string driveName,
        string driveWebUrl, int maxPathLength, int? maxPathLengthSpecial,
        HashSet<string> specialExtensions, HashSet<string> extensionFilter, CancellationToken ct)
    {
        var batch = new List<LongPathItem>();

        // Recursively enumerate all items via delta/children
        await ScanFolderAsync(scanId, siteUrl, driveId, driveName, driveWebUrl,
            $"drives/{driveId}/root", "", maxPathLength, maxPathLengthSpecial,
            specialExtensions, extensionFilter, batch, ct);

        // Compute deepest child depth for folders
        ComputeDeepestChildDepths(batch);

        // Remove folders that have no children exceeding the limit
        var urls = new HashSet<string>(batch.Select(b => b.FullUrl), StringComparer.OrdinalIgnoreCase);
        batch.RemoveAll(item =>
        {
            if (item.ItemType != "Folder") return false;
            // Keep folder if any item has a URL starting with this folder's URL and exceeds the limit
            return !batch.Any(other => other.ItemType != "Folder" &&
                other.FullUrl.StartsWith(item.FullUrl + "/", StringComparison.OrdinalIgnoreCase));
        });

        if (batch.Count > 0)
        {
            _itemRepo.InsertItems(batch);
            _totalLongPaths += batch.Count;
        }
    }

    private async Task ScanFolderAsync(long scanId, string siteUrl, string driveId, string driveName,
        string driveWebUrl, string folderPath, string parentWebPath,
        int maxPathLength, int? maxPathLengthSpecial,
        HashSet<string> specialExtensions, HashSet<string> extensionFilter,
        List<LongPathItem> batch, CancellationToken ct)
    {
        await foreach (var item in _graphClient.GetPagedAsync($"{folderPath}/children?$select=id,name,size,file,folder,parentReference&$top=999", ct))
        {
            ct.ThrowIfCancellationRequested();
            _totalItemsScanned++;

            var name = item.GetProperty("name").GetString() ?? "";
            var isFolder = item.TryGetProperty("folder", out _);
            var isFile = item.TryGetProperty("file", out _);
            var itemId = item.GetProperty("id").GetString() ?? "";

            // Build the actual file system URL from driveWebUrl + parentReference.path + name
            // parentReference.path looks like: /drives/{driveId}/root:/folder1/folder2
            // or just /drives/{driveId}/root if at the library root
            var relativePath = "";
            if (item.TryGetProperty("parentReference", out var parentRef) &&
                parentRef.TryGetProperty("path", out var parentPath))
            {
                var pathStr = parentPath.GetString() ?? "";
                var rootMarker = pathStr.IndexOf("root:", StringComparison.Ordinal);
                if (rootMarker >= 0)
                {
                    // Everything after "root:" is the folder path within the library
                    relativePath = Uri.UnescapeDataString(pathStr[(rootMarker + 5)..]);
                }
                // If just "root" without colon, item is at library root — relativePath stays ""
            }

            var decodedDriveUrl = Uri.UnescapeDataString(driveWebUrl);
            var fullUrl = string.IsNullOrEmpty(relativePath)
                ? $"{decodedDriveUrl}/{name}"
                : $"{decodedDriveUrl}{relativePath}/{name}";
            var fileRef = fullUrl.Contains("://")
                ? fullUrl[(fullUrl.IndexOf('/', fullUrl.IndexOf("://") + 3))..] // server-relative path
                : fullUrl;

            // Determine extension
            var ext = "";
            if (isFile)
            {
                var dotPos = name.LastIndexOf('.');
                if (dotPos >= 0) ext = name[dotPos..];
            }

            // Apply extension filter
            if (isFile && extensionFilter.Count > 0 && !extensionFilter.Contains(ext))
            {
                continue;
            }

            // Determine max path for this item
            var localMax = maxPathLength;
            if (isFile && maxPathLengthSpecial.HasValue && specialExtensions.Contains(ext))
                localMax = maxPathLengthSpecial.Value;

            var pathLength = fullUrl.Length;

            // Check if path exceeds limit
            if (pathLength >= localMax || isFolder)
            {
                var parentLength = pathLength - name.Length;

                if (pathLength >= localMax)
                {
                    batch.Add(new LongPathItem
                    {
                        ScanId = scanId,
                        SiteUrl = siteUrl,
                        LibraryTitle = driveName,
                        LibraryServerRelativeUrl = decodedDriveUrl,
                        ItemId = itemId,
                        ItemUniqueId = itemId,
                        ItemName = name,
                        ItemExtension = ext,
                        ItemType = isFolder ? "Folder" : "File",
                        FileRef = fileRef,
                        FullUrl = fullUrl,
                        PathTotalLength = pathLength,
                        PathParentLength = parentLength > 0 ? parentLength : 0,
                        PathLeafLength = name.Length,
                        MaxAllowed = localMax,
                        Delta = localMax - pathLength,
                        DeepestChildDepth = pathLength
                    });
                }
            }

            // Recurse into folders
            if (isFolder)
            {
                await ScanFolderAsync(scanId, siteUrl, driveId, driveName, driveWebUrl,
                    $"drives/{driveId}/items/{itemId}", fullUrl, maxPathLength, maxPathLengthSpecial,
                    specialExtensions, extensionFilter, batch, ct);
            }
        }
    }

    private static void ComputeDeepestChildDepths(List<LongPathItem> items)
    {
        foreach (var folder in items.Where(i => i.ItemType == "Folder"))
        {
            var folderUrl = folder.FullUrl + "/";
            var maxChildDepth = items
                .Where(i => i.FullUrl.StartsWith(folderUrl, StringComparison.OrdinalIgnoreCase))
                .Select(i => i.PathTotalLength)
                .DefaultIfEmpty(folder.PathTotalLength)
                .Max();
            folder.DeepestChildDepth = maxChildDepth;
        }
    }

    private async Task<string?> ResolveSiteIdAsync(string siteUrl, CancellationToken ct)
    {
        try
        {
            var uri = new Uri(siteUrl);
            var hostname = uri.Host;
            var path = uri.AbsolutePath.TrimEnd('/');

            if (string.IsNullOrEmpty(path) || path == "/")
            {
                var result = await _graphClient.GetAsync($"sites/{hostname}:", ct: ct);
                return result?.GetProperty("id").GetString();
            }

            var result2 = await _graphClient.GetAsync($"sites/{hostname}:{path}", ct: ct);
            return result2?.GetProperty("id").GetString();
        }
        catch { return null; }
    }

    // ── Fix Operations ──────────────────────────────────────────

    public long StartFix(long scanId, FixRequest request)
    {
        if (IsFixing) throw new InvalidOperationException("A fix operation is already in progress.");

        var items = request.ApplyToAll
            ? _itemRepo.GetAllItems(scanId).Where(i => i.FixStatus == "pending" || i.FixStatus == "preview").ToList()
            : request.ItemIds != null
                ? _itemRepo.GetItemsByIds(scanId, request.ItemIds).Where(i => i.FixStatus == "pending" || i.FixStatus == "preview").ToList()
                : new List<LongPathItem>();

        if (items.Count == 0) throw new InvalidOperationException("No pending items to fix.");

        var batchId = _progressRepo.CreateFixBatch(scanId, request.Strategy, items.Count);
        _activeFixBatchId = batchId;

        _fixTask = Task.Run(async () =>
        {
            int fixedCount = 0, failedCount = 0, skippedCount = 0;
            try
            {
                foreach (var item in items)
                {
                    try
                    {
                        if (request.WhatIf)
                        {
                            var preview = PreviewFix(item, request);
                            _itemRepo.UpdateFixStatus(item.Id, "preview", preview.NewName, preview.Description, request.Strategy);
                            fixedCount++;
                        }
                        else
                        {
                            // Verify item hasn't changed since scan (stale detection)
                            var staleReason = await CheckIfStaleAsync(item);
                            if (staleReason != null)
                            {
                                skippedCount++;
                                _itemRepo.UpdateFixStatus(item.Id, "skipped", null, $"Stale: {staleReason}", request.Strategy);
                                _progressRepo.AddLog(scanId, $"Skipped {item.ItemName}: {staleReason}", "warning");
                            }
                            else
                            {
                                await ApplyFixAsync(item, request);
                                fixedCount++;
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        failedCount++;
                        _itemRepo.UpdateFixStatus(item.Id, "failed", null, ex.Message, request.Strategy);
                        _progressRepo.AddLog(scanId, $"Failed to fix {item.ItemName}: {ex.Message}", "error");
                    }

                    _progressRepo.UpdateFixBatch(batchId, fixedCount, failedCount, "running");
                }

                _progressRepo.UpdateFixBatch(batchId, fixedCount, failedCount, "completed");
                var msg = $"Fix batch completed: {fixedCount} fixed, {failedCount} failed";
                if (skippedCount > 0) msg += $", {skippedCount} skipped (stale)";
                _progressRepo.AddLog(scanId, msg + ".", "info");
            }
            catch (Exception ex)
            {
                _progressRepo.UpdateFixBatch(batchId, fixedCount, failedCount, "failed");
                _progressRepo.AddLog(scanId, $"Fix batch failed: {ex.Message}", "error");
            }
        });

        return batchId;
    }

    /// <summary>
    /// Checks if an item is stale (deleted, moved, or renamed since scan time).
    /// Returns null if item is current, or a reason string if stale.
    /// </summary>
    private async Task<string?> CheckIfStaleAsync(LongPathItem item)
    {
        try
        {
            var siteId = await ResolveSiteIdAsync(item.SiteUrl, CancellationToken.None);
            if (siteId == null)
                return "Site no longer accessible";

            var result = await _graphClient.GetAsync(
                $"sites/{siteId}/drive/items/{item.ItemId}?$select=id,name,parentReference",
                ct: CancellationToken.None);

            if (result == null)
                return "Item no longer exists (deleted or moved to a different drive)";

            var currentName = result.Value.TryGetProperty("name", out var n) ? n.GetString() : null;
            if (currentName != null && !string.Equals(currentName, item.ItemName, StringComparison.Ordinal))
                return $"Item was renamed (now '{currentName}', expected '{item.ItemName}')";

            // Check if it was moved by comparing parent path
            if (result.Value.TryGetProperty("parentReference", out var parentRef) &&
                parentRef.TryGetProperty("path", out var pathProp))
            {
                var currentParentPath = pathProp.GetString() ?? "";
                // parentReference.path looks like /drives/{driveId}/root:/folder/subfolder
                // FileRef looks like /sites/sitename/library/folder/subfolder/filename
                // We just check the parent path hasn't changed by looking at the item's current full path length
                // A moved item will have a different parent path
                if (!string.IsNullOrEmpty(item.FileRef) && !string.IsNullOrEmpty(currentParentPath))
                {
                    // Extract the relative folder portion from the current parent path (after "root:" or "root:/")
                    var rootIdx = currentParentPath.IndexOf("root:", StringComparison.OrdinalIgnoreCase);
                    var currentRelFolder = rootIdx >= 0 ? currentParentPath[(rootIdx + 5)..].TrimStart('/') : "";

                    // Extract the relative folder from the scanned FileRef (strip site + library prefix)
                    var fileRefParts = item.FileRef.Split('/');
                    // FileRef = /sites/name/library/folder/.../filename → folder parts are between library and filename
                    var scannedRelFolder = fileRefParts.Length > 4
                        ? string.Join("/", fileRefParts.Skip(4).Take(fileRefParts.Length - 5))
                        : "";

                    if (!string.Equals(currentRelFolder, scannedRelFolder, StringComparison.OrdinalIgnoreCase))
                        return $"Item was moved (parent folder changed)";
                }
            }

            return null; // Item is current
        }
        catch (HttpRequestException ex) when (ex.Message.Contains("404") || ex.Message.Contains("NotFound"))
        {
            return "Item no longer exists (deleted)";
        }
        catch (Exception ex)
        {
            // If we can't verify, log but don't skip — let the actual fix attempt handle it
            _progressRepo.AddLog(item.ScanId, $"Warning: Could not verify state of {item.ItemName}: {ex.Message}", "warning");
            return null;
        }
    }

    private int GetMaxPathForItem(LongPathItem item, FixRequest request)
    {
        var maxPath = request.TargetMaxLength ?? 256;
        if (!string.IsNullOrEmpty(item.ItemExtension) && request.TargetMaxLengthSpecial.HasValue)
        {
            var specialExts = (request.SpecialExtensions ?? ".xlsx,.xls")
                .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            foreach (var ext in specialExts)
            {
                var normalizedExt = ext.StartsWith('.') ? ext : $".{ext}";
                if (string.Equals(item.ItemExtension, normalizedExt, StringComparison.OrdinalIgnoreCase))
                {
                    maxPath = request.TargetMaxLengthSpecial.Value;
                    break;
                }
            }
        }
        return maxPath;
    }

    private (string NewName, string Description) PreviewFix(LongPathItem item, FixRequest request)
    {
        return request.Strategy switch
        {
            "shorten_name" => PreviewShortenName(item, GetMaxPathForItem(item, request)),
            "move_up" => PreviewMoveUp(item),
            "flatten_path" => PreviewFlattenPath(item, request.TargetFolder),
            _ => (item.ItemName, "Unknown strategy")
        };
    }

    private static (string NewName, string Description) PreviewShortenName(LongPathItem item, int maxPathLength)
    {
        if (item.PathTotalLength <= maxPathLength)
            return (item.ItemName, $"Path already within limit ({item.PathTotalLength} ≤ {maxPathLength}).");

        var charsToRemove = item.PathTotalLength - maxPathLength;
        var ext = item.ItemExtension;
        var nameWithoutExt = string.IsNullOrEmpty(ext) ? item.ItemName : item.ItemName[..^ext.Length];
        var targetNameLen = nameWithoutExt.Length - charsToRemove;

        if (targetNameLen < 5)
        {
            targetNameLen = 5;
            var newLen = item.PathTotalLength - nameWithoutExt.Length + 5 + (ext?.Length ?? 0);
            return (nameWithoutExt[..5].TrimEnd() + ext,
                $"Name shortened to minimum (5 chars). Path: {item.PathTotalLength} → ~{newLen} (target: {maxPathLength})");
        }

        var shortened = nameWithoutExt[..targetNameLen].TrimEnd() + ext;
        var newPathLen = item.PathTotalLength - item.ItemName.Length + shortened.Length;
        return (shortened, $"Shorten name by {charsToRemove} chars. Path: {item.PathTotalLength} → {newPathLen} (target: ≤{maxPathLength})");
    }

    private static (string NewName, string Description) PreviewMoveUp(LongPathItem item)
    {
        // Move file/folder one level up in the hierarchy
        var parts = item.FileRef.Split('/');
        if (parts.Length <= 3)
            return (item.ItemName, "Already at library root, cannot move up.");

        var newPath = string.Join("/", parts.Take(parts.Length - 2).Append(parts.Last()));
        return (item.ItemName, $"Move to parent folder: {newPath}");
    }

    private static (string NewName, string Description) PreviewFlattenPath(LongPathItem item, string? targetFolder)
    {
        return (item.ItemName, $"Move to {targetFolder ?? "library root"} (flatten hierarchy). Duplicates will be suffixed automatically, e.g. file_1.docx.");
    }

    private async Task ApplyFixAsync(LongPathItem item, FixRequest request)
    {
        switch (request.Strategy)
        {
            case "shorten_name":
                await ApplyShortenNameAsync(item, GetMaxPathForItem(item, request));
                break;
            case "move_up":
                await ApplyMoveUpAsync(item);
                break;
            case "flatten_path":
                await ApplyFlattenPathAsync(item, request.TargetFolder);
                break;
            default:
                throw new ArgumentException($"Unknown strategy: {request.Strategy}");
        }
    }

    private async Task ApplyShortenNameAsync(LongPathItem item, int maxPathLength)
    {
        var preview = PreviewShortenName(item, maxPathLength);
        if (preview.NewName == item.ItemName)
        {
            _itemRepo.UpdateFixStatus(item.Id, "skipped", null, preview.Description, "shorten_name");
            return;
        }

        // Use Graph to rename the item
        var siteId = await ResolveSiteIdAsync(item.SiteUrl, CancellationToken.None);
        if (siteId == null) throw new InvalidOperationException("Cannot resolve site.");

        await _graphClient.PatchAsync($"sites/{siteId}/drive/items/{item.ItemId}",
            new { name = preview.NewName });

        _itemRepo.UpdateFixStatus(item.Id, "fixed", preview.NewName, $"Renamed to {preview.NewName}", "shorten_name");
        _progressRepo.AddLog(item.ScanId, $"Renamed {item.ItemName} → {preview.NewName}");
    }

    private async Task ApplyMoveUpAsync(LongPathItem item)
    {
        var siteId = await ResolveSiteIdAsync(item.SiteUrl, CancellationToken.None);
        if (siteId == null) throw new InvalidOperationException("Cannot resolve site.");

        // Get parent of parent
        var currentItem = await _graphClient.GetAsync($"sites/{siteId}/drive/items/{item.ItemId}?$select=id,name,parentReference");
        if (currentItem == null) throw new InvalidOperationException("Cannot retrieve item.");

        var parentRef = currentItem.Value.GetProperty("parentReference");
        var parentId = parentRef.GetProperty("id").GetString();

        // Get grandparent
        var parent = await _graphClient.GetAsync($"sites/{siteId}/drive/items/{parentId}?$select=id,parentReference");
        if (parent == null) throw new InvalidOperationException("Cannot retrieve parent.");

        var grandparentRef = parent.Value.GetProperty("parentReference");
        var grandparentId = grandparentRef.GetProperty("id").GetString();

        // Move item to grandparent
        await _graphClient.PatchAsync($"sites/{siteId}/drive/items/{item.ItemId}",
            new { parentReference = new { id = grandparentId } });

        _itemRepo.UpdateFixStatus(item.Id, "fixed", item.ItemName, "Moved up one directory level.", "move_up");
        _progressRepo.AddLog(item.ScanId, $"Moved {item.ItemName} up one directory level.");
    }

    private async Task ApplyFlattenPathAsync(LongPathItem item, string? targetFolder)
    {
        var siteId = await ResolveSiteIdAsync(item.SiteUrl, CancellationToken.None);
        if (siteId == null) throw new InvalidOperationException("Cannot resolve site.");

        string targetId;
        if (string.IsNullOrEmpty(targetFolder))
        {
            // Move to drive root
            var root = await _graphClient.GetAsync($"sites/{siteId}/drive/root?$select=id");
            targetId = root?.GetProperty("id").GetString()
                ?? throw new InvalidOperationException("Cannot get drive root.");
        }
        else
        {
            // Resolve target folder or create it
            var target = await _graphClient.GetAsync($"sites/{siteId}/drive/root:/{targetFolder}?$select=id");
            if (target != null)
            {
                targetId = target.Value.GetProperty("id").GetString()!;
            }
            else
            {
                // Create folder
                var createRequest = new Dictionary<string, object>
                {
                    ["name"] = targetFolder,
                    ["folder"] = new { },
                    ["@microsoft.graph.conflictBehavior"] = "rename"
                };
                var created = await _graphClient.PostAsync($"sites/{siteId}/drive/root/children", createRequest);
                targetId = created?.GetProperty("id").GetString()
                    ?? throw new InvalidOperationException("Cannot create target folder.");
            }
        }

        var moveRequest = new Dictionary<string, object>
        {
            ["parentReference"] = new { id = targetId },
            ["@microsoft.graph.conflictBehavior"] = "rename"
        };
        await _graphClient.PatchAsync($"sites/{siteId}/drive/items/{item.ItemId}", moveRequest);

        _itemRepo.UpdateFixStatus(item.Id, "fixed", item.ItemName,
            $"Moved to {targetFolder ?? "library root"}.", "flatten_path");
        _progressRepo.AddLog(item.ScanId, $"Moved {item.ItemName} to {targetFolder ?? "root"}.");
    }

    public void Shutdown()
    {
        _cts?.Cancel();
        try { _scanTask?.Wait(TimeSpan.FromSeconds(5)); } catch { }
        try { _fixTask?.Wait(TimeSpan.FromSeconds(5)); } catch { }
        _cts?.Dispose();
    }
}
