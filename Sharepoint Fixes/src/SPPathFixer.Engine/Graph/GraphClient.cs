using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using SPPathFixer.Engine.Auth;

namespace SPPathFixer.Engine.Graph;

public sealed class GraphClient
{
    private readonly SharePointAuth _auth;
    private readonly HttpClient _httpClient;
    private readonly SemaphoreSlim _throttle;
    private const string GraphBaseUrl = "https://graph.microsoft.com/v1.0/";

    public GraphClient(SharePointAuth auth, int maxConcurrency = 3)
    {
        _auth = auth;
        _httpClient = new HttpClient { BaseAddress = new Uri(GraphBaseUrl) };
        _throttle = new SemaphoreSlim(maxConcurrency, maxConcurrency);
    }

    public async Task<JsonElement?> GetAsync(string url, bool eventualConsistency = false, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct);
        try
        {
            return await ExecuteWithRetry(async () =>
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                if (eventualConsistency)
                    request.Headers.Add("ConsistencyLevel", "eventual");

                var response = await _httpClient.SendAsync(request, ct);

                if (response.StatusCode == HttpStatusCode.TooManyRequests)
                {
                    var retryAfter = response.Headers.RetryAfter?.Delta?.TotalSeconds ?? 10;
                    await Task.Delay(TimeSpan.FromSeconds(retryAfter), ct);
                    throw new HttpRequestException("Throttled (429)");
                }

                if (!response.IsSuccessStatusCode)
                {
                    var errBody = await response.Content.ReadAsStringAsync(ct);
                    throw new HttpRequestException($"Graph API {response.StatusCode}: {errBody}");
                }

                var json = await response.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(json);
                return doc.RootElement.Clone();
            }, ct);
        }
        finally { _throttle.Release(); }
    }

    public async IAsyncEnumerable<JsonElement> GetPagedAsync(string url, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        string? nextLink = url;
        while (!string.IsNullOrEmpty(nextLink))
        {
            var result = await GetAsync(nextLink, ct: ct);
            if (result == null) yield break;

            if (result.Value.TryGetProperty("value", out var values))
            {
                foreach (var item in values.EnumerateArray())
                    yield return item.Clone();
            }

            nextLink = result.Value.TryGetProperty("@odata.nextLink", out var nl) ? nl.GetString() : null;
            // Strip base URL from nextLink if present so we pass relative paths
            if (nextLink?.StartsWith(GraphBaseUrl) == true)
                nextLink = nextLink[GraphBaseUrl.Length..];
        }
    }

    public async Task<JsonElement?> PostAsync(string url, object? body = null, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct);
        try
        {
            return await ExecuteWithRetry(async () =>
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Post, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                if (body != null)
                    request.Content = new StringContent(
                        JsonSerializer.Serialize(body),
                        System.Text.Encoding.UTF8,
                        "application/json");

                var response = await _httpClient.SendAsync(request, ct);
                if (!response.IsSuccessStatusCode)
                {
                    var errBody = await response.Content.ReadAsStringAsync(ct);
                    throw new HttpRequestException($"Graph API {response.StatusCode}: {errBody}");
                }

                var json = await response.Content.ReadAsStringAsync(ct);
                if (string.IsNullOrWhiteSpace(json)) return null;
                using var doc = JsonDocument.Parse(json);
                return (JsonElement?)doc.RootElement.Clone();
            }, ct);
        }
        finally { _throttle.Release(); }
    }

    public async Task<JsonElement?> PatchAsync(string url, object body, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct);
        try
        {
            return await ExecuteWithRetry(async () =>
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Patch, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                request.Content = new StringContent(
                    JsonSerializer.Serialize(body),
                    System.Text.Encoding.UTF8,
                    "application/json");

                var response = await _httpClient.SendAsync(request, ct);
                if (!response.IsSuccessStatusCode)
                {
                    var errBody = await response.Content.ReadAsStringAsync(ct);
                    throw new HttpRequestException($"Graph API {response.StatusCode}: {errBody}");
                }

                var json = await response.Content.ReadAsStringAsync(ct);
                if (string.IsNullOrWhiteSpace(json)) return null;
                using var doc = JsonDocument.Parse(json);
                return (JsonElement?)doc.RootElement.Clone();
            }, ct);
        }
        finally { _throttle.Release(); }
    }

    private static async Task<T> ExecuteWithRetry<T>(Func<Task<T>> action, CancellationToken ct, int maxRetries = 3)
    {
        for (int attempt = 0; ; attempt++)
        {
            try { return await action(); }
            catch (HttpRequestException) when (attempt < maxRetries)
            {
                var delay = Math.Pow(2, attempt + 1);
                await Task.Delay(TimeSpan.FromSeconds(delay), ct);
            }
        }
    }
}
