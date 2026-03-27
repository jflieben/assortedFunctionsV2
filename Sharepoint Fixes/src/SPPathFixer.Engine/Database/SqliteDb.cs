using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Data.Sqlite;

namespace SPPathFixer.Engine.Database;

public sealed class SqliteDb : IDisposable
{
    private readonly string _connectionString;
    private readonly string _databasePath;
    private bool _initialized;
    private static bool _nativeInitialized;

    public string DatabasePath => _databasePath;

    public SqliteDb(string databasePath)
    {
        if (!_nativeInitialized)
        {
            _nativeInitialized = true;
            var providerAssembly = typeof(SQLitePCL.SQLite3Provider_e_sqlite3).Assembly;
            NativeLibrary.SetDllImportResolver(providerAssembly, ResolveNativeLibrary);
            SQLitePCL.Batteries_V2.Init();
        }

        _databasePath = databasePath;
        var dir = Path.GetDirectoryName(databasePath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);

        _connectionString = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared
        }.ToString();
    }

    public SqliteConnection CreateConnection()
    {
        var conn = new SqliteConnection(_connectionString);
        conn.Open();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;";
        cmd.ExecuteNonQuery();
        return conn;
    }

    public void Initialize()
    {
        if (_initialized) return;

        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = "SPPathFixer.Engine.Database.Schema.sql";

        using var stream = assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded resource '{resourceName}' not found.");
        using var reader = new StreamReader(stream);
        var sql = reader.ReadToEnd();

        using var conn = CreateConnection();
        using var cmd = conn.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();

        _initialized = true;
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
    }

    private static IntPtr ResolveNativeLibrary(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!libraryName.Contains("e_sqlite3")) return IntPtr.Zero;

        var assemblyDir = Path.GetDirectoryName(assembly.Location) ?? ".";
        string rid;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            rid = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
            rid = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "linux-arm64" : "linux-x64";
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            rid = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "osx-arm64" : "osx-x64";
        else
            return IntPtr.Zero;

        var nativePath = Path.Combine(assemblyDir, "runtimes", rid, "native", libraryName);
        if (!Path.HasExtension(nativePath))
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) nativePath += ".dll";
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) nativePath += ".dylib";
            else nativePath += ".so";
        }

        if (NativeLibrary.TryLoad(nativePath, out var handle)) return handle;

        // Fallback: try without runtimes subfolder
        var fallback = Path.Combine(assemblyDir, Path.GetFileName(nativePath));
        if (NativeLibrary.TryLoad(fallback, out handle)) return handle;

        return IntPtr.Zero;
    }
}
