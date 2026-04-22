using System.Net;
using System.Text.Json;
using SPPathFixer.Engine.Models;

namespace SPPathFixer.Engine.Http;

public static class ApiRoutes
{
    public static void Register(WebServer server, Engine engine)
    {
        // ── Status ────────────────────────────────────────────
        server.Route("GET", "/api/status", async (ctx, _) =>
        {
            var status = engine.GetStatus();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(status));
        });

        // ── Auth ──────────────────────────────────────────────
        server.Route("POST", "/api/connect", async (ctx, _) =>
        {
            var body = await WebServer.ReadJson<ConnectRequest>(ctx.Request);
            await engine.ConnectAsync(body?.Mode ?? "delegated", body?.ClientId, body?.TenantId,
                body?.PfxPath, body?.PfxPassword, body?.Thumbprint);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(engine.GetStatus()));
        });

        server.Route("POST", "/api/disconnect", async (ctx, _) =>
        {
            engine.Disconnect();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        server.Route("GET", "/api/permissions/check", async (ctx, _) =>
        {
            var result = await engine.CheckPermissionsAsync();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(result));
        });

        // ── Config ────────────────────────────────────────────
        server.Route("GET", "/api/config", async (ctx, _) =>
        {
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(engine.GetConfig()));
        });

        server.Route("PUT", "/api/config", async (ctx, _) =>
        {
            var body = await WebServer.ReadJson<Dictionary<string, JsonElement>>(ctx.Request);
            if (body != null) engine.UpdateConfig(body);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(engine.GetConfig()));
        });

        // ── Scan ──────────────────────────────────────────────
        server.Route("POST", "/api/scan/start", async (ctx, _) =>
        {
            var body = await WebServer.ReadJson<ScanRequest>(ctx.Request);
            if (body == null) { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid request body")); return; }
            var scanId = engine.StartScan(body);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(new { scanId }));
        });

        server.Route("GET", "/api/scan/progress", async (ctx, _) =>
        {
            var progress = engine.GetScanProgress();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(progress));
        });

        server.Route("POST", "/api/scan/cancel", async (ctx, _) =>
        {
            engine.CancelScan();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        // ── Scans list ────────────────────────────────────────
        server.Route("GET", "/api/scans", async (ctx, _) =>
        {
            var scans = engine.GetScans();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(scans));
        });

        server.Route("GET", "/api/scans/:id/results", async (ctx, routeParams) =>
        {
            if (!long.TryParse(routeParams["id"], out var scanId))
            { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID")); return; }

            var qs = ctx.Request.QueryString;
            var page = int.TryParse(qs["page"], out var p) ? p : 1;
            var pageSize = int.TryParse(qs["pageSize"], out var ps) ? ps : 50;
            var results = engine.GetResults(scanId, page, pageSize,
                qs["site"], qs["extension"], qs["type"], qs["fixStatus"],
                qs["search"], qs["sortColumn"], qs["sortDirection"]);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(results));
        });

        server.Route("GET", "/api/scans/:id/summary", async (ctx, routeParams) =>
        {
            if (!long.TryParse(routeParams["id"], out var scanId))
            { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID")); return; }
            var summary = engine.GetSummary(scanId);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(summary));
        });

        server.Route("GET", "/api/scans/:id/export", async (ctx, routeParams) =>
        {
            if (!long.TryParse(routeParams["id"], out var scanId))
            { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID")); return; }

            var format = ctx.Request.QueryString["format"] ?? "xlsx";
            var bytes = engine.Export(scanId, format);

            ctx.Response.ContentType = format.Equals("xlsx", StringComparison.OrdinalIgnoreCase)
                ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                : "text/csv; charset=utf-8";
            ctx.Response.Headers.Add("Content-Disposition", $"attachment; filename=\"long-paths-{scanId}.{format}\"");
            ctx.Response.ContentLength64 = bytes.Length;
            await ctx.Response.OutputStream.WriteAsync(bytes);
            ctx.Response.Close();
        });

        server.Route("DELETE", "/api/scans/:id", async (ctx, routeParams) =>
        {
            if (!long.TryParse(routeParams["id"], out var scanId))
            { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID")); return; }
            engine.DeleteScan(scanId);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok());
        });

        // ── Fix ───────────────────────────────────────────────
        server.Route("GET", "/api/fix/progress", async (ctx, _) =>
        {
            var progress = engine.GetFixProgress();
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(progress));
        });

        server.Route("POST", "/api/scans/:id/fix", async (ctx, routeParams) =>
        {
            if (!long.TryParse(routeParams["id"], out var scanId))
            { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID")); return; }

            var body = await WebServer.ReadJson<FixRequest>(ctx.Request);
            if (body == null) { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid request body")); return; }

            var batchId = engine.StartFix(scanId, body);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(new { batchId }));
        });

        server.Route("POST", "/api/scans/:id/fix/preview", async (ctx, routeParams) =>
        {
            if (!long.TryParse(routeParams["id"], out var scanId))
            { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid scan ID")); return; }

            var body = await WebServer.ReadJson<FixRequest>(ctx.Request);
            if (body == null) { await WebServer.WriteJson(ctx.Response, 400, ApiResponse.Fail("Invalid request body")); return; }
            body.WhatIf = true;

            var batchId = engine.StartFix(scanId, body);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(new { batchId }));
        });

        // ── Sites discovery ───────────────────────────────────
        server.Route("GET", "/api/sites", async (ctx, _) =>
        {
            var qs = ctx.Request.QueryString;
            var pageSize = int.TryParse(qs["pageSize"], out var ps) ? ps : 100;
            var cursor = qs["cursor"];
            var query = qs["query"];
            var includeOneDrive = bool.TryParse(qs["includeOneDrive"], out var iod) && iod;

            var page = await engine.DiscoverSitesPageAsync(pageSize, cursor, query, includeOneDrive);
            await WebServer.WriteJson(ctx.Response, 200, ApiResponse.Ok(page));
        });
    }

    private class ConnectRequest
    {
        public string Mode { get; set; } = "delegated";
        public string? ClientId { get; set; }
        public string? TenantId { get; set; }
        public string? PfxPath { get; set; }
        public string? PfxPassword { get; set; }
        public string? Thumbprint { get; set; }
    }
}
