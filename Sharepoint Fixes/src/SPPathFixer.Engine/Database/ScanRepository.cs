using Microsoft.Data.Sqlite;
using SPPathFixer.Engine.Models;

namespace SPPathFixer.Engine.Database;

public class ScanRepository
{
    private readonly SqliteDb _db;

    public ScanRepository(SqliteDb db) => _db = db;

    public long CreateScan(ScanRequest request)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            INSERT INTO scans (site_filter, extension_filter, max_path_length, special_extensions, max_path_length_special)
            VALUES (@siteFilter, @extFilter, @maxPath, @specialExt, @maxPathSpecial);
            SELECT last_insert_rowid();";
        cmd.Parameters.AddWithValue("@siteFilter", request.SiteUrls != null ? string.Join(",", request.SiteUrls) : (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@extFilter", request.ExtensionFilter ?? (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@maxPath", request.MaxPathLength);
        cmd.Parameters.AddWithValue("@specialExt", request.SpecialExtensions ?? (object)DBNull.Value);
        cmd.Parameters.AddWithValue("@maxPathSpecial", request.MaxPathLengthSpecial.HasValue ? request.MaxPathLengthSpecial.Value : (object)DBNull.Value);
        return (long)cmd.ExecuteScalar()!;
    }

    public void UpdateScanStats(long scanId, int totalSites, int totalLibraries, int totalItemsScanned, int totalLongPaths)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"
            UPDATE scans SET total_sites=@ts, total_libraries=@tl, total_items_scanned=@ti, total_long_paths=@tlp
            WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", scanId);
        cmd.Parameters.AddWithValue("@ts", totalSites);
        cmd.Parameters.AddWithValue("@tl", totalLibraries);
        cmd.Parameters.AddWithValue("@ti", totalItemsScanned);
        cmd.Parameters.AddWithValue("@tlp", totalLongPaths);
        cmd.ExecuteNonQuery();
    }

    public void CompleteScan(long scanId, string status = "completed")
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "UPDATE scans SET status=@s, completed_at=datetime('now') WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", scanId);
        cmd.Parameters.AddWithValue("@s", status);
        cmd.ExecuteNonQuery();
    }

    public ScanInfo? GetScan(long scanId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM scans WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", scanId);
        using var r = cmd.ExecuteReader();
        return r.Read() ? ReadScanInfo(r) : null;
    }

    public List<ScanInfo> GetScans()
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT * FROM scans ORDER BY id DESC";
        using var r = cmd.ExecuteReader();
        var list = new List<ScanInfo>();
        while (r.Read()) list.Add(ReadScanInfo(r));
        return list;
    }

    public void DeleteScan(long scanId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM long_path_items WHERE scan_id=@id; DELETE FROM scan_progress WHERE scan_id=@id; DELETE FROM fix_batches WHERE scan_id=@id; DELETE FROM scans WHERE id=@id;";
        cmd.Parameters.AddWithValue("@id", scanId);
        cmd.ExecuteNonQuery();
    }

    private static ScanInfo ReadScanInfo(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(r.GetOrdinal("id")),
        StartedAt = r.GetString(r.GetOrdinal("started_at")),
        CompletedAt = r.IsDBNull(r.GetOrdinal("completed_at")) ? null : r.GetString(r.GetOrdinal("completed_at")),
        Status = r.GetString(r.GetOrdinal("status")),
        SiteFilter = r.IsDBNull(r.GetOrdinal("site_filter")) ? null : r.GetString(r.GetOrdinal("site_filter")),
        ExtensionFilter = r.IsDBNull(r.GetOrdinal("extension_filter")) ? null : r.GetString(r.GetOrdinal("extension_filter")),
        MaxPathLength = r.GetInt32(r.GetOrdinal("max_path_length")),
        SpecialExtensions = r.IsDBNull(r.GetOrdinal("special_extensions")) ? null : r.GetString(r.GetOrdinal("special_extensions")),
        MaxPathLengthSpecial = r.IsDBNull(r.GetOrdinal("max_path_length_special")) ? null : r.GetInt32(r.GetOrdinal("max_path_length_special")),
        TotalSites = r.GetInt32(r.GetOrdinal("total_sites")),
        TotalLibraries = r.GetInt32(r.GetOrdinal("total_libraries")),
        TotalItemsScanned = r.GetInt32(r.GetOrdinal("total_items_scanned")),
        TotalLongPaths = r.GetInt32(r.GetOrdinal("total_long_paths")),
        Notes = r.IsDBNull(r.GetOrdinal("notes")) ? null : r.GetString(r.GetOrdinal("notes"))
    };
}
