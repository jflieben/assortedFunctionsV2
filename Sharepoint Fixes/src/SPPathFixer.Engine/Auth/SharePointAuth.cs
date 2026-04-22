using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;

namespace SPPathFixer.Engine.Auth;

public sealed class SharePointAuth
{
    // Microsoft Graph PowerShell well-known client ID (first-party, multi-tenant)
    private const string DefaultClientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e";
    private const string DefaultAuthority = "https://login.microsoftonline.com";
    private const string SharePointScope = "Sites.Read.All Sites.ReadWrite.All User.Read offline_access openid profile";

    private readonly TokenCache _tokenCache;
    private readonly HttpClient _httpClient = new();

    private string _clientId = DefaultClientId;
    private string? _tenantId;
    private string? _tenantDomain;
    private string? _userPrincipalName;
    private string _authMode = "None"; // None, Delegated, Certificate

    // Certificate-based auth fields
    private X509Certificate2? _certificate;
    private string? _certClientId;
    private string? _certTenantId;

    // A session is considered connected only after auth mode has been established.
    // This avoids transient UI states like "Connected ... (None)" during startup restore.
    public bool IsConnected => !string.Equals(_authMode, "None", StringComparison.OrdinalIgnoreCase);
    public string? TenantId => _tenantId;
    public string? TenantDomain => _tenantDomain;
    public string? UserPrincipalName => _userPrincipalName;
    public string AuthMode => _authMode;
    public DateTimeOffset? RefreshTokenExpiry => _tokenCache.RefreshTokenExpiry;

    public SharePointAuth(TokenCache tokenCache) => _tokenCache = tokenCache;

    // ── Delegated Auth (PKCE browser flow) ──────────────────────

    public async Task AuthenticateDelegatedAsync(string? clientId = null, CancellationToken ct = default)
    {
        _clientId = clientId ?? DefaultClientId;
        var codeVerifier = GenerateCodeVerifier();
        var codeChallenge = GenerateCodeChallenge(codeVerifier);

        var listener = new HttpListener();
        const int redirectPort = 1986;
        var redirectUri = $"http://localhost:{redirectPort}/";
        listener.Prefixes.Add(redirectUri);
        listener.Start();

        try
        {
            var authUrl = $"{DefaultAuthority}/common/oauth2/v2.0/authorize" +
                $"?client_id={Uri.EscapeDataString(_clientId)}" +
                $"&response_type=code" +
                $"&redirect_uri={Uri.EscapeDataString(redirectUri)}" +
                $"&response_mode=query" +
                $"&scope={Uri.EscapeDataString(SharePointScope)}" +
                $"&code_challenge={codeChallenge}" +
                $"&code_challenge_method=S256";

            OpenBrowser(authUrl);

            var context = await listener.GetContextAsync().WaitAsync(TimeSpan.FromMinutes(5), ct);
            var code = context.Request.QueryString["code"];
            var error = context.Request.QueryString["error"];

            var responseHtml = code != null
                ? "<html><body><h2>Authentication successful!</h2><p>You can close this window.</p><script>window.close()</script></body></html>"
                : $"<html><body><h2>Authentication failed</h2><p>{error}</p></body></html>";
            var buffer = Encoding.UTF8.GetBytes(responseHtml);
            context.Response.ContentType = "text/html";
            context.Response.ContentLength64 = buffer.Length;
            await context.Response.OutputStream.WriteAsync(buffer, ct);
            context.Response.Close();

            if (string.IsNullOrEmpty(code))
                throw new InvalidOperationException($"Authentication failed: {error}");

            await ExchangeCodeForTokens(code, redirectUri, codeVerifier, ct);
            await DiscoverTenantInfoAsync(ct);
            _authMode = "Delegated";
        }
        finally { listener.Stop(); listener.Close(); }
    }

    // ── Certificate-based Auth ──────────────────────────────────

