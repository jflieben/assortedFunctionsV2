using System.Net;
using System.Text;
using System.Text.Json;

namespace SPPathFixer.Engine.Http;

public sealed class WebServer : IDisposable
{
    private readonly HttpListener _listener = new();
    private readonly Dictionary<string, RouteHandler> _routes = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _staticFilesPath;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;

    public delegate Task RouteHandler(HttpListenerContext context, Dictionary<string, string> routeParams);

    public int Port { get; }
    public bool IsRunning => _listener.IsListening;

    public WebServer(int port, string staticFilesPath)
    {
        Port = port;
        _staticFilesPath = staticFilesPath;
        _listener.Prefixes.Add($"http://localhost:{port}/");
        _listener.Prefixes.Add($"http://127.0.0.1:{port}/");
    }

    public void Route(string method, string pattern, RouteHandler handler)
    {
        var key = $"{method.ToUpperInvariant()} {pattern}";
        _routes[key] = handler;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _listener.Start();
        _listenTask = Task.Run(() => ListenLoop(_cts.Token));
    }

    public async Task StopAsync()
    {
        _cts?.Cancel();
        _listener.Stop();
        if (_listenTask != null)
            await _listenTask.ConfigureAwait(false);
    }

    private async Task ListenLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            HttpListenerContext context;
            try { context = await _listener.GetContextAsync().ConfigureAwait(false); }
            catch (HttpListenerException) when (ct.IsCancellationRequested) { break; }
            catch (ObjectDisposedException) { break; }

            _ = Task.Run(async () =>
            {
                try { await HandleRequest(context).ConfigureAwait(false); }
                catch (Exception ex)
                {
                    await WriteJson(context.Response, 500, Models.ApiResponse.Fail($"Internal error: {ex.Message}"));
                }
            }, CancellationToken.None);
        }
    }

    private async Task HandleRequest(HttpListenerContext context)
    {
        var request = context.Request;
        var path = request.Url?.AbsolutePath ?? "/";
        var method = request.HttpMethod.ToUpperInvariant();

        context.Response.Headers.Add("Access-Control-Allow-Origin", "*");
        context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
        context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type");

        if (method == "OPTIONS") { context.Response.StatusCode = 204; context.Response.Close(); return; }

        if (path.StartsWith("/api/", StringComparison.OrdinalIgnoreCase))
        {
            var (handler, routeParams) = MatchRoute(method, path);
            if (handler != null) { await handler(context, routeParams); return; }
            await WriteJson(context.Response, 404, Models.ApiResponse.Fail("Route not found"));
            return;
        }

        await StaticFiles.Serve(context, _staticFilesPath);
    }

    private (RouteHandler? handler, Dictionary<string, string> routeParams) MatchRoute(string method, string path)
    {
        var pathSegments = path.Trim('/').Split('/');

        foreach (var (key, handler) in _routes)
        {
            var parts = key.Split(' ', 2);
            if (parts[0] != method) continue;

            var patternSegments = parts[1].Trim('/').Split('/');
            if (patternSegments.Length != pathSegments.Length) continue;

            var routeParams = new Dictionary<string, string>();
            var match = true;

            for (int i = 0; i < patternSegments.Length; i++)
            {
                if (patternSegments[i].StartsWith(':'))
                    routeParams[patternSegments[i][1..]] = pathSegments[i];
                else if (!string.Equals(patternSegments[i], pathSegments[i], StringComparison.OrdinalIgnoreCase))
                { match = false; break; }
            }

            if (match) return (handler, routeParams);
        }

        return (null, new Dictionary<string, string>());
    }

    public static async Task WriteJson<T>(HttpListenerResponse response, int statusCode, T body)
    {
        response.StatusCode = statusCode;
        response.ContentType = "application/json; charset=utf-8";
        var json = JsonSerializer.SerializeToUtf8Bytes(body, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = false
        });
        response.ContentLength64 = json.Length;
        await response.OutputStream.WriteAsync(json).ConfigureAwait(false);
        response.Close();
    }

    public static async Task<T?> ReadJson<T>(HttpListenerRequest request)
    {
        using var reader = new StreamReader(request.InputStream, Encoding.UTF8);
        var body = await reader.ReadToEndAsync().ConfigureAwait(false);
        return JsonSerializer.Deserialize<T>(body, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true
        });
    }

    public void Dispose()
    {
        _cts?.Cancel();
        _listener.Close();
        try { _listenTask?.Wait(TimeSpan.FromSeconds(2)); } catch { }
        _cts?.Dispose();
    }
}
