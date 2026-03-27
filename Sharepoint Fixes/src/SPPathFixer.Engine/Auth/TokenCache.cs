using System.Text.Json;

namespace SPPathFixer.Engine.Auth;

public sealed class TokenCache
{
    private readonly string _persistDir;
    private readonly Dictionary<string, TokenEntry> _tokens = new(StringComparer.OrdinalIgnoreCase);
    private string? _refreshToken;
    private DateTimeOffset? _refreshTokenExpiry;
    private readonly object _lock = new();

    public DateTimeOffset? RefreshTokenExpiry => _refreshTokenExpiry;

    public TokenCache(string persistDir)
    {
        _persistDir = persistDir;
        Load();
    }

    public void SetToken(string resource, string accessToken, DateTimeOffset expires)
    {
        lock (_lock)
        {
            _tokens[resource] = new TokenEntry { AccessToken = accessToken, Expires = expires };
            Save();
        }
    }

    public void SetRefreshToken(string token, DateTimeOffset? expiry = null)
    {
        lock (_lock)
        {
            _refreshToken = token;
            _refreshTokenExpiry = expiry ?? DateTimeOffset.UtcNow.AddDays(90);
            Save();
        }
    }

    public string? GetRefreshToken() => _refreshToken;

    public bool HasValidToken(string resource)
    {
        lock (_lock)
        {
            return _tokens.TryGetValue(resource, out var entry)
                   && entry.Expires > DateTimeOffset.UtcNow.AddMinutes(5);
        }
    }

    public string? GetAccessToken(string resource)
    {
        lock (_lock)
        {
            if (_tokens.TryGetValue(resource, out var entry) && entry.Expires > DateTimeOffset.UtcNow.AddMinutes(2))
                return entry.AccessToken;
            return null;
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _tokens.Clear();
            _refreshToken = null;
            _refreshTokenExpiry = null;
            Save();
        }
    }

    private void Save()
    {
        var data = new CacheData
        {
            Tokens = _tokens.ToDictionary(kv => kv.Key, kv => kv.Value),
            RefreshToken = _refreshToken,
            RefreshTokenExpiry = _refreshTokenExpiry?.ToString("O")
        };
        var json = JsonSerializer.Serialize(data);
        var path = Path.Combine(_persistDir, "tokens.json");
        File.WriteAllText(path, json);
    }

    private void Load()
    {
        var path = Path.Combine(_persistDir, "tokens.json");
        if (!File.Exists(path)) return;
        try
        {
            var json = File.ReadAllText(path);
            var data = JsonSerializer.Deserialize<CacheData>(json);
            if (data == null) return;
            foreach (var kv in data.Tokens) _tokens[kv.Key] = kv.Value;
            _refreshToken = data.RefreshToken;
            if (DateTimeOffset.TryParse(data.RefreshTokenExpiry, out var exp))
                _refreshTokenExpiry = exp;
        }
        catch { /* corrupt cache, ignore */ }
    }

    private class CacheData
    {
        public Dictionary<string, TokenEntry> Tokens { get; set; } = new();
        public string? RefreshToken { get; set; }
        public string? RefreshTokenExpiry { get; set; }
    }

    public class TokenEntry
    {
        public string AccessToken { get; set; } = "";
        public DateTimeOffset Expires { get; set; }
    }
}