    public async Task AuthenticateCertificateAsync(string clientId, string tenantId,
        string? pfxPath = null, string? pfxPassword = null, string? thumbprint = null,
        CancellationToken ct = default)
    {
        _certClientId = clientId;
        _certTenantId = tenantId;

        if (!string.IsNullOrEmpty(thumbprint))
        {
            using var store = new X509Store(StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadOnly);
            var found = store.Certificates.Find(X509FindType.FindByThumbprint, thumbprint, false);
            if (found.Count == 0)
            {
                store.Close();
                using var machineStore = new X509Store(StoreLocation.LocalMachine);
                machineStore.Open(OpenFlags.ReadOnly);
                found = machineStore.Certificates.Find(X509FindType.FindByThumbprint, thumbprint, false);
                if (found.Count == 0)
                    throw new InvalidOperationException($"Certificate with thumbprint {thumbprint} not found in any store.");
            }
            _certificate = found[0];
        }
        else if (!string.IsNullOrEmpty(pfxPath))
        {
            _certificate = string.IsNullOrEmpty(pfxPassword)
                ? new X509Certificate2(pfxPath)
                : new X509Certificate2(pfxPath, pfxPassword, X509KeyStorageFlags.MachineKeySet);
        }
        else
        {
            throw new ArgumentException("Either pfxPath or thumbprint must be provided for certificate auth.");
        }

        await AcquireCertificateTokenAsync(ct);
        await DiscoverTenantInfoAsync(ct);
        _authMode = "Certificate";
        _clientId = clientId;
    }

