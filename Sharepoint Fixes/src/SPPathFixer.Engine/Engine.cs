using System.Diagnostics;
using System.Text.Json;
using SPPathFixer.Engine.Auth;
using SPPathFixer.Engine.Database;
using SPPathFixer.Engine.Export;
using SPPathFixer.Engine.Graph;
using SPPathFixer.Engine.Http;
using SPPathFixer.Engine.Models;
using SPPathFixer.Engine.Scanning;

namespace SPPathFixer.Engine;

public sealed class Engine : IDisposable
{
    public static string ModuleVersion { get; } =
        typeof(Engine).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    private readonly SqliteDb _db;
    private readonly ConfigRepository _configRepo;
    private readonly ScanRepository _scanRepo;
    private readonly ItemRepository _itemRepo;
    private readonly ProgressRepository _progressRepo;
    private readonly TokenCache _tokenCache;
    private readonly SharePointAuth _auth;
    private readonly ExcelExporter _excelExporter;

    private GraphClient? _graphClient;
    private ScanOrchestrator? _orchestrator;
    private WebServer? _webServer;
    private AppConfig _config;
    private readonly Task _sessionRestoreTask;

    public Engine(string databasePath)
    {
        _db = new SqliteDb(databasePath);
        _db.Initialize();

        _configRepo = new ConfigRepository(_db);
        _scanRepo = new ScanRepository(_db);
        _itemRepo = new ItemRepository(_db);
        _progressRepo = new ProgressRepository(_db);

        var persistDir = Path.GetDirectoryName(databasePath) ?? ".";
        _tokenCache = new TokenCache(persistDir);
        _auth = new SharePointAuth(_tokenCache);
        _excelExporter = new ExcelExporter();

        _config = _configRepo.Load();

        _sessionRestoreTask = Task.Run(async () =>
        {
            try
            {
                if (await _auth.TryRestoreSessionAsync())
                    InitializeClients();
            }
            catch { /* best effort */ }
        });
    }

    public async Task EnsureSessionRestoredAsync(int timeoutMs = 5000)
    {
        await Task.WhenAny(_sessionRestoreTask, Task.Delay(timeoutMs));
    }

    // ── Status ──────────────────────────────────────────────────

    public StatusResponse GetStatus() => new()
    {
        Connected = _auth.IsConnected,
        TenantDomain = _auth.TenantDomain,
        UserPrincipalName = _auth.UserPrincipalName,
        AuthMode = _auth.AuthMode,
        ModuleVersion = ModuleVersion,
        Scanning = _orchestrator?.IsScanning ?? false,
        ActiveScanId = _orchestrator?.IsScanning == true ? _orchestrator.ActiveScanId : null,
        Fixing = _orchestrator?.IsFixing ?? false,
        ActiveFixBatchId = _orchestrator?.IsFixing == true ? _orchestrator.ActiveFixBatchId : null
    };

    // ── Auth ────────────────────────────────────────────────────

    public async Task ConnectAsync(string mode = "delegated", string? clientId = null, string? tenantId = null,
        string? pfxPath = null, string? pfxPassword = null, string? thumbprint = null,
        CancellationToken ct = default)
    {
        if (mode.Equals("certificate", StringComparison.OrdinalIgnoreCase))
        {
            if (string.IsNullOrEmpty(clientId) || string.IsNullOrEmpty(tenantId))
                throw new ArgumentException("ClientId and TenantId are required for certificate auth.");
            await _auth.AuthenticateCertificateAsync(clientId, tenantId, pfxPath, pfxPassword, thumbprint, ct);
        }
        else
        {
            await _auth.AuthenticateDelegatedAsync(clientId, ct);
        }

        InitializeClients();
        _progressRepo.AddAuditLog("connect", $"Connected via {mode} as {_auth.UserPrincipalName ?? "app"}");
    }

    public void Disconnect()
    {
        _auth.SignOut();
        _graphClient = null;
        _orchestrator = null;
        _progressRepo.AddAuditLog("disconnect");
    }

    public async Task<PermissionCheckResult> CheckPermissionsAsync(CancellationToken ct = default)
    {
        return await _auth.CheckPermissionsAsync(ct);
    }

    private void InitializeClients()
    {
        _graphClient = new GraphClient(_auth, _config.MaxThreads);
        _orchestrator = new ScanOrchestrator(_scanRepo, _itemRepo, _progressRepo, _graphClient, _auth);
    }

    // ── Config ──────────────────────────────────────────────────

    public AppConfig GetConfig() => _config;

    public void UpdateConfig(AppConfig config)
    {
        _config = config;
        _configRepo.Save(config);
    }

