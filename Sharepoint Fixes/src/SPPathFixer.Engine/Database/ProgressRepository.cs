using Microsoft.Data.Sqlite;
using SPPathFixer.Engine.Models;

namespace SPPathFixer.Engine.Database;

public class ProgressRepository
{
    private readonly SqliteDb _db;

    public ProgressRepository(SqliteDb db) => _db = db;

    public void AddLog(long scanId, string message, string level = "info")
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "INSERT INTO scan_progress (scan_id, message, level) VALUES (@sid, @msg, @lvl)";
        cmd.Parameters.AddWithValue("@sid", scanId);
        cmd.Parameters.AddWithValue("@msg", message);
        cmd.Parameters.AddWithValue("@lvl", level);
        cmd.ExecuteNonQuery();
    }

    public List<LogEntry> GetRecentLogs(long scanId, int count = 50)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT timestamp, message, level FROM scan_progress WHERE scan_id=@sid ORDER BY id DESC LIMIT @cnt";
        cmd.Parameters.AddWithValue("@sid", scanId);
        cmd.Parameters.AddWithValue("@cnt", count);
        using var r = cmd.ExecuteReader();
        var logs = new List<LogEntry>();
        while (r.Read())
        {
            logs.Add(new LogEntry
            {
                Timestamp = r.GetString(0),
                Message = r.GetString(1),
                Level = r.GetString(2)
            });
        }
        logs.Reverse();
        return logs;
    }

    public void AddAuditLog(string action, string? details = null)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "INSERT INTO audit_log (action, details) VALUES (@a, @d)";
        cmd.Parameters.AddWithValue("@a", action);
        cmd.Parameters.AddWithValue("@d", details ?? (object)DBNull.Value);
        cmd.ExecuteNonQuery();
    }

    public long CreateFixBatch(long scanId, string strategy, int totalItems)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"INSERT INTO fix_batches (scan_id, strategy, total_items) VALUES (@sid, @strat, @total);
            SELECT last_insert_rowid();";
        cmd.Parameters.AddWithValue("@sid", scanId);
        cmd.Parameters.AddWithValue("@strat", strategy);
        cmd.Parameters.AddWithValue("@total", totalItems);
        return (long)cmd.ExecuteScalar()!;
    }

    public void UpdateFixBatch(long batchId, int fixedItems, int failedItems, string status)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = @"UPDATE fix_batches SET fixed_items=@fixed, failed_items=@failed, status=@s,
            completed_at=CASE WHEN @s IN ('completed','failed') THEN datetime('now') ELSE completed_at END
            WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", batchId);
        cmd.Parameters.AddWithValue("@fixed", fixedItems);
        cmd.Parameters.AddWithValue("@failed", failedItems);
        cmd.Parameters.AddWithValue("@s", status);
        cmd.ExecuteNonQuery();
    }

    public FixBatchInfo? GetFixBatch(long batchId)
    {
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT id, scan_id, strategy, started_at, completed_at, status, total_items, fixed_items, failed_items FROM fix_batches WHERE id=@id";
        cmd.Parameters.AddWithValue("@id", batchId);
        using var r = cmd.ExecuteReader();
        if (!r.Read()) return null;
        return new FixBatchInfo
        {
            Id = r.GetInt64(0),
            ScanId = r.GetInt64(1),
            Strategy = r.GetString(2),
            StartedAt = r.GetString(3),
            CompletedAt = r.IsDBNull(4) ? null : r.GetString(4),
            Status = r.GetString(5),
            TotalItems = r.GetInt32(6),
            FixedItems = r.GetInt32(7),
            FailedItems = r.GetInt32(8)
        };
    }
}
