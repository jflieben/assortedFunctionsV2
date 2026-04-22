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
    private const int MaxRetries = 6;

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
            using var response = await SendWithRetryAsync(async () =>
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Get, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                if (eventualConsistency)
                    request.Headers.Add("ConsistencyLevel", "eventual");
                return request;
            }, ct);

            var json = await response.Content.ReadAsStringAsync(ct);
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
        }
        finally { _throttle.Release(); }
    }

    public async IAsyncEnumerable<JsonElement> GetPagedAsync(string url, bool eventualConsistency = false, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        string? nextLink = url;
        while (!string.IsNullOrEmpty(nextLink))
        {
            var result = await GetAsync(nextLink, eventualConsistency, ct);
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
            using var response = await SendWithRetryAsync(async () =>
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Post, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                if (body != null)
                    request.Content = new StringContent(
                        JsonSerializer.Serialize(body),
                        System.Text.Encoding.UTF8,
                        "application/json");
                return request;
            }, ct);

            var json = await response.Content.ReadAsStringAsync(ct);
            if (string.IsNullOrWhiteSpace(json)) return null;
            using var doc = JsonDocument.Parse(json);
            return (JsonElement?)doc.RootElement.Clone();
        }
        finally { _throttle.Release(); }
    }

    public async Task<JsonElement?> PatchAsync(string url, object body, CancellationToken ct = default)
    {
        await _throttle.WaitAsync(ct);
        try
        {
            using var response = await SendWithRetryAsync(async () =>
            {
                var token = await _auth.GetAccessTokenAsync("graph", ct);
                var request = new HttpRequestMessage(HttpMethod.Patch, url);
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                request.Content = new StringContent(
                    JsonSerializer.Serialize(body),
                    System.Text.Encoding.UTF8,
                    "application/json");
                return request;
            }, ct);

            var json = await response.Content.ReadAsStringAsync(ct);
            if (string.IsNullOrWhiteSpace(json)) return null;
            using var doc = JsonDocument.Parse(json);
            return (JsonElement?)doc.RootElement.Clone();
        }
        finally { _throttle.Release(); }
    }

    private async Task<HttpResponseMessage> SendWithRetryAsync(Func<Task<HttpRequestMessage>> requestFactory, CancellationToken ct)
    {
        HttpResponseMessage? response = null;
        for (int attempt = 0; attempt <= MaxRetries; attempt++)
        {
            try
            {
                using var request = await requestFactory();
                response = await _httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);

                if (response.IsSuccessStatusCode)
                    return response;

                if (!ShouldRetry(response.StatusCode) || attempt == MaxRetries)
                {
                    var errBody = await response.Content.ReadAsStringAsync(ct);
                    throw new HttpRequestException($"Graph API {response.StatusCode}: {errBody}");
                }

                var delay = GetRetryDelay(response, attempt);
                response.Dispose();
                response = null;
                await Task.Delay(delay, ct);
            }
            catch (HttpRequestException) when (attempt < MaxRetries)
            {
                var delay = GetRetryDelay(null, attempt);
                await Task.Delay(delay, ct);
            }
        }

        throw new InvalidOperationException("Unexpected retry termination in Graph request pipeline.");
    }

    private static bool ShouldRetry(HttpStatusCode statusCode)
        => statusCode == HttpStatusCode.RequestTimeout
           || statusCode == HttpStatusCode.TooManyRequests
           || statusCode == HttpStatusCode.InternalServerError
           || statusCode == HttpStatusCode.BadGateway
           || statusCode == HttpStatusCode.ServiceUnavailable
           || statusCode == HttpStatusCode.GatewayTimeout;

    private static TimeSpan GetRetryDelay(HttpResponseMessage? response, int attempt)
    {
        if (response?.Headers?.RetryAfter?.Delta is TimeSpan retryAfterDelta && retryAfterDelta > TimeSpan.Zero)
            return retryAfterDelta;

        var expSeconds = Math.Min(60, (int)Math.Pow(2, attempt + 1));
        var jitterMs = Random.Shared.Next(100, 900);
        return TimeSpan.FromSeconds(expSeconds) + TimeSpan.FromMilliseconds(jitterMs);
    }
}