    private async Task AcquireCertificateTokenAsync(CancellationToken ct)
    {
        if (_certificate == null || _certClientId == null || _certTenantId == null)
            throw new InvalidOperationException("Certificate not configured.");

        var assertion = BuildClientAssertion(_certClientId, _certTenantId, _certificate);

        var tokenUrl = $"{DefaultAuthority}/{_certTenantId}/oauth2/v2.0/token";
        var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = _certClientId,
            ["scope"] = "https://graph.microsoft.com/.default",
            ["client_assertion_type"] = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            ["client_assertion"] = assertion,
            ["grant_type"] = "client_credentials"
        });

        var response = await _httpClient.PostAsync(tokenUrl, content, ct);
        var json = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Token request failed: {json}");

        using var doc = JsonDocument.Parse(json);
        var accessToken = doc.RootElement.GetProperty("access_token").GetString()!;
        var expiresIn = doc.RootElement.GetProperty("expires_in").GetInt32();

        _tokenCache.SetToken("graph", accessToken, DateTimeOffset.UtcNow.AddSeconds(expiresIn));
    }

    private static string BuildClientAssertion(string clientId, string tenantId, X509Certificate2 cert)
    {
        var header = Base64Url(JsonSerializer.SerializeToUtf8Bytes(new
        {
            alg = "RS256",
            typ = "JWT",
            x5t = Base64UrlEncode(cert.GetCertHash())
        }));

        var now = DateTimeOffset.UtcNow;
        var payload = Base64Url(JsonSerializer.SerializeToUtf8Bytes(new
        {
            aud = $"https://login.microsoftonline.com/{tenantId}/oauth2/v2.0/token",
            iss = clientId,
            sub = clientId,
            jti = Guid.NewGuid().ToString(),
            nbf = now.ToUnixTimeSeconds(),
            exp = now.AddMinutes(10).ToUnixTimeSeconds()
        }));

        var dataToSign = Encoding.UTF8.GetBytes($"{header}.{payload}");
        using var rsa = cert.GetRSAPrivateKey()
            ?? throw new InvalidOperationException("Certificate does not have a private key.");
        var signature = rsa.SignData(dataToSign, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

        return $"{header}.{payload}.{Base64UrlEncode(signature)}";
    }

    // ── Token Refresh ───────────────────────────────────────────

    public async Task<string> GetAccessTokenAsync(string resource = "graph", CancellationToken ct = default)
    {
        var cached = _tokenCache.GetAccessToken(resource);
        if (cached != null) return cached;

        if (_authMode == "Certificate")
        {
            await AcquireCertificateTokenAsync(ct);
            return _tokenCache.GetAccessToken(resource)
                ?? throw new InvalidOperationException("Failed to acquire certificate token.");
        }

        // Delegated - use refresh token
        var refreshToken = _tokenCache.GetRefreshToken();
        if (refreshToken == null)
            throw new InvalidOperationException("No refresh token available. Please re-authenticate.");

        var scope = resource switch
        {
            "sharepoint" => "https://graph.microsoft.com/.default offline_access",
            _ => SharePointScope
        };

        var tokenUrl = $"{DefaultAuthority}/common/oauth2/v2.0/token";
        var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = _clientId,
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
            ["scope"] = scope
        });

        var response = await _httpClient.PostAsync(tokenUrl, content, ct);
        var json = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Token refresh failed: {json}");

        using var doc = JsonDocument.Parse(json);
        var accessToken = doc.RootElement.GetProperty("access_token").GetString()!;
        var expiresIn = doc.RootElement.GetProperty("expires_in").GetInt32();
        _tokenCache.SetToken(resource, accessToken, DateTimeOffset.UtcNow.AddSeconds(expiresIn));

        if (doc.RootElement.TryGetProperty("refresh_token", out var rt))
            _tokenCache.SetRefreshToken(rt.GetString()!);

        return accessToken;
    }

    public async Task<bool> TryRestoreSessionAsync()
    {
        if (_tokenCache.HasValidToken("graph"))
        {
            try { await DiscoverTenantInfoAsync(); } catch { /* best effort */ }
            _authMode = "Delegated";
            return true;
        }
        if (_tokenCache.GetRefreshToken() == null) return false;
        try
        {
            await GetAccessTokenAsync("graph");
            await DiscoverTenantInfoAsync();
            _authMode = "Delegated";
            return true;
        }
        catch { return false; }
    }

    public void SignOut()
    {
        _tokenCache.Clear();
        _certificate = null;
        _certClientId = null;
        _certTenantId = null;
        _tenantId = null;
        _tenantDomain = null;
        _userPrincipalName = null;
        _authMode = "None";
    }

    // ── Permission Checking ─────────────────────────────────────

    public async Task<Models.PermissionCheckResult> CheckPermissionsAsync(CancellationToken ct = default)
    {
        var result = new Models.PermissionCheckResult { AuthMode = _authMode };
        var granted = new List<string>();
        var missing = new List<string>();

        try
        {
            var token = await GetAccessTokenAsync("graph", ct);
            var request = new HttpRequestMessage(HttpMethod.Get, "https://graph.microsoft.com/v1.0/me");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            var response = await _httpClient.SendAsync(request, ct);

            if (response.IsSuccessStatusCode)
                granted.Add("User.Read");
            else
                missing.Add("User.Read");
        }
        catch { missing.Add("User.Read (could not validate)"); }

        try
        {
            var token = await GetAccessTokenAsync("graph", ct);
            var request = new HttpRequestMessage(HttpMethod.Get, "https://graph.microsoft.com/v1.0/sites/root");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            var response = await _httpClient.SendAsync(request, ct);

            if (response.IsSuccessStatusCode)
                granted.Add("Sites.Read.All");
            else
                missing.Add("Sites.Read.All");
        }
        catch { missing.Add("Sites.Read.All (could not validate)"); }

        if (_authMode == "Certificate")
        {
            result.Guidance = missing.Count > 0
                ? $"The app registration ({_certClientId}) needs API permissions: Sites.ReadWrite.All (Application). " +
                  "Go to Entra ID → App registrations → API permissions → Add → Microsoft Graph → Application → Sites.ReadWrite.All → Grant admin consent."
                : "All required permissions are granted.";
        }
        else
        {
            result.Guidance = missing.Count > 0
                ? "Delegated auth requires: Sites.Read.All, Sites.ReadWrite.All (to apply fixes). " +
                  "If your admin hasn't consented, ask them to visit: " +
                  $"https://login.microsoftonline.com/{_tenantId ?? "common"}/adminconsent?client_id={_clientId}"
                : "All required permissions are granted. To apply fixes, Sites.ReadWrite.All is also needed.";
        }

        result.HasRequiredPermissions = missing.Count == 0;
        result.GrantedPermissions = granted.ToArray();
        result.MissingPermissions = missing.ToArray();
        return result;
    }

    // ── Helpers ──────────────────────────────────────────────────

    private async Task ExchangeCodeForTokens(string code, string redirectUri, string codeVerifier, CancellationToken ct)
    {
        var tokenUrl = $"{DefaultAuthority}/common/oauth2/v2.0/token";
        var content = new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = _clientId,
            ["grant_type"] = "authorization_code",
            ["code"] = code,
            ["redirect_uri"] = redirectUri,
            ["code_verifier"] = codeVerifier,
            ["scope"] = SharePointScope
        });

        var response = await _httpClient.PostAsync(tokenUrl, content, ct);
        var json = await response.Content.ReadAsStringAsync(ct);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Token exchange failed: {json}");

        using var doc = JsonDocument.Parse(json);
        var accessToken = doc.RootElement.GetProperty("access_token").GetString()!;
        var expiresIn = doc.RootElement.GetProperty("expires_in").GetInt32();
        _tokenCache.SetToken("graph", accessToken, DateTimeOffset.UtcNow.AddSeconds(expiresIn));

        if (doc.RootElement.TryGetProperty("refresh_token", out var rt))
            _tokenCache.SetRefreshToken(rt.GetString()!);
    }

    private async Task DiscoverTenantInfoAsync(CancellationToken ct = default)
    {
        try
        {
            var token = await GetAccessTokenAsync("graph", ct);
            var request = new HttpRequestMessage(HttpMethod.Get, "https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains");
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            var response = await _httpClient.SendAsync(request, ct);
            if (!response.IsSuccessStatusCode) return;

            var json = await response.Content.ReadAsStringAsync(ct);
            using var doc = JsonDocument.Parse(json);
            var orgs = doc.RootElement.GetProperty("value");
            if (orgs.GetArrayLength() > 0)
            {
                var org = orgs[0];
                _tenantId = org.GetProperty("id").GetString();
                var domains = org.GetProperty("verifiedDomains");
                foreach (var d in domains.EnumerateArray())
                {
                    if (d.TryGetProperty("isDefault", out var isDefault) && isDefault.GetBoolean())
                    {
                        _tenantDomain = d.GetProperty("name").GetString();
                        break;
                    }
                }
            }
        }
        catch { /* best effort */ }

        if (_authMode != "Certificate")
        {
            try
            {
                var token = await GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Get, "https://graph.microsoft.com/v1.0/me?$select=userPrincipalName");
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
                var response = await _httpClient.SendAsync(request, ct);
                if (response.IsSuccessStatusCode)
                {
                    var json = await response.Content.ReadAsStringAsync(ct);
                    using var doc = JsonDocument.Parse(json);
                    _userPrincipalName = doc.RootElement.GetProperty("userPrincipalName").GetString();
                }
            }
            catch { /* best effort */ }
        }
    }

    private static string GenerateCodeVerifier()
    {
        var bytes = new byte[32];
        RandomNumberGenerator.Fill(bytes);
        return Base64UrlEncode(bytes);
    }

    private static string GenerateCodeChallenge(string verifier)
    {
        var hash = SHA256.HashData(Encoding.ASCII.GetBytes(verifier));
        return Base64UrlEncode(hash);
    }

    private static string Base64UrlEncode(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static string Base64Url(byte[] bytes) => Base64UrlEncode(bytes);

    private static void OpenBrowser(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }
}
