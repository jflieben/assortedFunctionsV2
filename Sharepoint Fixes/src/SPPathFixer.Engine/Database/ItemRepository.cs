using Microsoft.Data.Sqlite;
using SPPathFixer.Engine.Models;

namespace SPPathFixer.Engine.Database;

public class ItemRepository
{
    private readonly SqliteDb _db;

    public ItemRepository(SqliteDb db) => _db = db;

    public void InsertItems(IEnumerable<LongPathItem> items)
    {
        using var conn = _db.CreateConnection();
        using var tx = conn.BeginTransaction();
        using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
            INSERT INTO long_path_items (scan_id, site_url, library_title, library_server_relative_url,
                item_id, item_unique_id, item_name, item_extension, item_type, file_ref, full_url,
                path_total_length, path_parent_length, path_leaf_length, max_allowed, delta, deepest_child_depth)
            VALUES (@scanId, @siteUrl, @libTitle, @libSru, @itemId, @itemUid, @itemName, @itemExt,
                @itemType, @fileRef, @fullUrl, @ptl, @ppl, @pll, @maxA, @delta, @dcd)";

        var pScanId = cmd.Parameters.Add("@scanId", SqliteType.Integer);
        var pSiteUrl = cmd.Parameters.Add("@siteUrl", SqliteType.Text);
        var pLibTitle = cmd.Parameters.Add("@libTitle", SqliteType.Text);
        var pLibSru = cmd.Parameters.Add("@libSru", SqliteType.Text);
        var pItemId = cmd.Parameters.Add("@itemId", SqliteType.Text);
        var pItemUid = cmd.Parameters.Add("@itemUid", SqliteType.Text);
        var pItemName = cmd.Parameters.Add("@itemName", SqliteType.Text);
        var pItemExt = cmd.Parameters.Add("@itemExt", SqliteType.Text);
        var pItemType = cmd.Parameters.Add("@itemType", SqliteType.Text);
        var pFileRef = cmd.Parameters.Add("@fileRef", SqliteType.Text);
        var pFullUrl = cmd.Parameters.Add("@fullUrl", SqliteType.Text);
        var pPtl = cmd.Parameters.Add("@ptl", SqliteType.Integer);
        var pPpl = cmd.Parameters.Add("@ppl", SqliteType.Integer);
        var pPll = cmd.Parameters.Add("@pll", SqliteType.Integer);
        var pMaxA = cmd.Parameters.Add("@maxA", SqliteType.Integer);
        var pDelta = cmd.Parameters.Add("@delta", SqliteType.Integer);
        var pDcd = cmd.Parameters.Add("@dcd", SqliteType.Integer);

        foreach (var item in items)
        {
            pScanId.Value = item.ScanId;
            pSiteUrl.Value = item.SiteUrl;
            pLibTitle.Value = item.LibraryTitle;
            pLibSru.Value = item.LibraryServerRelativeUrl;
            pItemId.Value = item.ItemId;
            pItemUid.Value = item.ItemUniqueId;
            pItemName.Value = item.ItemName;
            pItemExt.Value = item.ItemExtension;
            pItemType.Value = item.ItemType;
            pFileRef.Value = item.FileRef;
            pFullUrl.Value = item.FullUrl;
            pPtl.Value = item.PathTotalLength;
            pPpl.Value = item.PathParentLength;
            pPll.Value = item.PathLeafLength;
            pMaxA.Value = item.MaxAllowed;
            pDelta.Value = item.Delta;
            pDcd.Value = item.DeepestChildDepth;
            cmd.ExecuteNonQuery();
        }
        tx.Commit();
    }