    public void UpdateConfig(Dictionary<string, JsonElement> updates)
    {
        foreach (var (key, value) in updates)
        {
            switch (key.ToLowerInvariant())
            {
                case "guiport": if (value.TryGetInt32(out var port)) _config.GuiPort = port; break;
                case "maxpathlength": if (value.TryGetInt32(out var mpl)) _config.MaxPathLength = mpl; break;
                case "maxpathlengthspecial": if (value.TryGetInt32(out var mpls)) _config.MaxPathLengthSpecial = mpls; break;
                case "specialextensions": _config.SpecialExtensions = value.GetString() ?? ""; break;
                case "extensionfilter": _config.ExtensionFilter = value.GetString() ?? ""; break;
                case "maxthreads": if (value.TryGetInt32(out var mt)) _config.MaxThreads = mt; break;
                case "outputformat": _config.OutputFormat = value.GetString() ?? "XLSX"; break;
            }
        }
        _configRepo.Save(_config);
    }

    // ── Scanning ────────────────────────────────────────────────

    public long StartScan(ScanRequest request)
    {
        if (_orchestrator == null) throw new InvalidOperationException("Not connected. Please connect first.");
        _progressRepo.AddAuditLog("scan_start", JsonSerializer.Serialize(request));
        return _orchestrator.StartScan(request);
    }

    public ScanProgress GetScanProgress()
    {
        return _orchestrator?.GetProgress() ?? new ScanProgress { Status = "idle" };
    }

    public void CancelScan()
    {
        _orchestrator?.CancelScan();
        _progressRepo.AddAuditLog("scan_cancel");
    }

    // ── Results ─────────────────────────────────────────────────

    public List<ScanInfo> GetScans() => _scanRepo.GetScans();

    public ScanResultsPage GetResults(long scanId, int page = 1, int pageSize = 50,
        string? siteFilter = null, string? extensionFilter = null, string? typeFilter = null,
        string? fixStatusFilter = null, string? search = null, string? sortColumn = null, string? sortDirection = null)
    {
        return _itemRepo.GetItems(scanId, page, pageSize, siteFilter, extensionFilter,
            typeFilter, fixStatusFilter, search, sortColumn, sortDirection);
    }

    public ScanSummary GetSummary(long scanId) => _itemRepo.GetSummary(scanId);

    public void DeleteScan(long scanId)
    {
        _scanRepo.DeleteScan(scanId);
        _progressRepo.AddAuditLog("scan_delete", $"Deleted scan {scanId}");
    }

    // ── Fix ─────────────────────────────────────────────────────

    public long StartFix(long scanId, FixRequest request)
    {
        if (_orchestrator == null) throw new InvalidOperationException("Not connected. Please connect first.");
        _progressRepo.AddAuditLog("fix_start", JsonSerializer.Serialize(request));
        return _orchestrator.StartFix(scanId, request);
    }

    public FixProgressResponse GetFixProgress()
    {
        var batchId = _orchestrator?.ActiveFixBatchId ?? 0;
        if (batchId == 0)
            return new FixProgressResponse { Status = "idle" };

        var batch = _progressRepo.GetFixBatch(batchId);
        if (batch == null)
            return new FixProgressResponse { Status = "idle" };

        var logs = _progressRepo.GetRecentLogs(batch.ScanId);
        var pct = batch.TotalItems > 0 ? (int)((batch.FixedItems + batch.FailedItems) * 100.0 / batch.TotalItems) : 0;

        return new FixProgressResponse
        {
            BatchId = batch.Id,
            ScanId = batch.ScanId,
            Status = batch.Status,
            Strategy = batch.Strategy,
            TotalItems = batch.TotalItems,
            FixedItems = batch.FixedItems,
            FailedItems = batch.FailedItems,
            OverallPercent = pct,
            RecentLogs = logs
        };
    }

    // ── Export ───────────────────────────────────────────────────

    public byte[] Export(long scanId, string format = "xlsx")
    {
        var items = _itemRepo.GetAllItems(scanId);
        var scan = _scanRepo.GetScan(scanId) ?? throw new InvalidOperationException("Scan not found.");
        _progressRepo.AddAuditLog("export", $"Exported scan {scanId} as {format}");

        if (format.Equals("csv", StringComparison.OrdinalIgnoreCase))
            return _excelExporter.ExportCsv(items);

        return _excelExporter.Export(items, scan);
    }

    // ── Site Discovery ──────────────────────────────────────────

