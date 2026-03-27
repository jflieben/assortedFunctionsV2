using Microsoft.Data.Sqlite;
using SPPathFixer.Engine.Models;

namespace SPPathFixer.Engine.Database;

public class ConfigRepository
{
    private readonly SqliteDb _db;

    public ConfigRepository(SqliteDb db) => _db = db;

    public AppConfig Load()
    {
        var config = new AppConfig();
        using var conn = _db.CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT key, value FROM config";
        using var r = cmd.ExecuteReader();
        while (r.Read())
        {
            var key = r.GetString(0);
            var val = r.GetString(1);
            switch (key)
            {
                case "GuiPort": if (int.TryParse(val, out var p)) config.GuiPort = p; break;
                case "MaxPathLength": if (int.TryParse(val, out var m)) config.MaxPathLength = m; break;
                case "MaxPathLengthSpecial": if (int.TryParse(val, out var ms)) config.MaxPathLengthSpecial = ms; break;
                case "SpecialExtensions": config.SpecialExtensions = val; break;
                case "ExtensionFilter": config.ExtensionFilter = val; break;
                case "MaxThreads": if (int.TryParse(val, out var mt)) config.MaxThreads = mt; break;
                case "OutputFormat": config.OutputFormat = val; break;
            }
        }
        return config;
    }

    public void Save(AppConfig config)
    {
        using var conn = _db.CreateConnection();
        using var tx = conn.BeginTransaction();

        void Upsert(string key, string value)
        {
            using var cmd = conn.CreateCommand();
            cmd.Transaction = tx;
            cmd.CommandText = "INSERT INTO config (key, value) VALUES (@k, @v) ON CONFLICT(key) DO UPDATE SET value=@v";
            cmd.Parameters.AddWithValue("@k", key);
            cmd.Parameters.AddWithValue("@v", value);
            cmd.ExecuteNonQuery();
        }

        Upsert("GuiPort", config.GuiPort.ToString());
        Upsert("MaxPathLength", config.MaxPathLength.ToString());
        Upsert("MaxPathLengthSpecial", config.MaxPathLengthSpecial.ToString());
        Upsert("SpecialExtensions", config.SpecialExtensions);
        Upsert("ExtensionFilter", config.ExtensionFilter);
        Upsert("MaxThreads", config.MaxThreads.ToString());
        Upsert("OutputFormat", config.OutputFormat);

        tx.Commit();
    }
}