    public ScanResultsPage GetItems(long scanId, int page = 1, int pageSize = 50, string? siteFilter = null,
        string? extensionFilter = null, string? typeFilter = null, string? fixStatusFilter = null,
        string? search = null, string? sortColumn = null, string? sortDirection = null)
    {
        using var conn = _db.CreateConnection();

        var where = "WHERE scan_id=@scanId";
        var parameters = new List<SqliteParameter> { new("@scanId", scanId) };

        if (!string.IsNullOrEmpty(siteFilter))
        {
            where += " AND site_url=@siteFilter";
            parameters.Add(new("@siteFilter", siteFilter));
        }
        if (!string.IsNullOrEmpty(extensionFilter))
        {
            where += " AND item_extension=@extFilter";
            parameters.Add(new("@extFilter", extensionFilter));
        }
        if (!string.IsNullOrEmpty(typeFilter))
        {
            where += " AND item_type=@typeFilter";
            parameters.Add(new("@typeFilter", typeFilter));
        }
        if (!string.IsNullOrEmpty(fixStatusFilter))
        {
            where += " AND fix_status=@fixFilter";
            parameters.Add(new("@fixFilter", fixStatusFilter));
        }
        if (!string.IsNullOrEmpty(search))
        {
            where += " AND (item_name LIKE @search OR full_url LIKE @search)";
            parameters.Add(new("@search", $"%{search}%"));
        }

        // Count
        using var countCmd = conn.CreateCommand();
        countCmd.CommandText = $"SELECT COUNT(*) FROM long_path_items {where}";
        foreach (var p in parameters) countCmd.Parameters.Add(new(p.ParameterName, p.Value));
        var totalCount = Convert.ToInt32(countCmd.ExecuteScalar());

        // Validate sort column to prevent injection
        var validSortColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "item_name", "path_total_length", "delta", "item_type", "item_extension",
            "site_url", "fix_status", "deepest_child_depth", "path_leaf_length", "full_url"
        };
        var orderBy = "ORDER BY delta ASC, path_total_length DESC";
        if (!string.IsNullOrEmpty(sortColumn) && validSortColumns.Contains(sortColumn))
        {
            var dir = sortDirection?.Equals("desc", StringComparison.OrdinalIgnoreCase) == true ? "DESC" : "ASC";
            orderBy = $"ORDER BY {sortColumn} {dir}";
        }

        // Query
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT * FROM long_path_items {where} {orderBy} LIMIT @limit OFFSET @offset";
        foreach (var p in parameters) cmd.Parameters.Add(new(p.ParameterName, p.Value));
        cmd.Parameters.AddWithValue("@limit", pageSize);
        cmd.Parameters.AddWithValue("@offset", (page - 1) * pageSize);

        using var r = cmd.ExecuteReader();
        var items = new List<LongPathItem>();
        while (r.Read()) items.Add(ReadItem(r));