    public async Task<SiteDiscoveryPage> DiscoverSitesPageAsync(
        int pageSize = 100,
        string? cursor = null,
        string? query = null,
        bool includeOneDrive = false,
        CancellationToken ct = default)
    {
        if (_graphClient == null) throw new InvalidOperationException("Not connected.");

        var boundedPageSize = Math.Clamp(pageSize, 10, 500);
        var normalizedQuery = string.IsNullOrWhiteSpace(query) ? null : query.Trim();

        var requestUrl = !string.IsNullOrWhiteSpace(cursor)
            ? cursor
            : $"sites?search={Uri.EscapeDataString(normalizedQuery ?? "*")}&$select=id,displayName,webUrl&$top={boundedPageSize}";

        var result = await _graphClient.GetAsync(requestUrl, eventualConsistency: true, ct: ct);
        var items = new List<SiteInfo>();
        if (result?.TryGetProperty("value", out var values) == true)
        {
            foreach (var site in values.EnumerateArray())
            {
                var webUrl = site.TryGetProperty("webUrl", out var wu) ? wu.GetString() ?? "" : "";
                if (string.IsNullOrEmpty(webUrl))
                    continue;

                if (!includeOneDrive && webUrl.Contains("-my.sharepoint.com", StringComparison.OrdinalIgnoreCase))
                    continue;

                var displayName = site.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "";
                if (!string.IsNullOrEmpty(normalizedQuery) &&
                    !displayName.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase) &&
                    !webUrl.Contains(normalizedQuery, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                items.Add(new SiteInfo
                {
                    Id = site.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "",
                    DisplayName = displayName,
                    WebUrl = webUrl
                });
            }
        }

        var nextCursor = result?.TryGetProperty("@odata.nextLink", out var nl) == true
            ? NormalizeGraphNextLink(nl.GetString())
            : null;

        return new SiteDiscoveryPage
        {
            Items = items,
            PageSize = boundedPageSize,
            HasMore = !string.IsNullOrEmpty(nextCursor),
            NextCursor = nextCursor,
            Query = normalizedQuery
        };
    }

    public async Task<List<SiteInfo>> DiscoverSitesAsync(CancellationToken ct = default)
    {
        if (_graphClient == null) throw new InvalidOperationException("Not connected.");

        var sites = new List<SiteInfo>();

        // Use search=* which works for both delegated and app-only auth
        await foreach (var site in _graphClient.GetPagedAsync("sites?search=*&$select=id,displayName,webUrl&$top=500", eventualConsistency: true, ct: ct))
        {
            var webUrl = site.TryGetProperty("webUrl", out var wu) ? wu.GetString() ?? "" : "";
            // Skip the root site and OneDrive personal sites
            if (string.IsNullOrEmpty(webUrl) || webUrl.Contains("-my.sharepoint.com", StringComparison.OrdinalIgnoreCase))
                continue;

            sites.Add(new SiteInfo
            {
                Id = site.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "",
                DisplayName = site.TryGetProperty("displayName", out var dn) ? dn.GetString() ?? "" : "",
                WebUrl = webUrl
            });
        }
        return sites.OrderBy(s => s.DisplayName).ToList();
    }

    private static string? NormalizeGraphNextLink(string? nextLink)
    {
        if (string.IsNullOrWhiteSpace(nextLink))
            return null;

        const string graphV1Prefix = "https://graph.microsoft.com/v1.0/";
        if (nextLink.StartsWith(graphV1Prefix, StringComparison.OrdinalIgnoreCase))
            return nextLink[graphV1Prefix.Length..];

        return nextLink;
    }

    // ── HTTP Server ─────────────────────────────────────────────

    public void StartServer(int port, string staticFilesPath, bool openBrowser = true)
    {
        _webServer?.Dispose();
        var server = new WebServer(port, staticFilesPath);
        ApiRoutes.Register(server, this);
        server.Start();
        _webServer = server;

        if (openBrowser)
        {
            try { Process.Start(new ProcessStartInfo($"http://localhost:{port}") { UseShellExecute = true }); }
            catch { }
        }
    }

    public async Task StopServerAsync()
    {
        if (_webServer != null)
            await _webServer.StopAsync();
    }

    public void Dispose()
    {
        _orchestrator?.Shutdown();
        _webServer?.Dispose();
        _db.Dispose();
    }
}

public class SiteInfo
{
    public string Id { get; set; } = "";
    public string DisplayName { get; set; } = "";
    public string WebUrl { get; set; } = "";
}

public class SiteDiscoveryPage
{
    public List<SiteInfo> Items { get; set; } = new();
    public int PageSize { get; set; }
    public bool HasMore { get; set; }
    public string? NextCursor { get; set; }
    public string? Query { get; set; }
}
