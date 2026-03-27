using System.Net;

namespace SPPathFixer.Engine.Http;

public static class StaticFiles
{
    private static readonly Dictionary<string, string> MimeTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        [".html"] = "text/html; charset=utf-8",
        [".js"] = "application/javascript; charset=utf-8",
        [".css"] = "text/css; charset=utf-8",
        [".json"] = "application/json; charset=utf-8",
        [".png"] = "image/png",
        [".svg"] = "image/svg+xml",
        [".ico"] = "image/x-icon",
    };

    public static async Task Serve(HttpListenerContext context, string rootPath)
    {
        var requestPath = context.Request.Url?.AbsolutePath ?? "/";
        if (requestPath == "/") requestPath = "/index.html";

        var safePath = requestPath.Replace('/', Path.DirectorySeparatorChar).TrimStart(Path.DirectorySeparatorChar);
        var fullPath = Path.GetFullPath(Path.Combine(rootPath, safePath));

        if (!fullPath.StartsWith(Path.GetFullPath(rootPath), StringComparison.OrdinalIgnoreCase))
        {
            context.Response.StatusCode = 403;
            context.Response.Close();
            return;
        }

        if (!File.Exists(fullPath))
            fullPath = Path.Combine(rootPath, "index.html");

        if (!File.Exists(fullPath))
        {
            context.Response.StatusCode = 404;
            context.Response.Close();
            return;
        }

        var ext = Path.GetExtension(fullPath);
        context.Response.ContentType = MimeTypes.GetValueOrDefault(ext, "application/octet-stream");
        context.Response.StatusCode = 200;

        if (ext is ".js" or ".css" or ".png" or ".svg")
            context.Response.Headers.Add("Cache-Control", "public, max-age=3600");
        else
            context.Response.Headers.Add("Cache-Control", "no-cache");

        var bytes = await File.ReadAllBytesAsync(fullPath).ConfigureAwait(false);
        context.Response.ContentLength64 = bytes.Length;
        await context.Response.OutputStream.WriteAsync(bytes).ConfigureAwait(false);
        context.Response.Close();
    }
}