        return new ScanResultsPage
        {
            Items = items,
            TotalCount = totalCount,
            Page = page,
            PageSize = pageSize,
            TotalPages = (int)Math.Ceiling(totalCount / (double)pageSize)
        };
    }

    public List<LongPathItem> GetItemsByIds(long scanId, long[] itemIds)
    {
        if (itemIds.Length == 0) return new();
        using var conn = _db.CreateConnection();
        var idList = string.Join(",", itemIds);
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT * FROM long_path_items WHERE scan_id=@scanId AND id IN ({idList})";
        cmd.Parameters.AddWithValue("@scanId", scanId);
        using var r = cmd.ExecuteReader();
        var items = new List<LongPathItem>();
        while (r.Read()) items.Add(ReadItem(r));
        return items;
    }

    public List<LongPathItem> GetAllItems(long scanId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM long_path_items WHERE scan_id=@scanId ORDER BY delta ASC";
        cmd.Parameters.AddWithValue("@scanId", scanId);
        using var r = cmd.ExecuteReader();
        var items = new List<LongPathItem>();
        while (r.Read()) items.Add(ReadItem(r));
        return items;
    }

    public void UpdateFixStatus(long itemId, string status, string? newName = null, string? result = null, string? strategy = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            UPDATE long_path_items SET fix_status=@status, fix_new_name=@newName, fix_result=@result,
                fix_strategy=@strategy, fix_applied_at=datetime('now')
            WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", itemId);
        cmd.Parameters.AddWithValue("@status", status);
        cmd.Parameters.AddWithValue("@newName", newName ?? (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@result", result ?? (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@strategy", strategy ?? (object)DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    public ScanSummary GetSummary(long scanId)
    {
        using var conn = _db.CreateConnection();
        var summary = new ScanSummary();

        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM long_path_items WHERE scan_id=@id";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.TotalItems = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM long_path_items WHERE scan_id=@id AND item_type='File'";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.FileCount = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM long_path_items WHERE scan_id=@id AND item_type='Folder'";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.FolderCount = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM long_path_items WHERE scan_id=@id AND delta < -50";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.CriticalCount = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM long_path_items WHERE scan_id=@id AND delta >= -50 AND delta < 0";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.WarningCount = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COALESCE(AVG(path_total_length), 0) FROM long_path_items WHERE scan_id=@id";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.AvgPathLength = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COALESCE(MAX(path_total_length), 0) FROM long_path_items WHERE scan_id=@id";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.MaxPathLengthFound = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM long_path_items WHERE scan_id=@id AND fix_status='fixed'";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.FixedCount = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(DISTINCT site_url) FROM long_path_items WHERE scan_id=@id";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.UniqueSites = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(DISTINCT item_extension) FROM long_path_items WHERE scan_id=@id AND item_type='File'";
            cmd.Parameters.AddWithValue("@id", scanId);
            summary.UniqueExtensions = Convert.ToInt32(cmd.ExecuteScalar());
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT site_url, COUNT(*) as cnt FROM long_path_items WHERE scan_id=@id GROUP BY site_url ORDER BY cnt DESC";
            cmd.Parameters.AddWithValue("@id", scanId);
            using var r = cmd.ExecuteReader();
            while (r.Read()) summary.BySite[r.GetString(0)] = r.GetInt32(1);
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT item_extension, COUNT(*) as cnt FROM long_path_items WHERE scan_id=@id AND item_type='File' GROUP BY item_extension ORDER BY cnt DESC";
            cmd.Parameters.AddWithValue("@id", scanId);
            using var r = cmd.ExecuteReader();
            while (r.Read()) summary.ByExtension[r.GetString(0)] = r.GetInt32(1);
        }
        using (var cmd = conn.CreateCommand())
        {
            cmd.CommandText = "SELECT fix_status, COUNT(*) as cnt FROM long_path_items WHERE scan_id=@id GROUP BY fix_status ORDER BY cnt DESC";
            cmd.Parameters.AddWithValue("@id", scanId);
            using var r = cmd.ExecuteReader();
            while (r.Read()) summary.ByFixStatus[r.GetString(0)] = r.GetInt32(1);
        }
        return summary;
    }

    private static LongPathItem ReadItem(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(r.GetOrdinal("id")),
        ScanId = r.GetInt64(r.GetOrdinal("scan_id")),
        SiteUrl = r.GetString(r.GetOrdinal("site_url")),
        LibraryTitle = r.GetString(r.GetOrdinal("library_title")),
        LibraryServerRelativeUrl = r.GetString(r.GetOrdinal("library_server_relative_url")),
        ItemId = r.GetString(r.GetOrdinal("item_id")),
        ItemUniqueId = r.GetString(r.GetOrdinal("item_unique_id")),
        ItemName = r.GetString(r.GetOrdinal("item_name")),
        ItemExtension = r.GetString(r.GetOrdinal("item_extension")),
        ItemType = r.GetString(r.GetOrdinal("item_type")),
        FileRef = r.GetString(r.GetOrdinal("file_ref")),
        FullUrl = r.GetString(r.GetOrdinal("full_url")),
        PathTotalLength = r.GetInt32(r.GetOrdinal("path_total_length")),
        PathParentLength = r.GetInt32(r.GetOrdinal("path_parent_length")),
        PathLeafLength = r.GetInt32(r.GetOrdinal("path_leaf_length")),
        MaxAllowed = r.GetInt32(r.GetOrdinal("max_allowed")),
        Delta = r.GetInt32(r.GetOrdinal("delta")),
        DeepestChildDepth = r.GetInt32(r.GetOrdinal("deepest_child_depth")),
        FixStatus = r.GetString(r.GetOrdinal("fix_status")),
        FixStrategy = r.IsDBNull(r.GetOrdinal("fix_strategy")) ? null : r.GetString(r.GetOrdinal("fix_strategy")),
        FixNewName = r.IsDBNull(r.GetOrdinal("fix_new_name")) ? null : r.GetString(r.GetOrdinal("fix_new_name")),
        FixResult = r.IsDBNull(r.GetOrdinal("fix_result")) ? null : r.GetString(r.GetOrdinal("fix_result")),
        FixAppliedAt = r.IsDBNull(r.GetOrdinal("fix_applied_at")) ? null : r.GetString(r.GetOrdinal("fix_applied_at"))
    };
}
