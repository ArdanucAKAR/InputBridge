using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;

namespace InputBridge.Windows;

public sealed class ControllerServer : IAsyncDisposable
{
    private readonly AppRuntime _runtime;
    private WebApplication? _app;

    public ControllerServer(AppRuntime runtime) => _runtime = runtime;

    public async Task StartAsync()
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.UseUrls($"http://0.0.0.0:{_runtime.Settings.HttpPort}");
        builder.WebHost.ConfigureKestrel(options =>
        {
            options.Limits.MinRequestBodyDataRate = null;
            options.Limits.MinResponseDataRate = null;
            options.Limits.KeepAliveTimeout = TimeSpan.FromHours(1);
        });
        builder.Services.ConfigureHttpJsonOptions(options => options.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase);
        _app = builder.Build();

        _app.MapGet("/api/health", () => Results.Ok(new
        {
            ok = true,
            protocol = 1,
            controllerId = _runtime.Settings.ControllerId,
            name = Environment.MachineName
        }));

        _app.MapPost("/api/pair/request", async (HttpContext ctx) =>
        {
            if (!NetworkPolicy.IsPrivateOrLoopback(ctx.Connection.RemoteIpAddress)) return Results.StatusCode(StatusCodes.Status403Forbidden);
            var request = await ctx.Request.ReadFromJsonAsync<PairRequest>();
            if (request is null || request.ClientId == Guid.Empty)
                return Results.BadRequest(new { ok = false, error = "invalid-request" });

            var response = _runtime.PairingService.CreateRequest(request.ClientId, request.ClientName ?? "Unnamed Mac");
            return Results.Accepted($"/api/pair/status/{response.RequestId}", new
            {
                requestId = response.RequestId,
                secret = response.Secret,
                status = response.Status
            });
        });

        _app.MapGet("/api/pair/status/{requestId:guid}", (Guid requestId, HttpContext ctx) =>
        {
            if (!NetworkPolicy.IsPrivateOrLoopback(ctx.Connection.RemoteIpAddress)) return Results.StatusCode(StatusCodes.Status403Forbidden);
            var secret = ctx.Request.Headers["X-InputBridge-Pairing-Secret"].ToString();
            var status = _runtime.PairingService.GetStatus(requestId, secret);
            return status.Status == "missing"
                ? Results.NotFound(new { ok = false, error = "pairing-not-found" })
                : Results.Ok(new { ok = true, status = status.Status, token = status.Token, clientName = status.ClientName });
        });

        _app.MapPost("/api/mode/{mode}", async (string mode, HttpContext ctx) =>
        {
            if (!NetworkPolicy.IsPrivateOrLoopback(ctx.Connection.RemoteIpAddress)) return Results.StatusCode(StatusCodes.Status403Forbidden);
            if (!TryAuthorize(ctx, _runtime.PairingService)) return Results.Unauthorized();
            if (!Enum.TryParse<ProfileMode>(mode, true, out var profile))
                return Results.BadRequest(new { ok = false, error = "invalid-mode" });

            var results = await _runtime.ApplyProfileAsync(profile);
            return Results.Ok(new { ok = true, mode = profile.ToString().ToLowerInvariant(), monitors = results });
        });

        _app.MapGet("/api/camera/status", (HttpContext ctx) =>
        {
            if (!NetworkPolicy.IsPrivateOrLoopback(ctx.Connection.RemoteIpAddress)) return Results.StatusCode(StatusCodes.Status403Forbidden);
            if (!TryAuthorize(ctx, _runtime.PairingService)) return Results.Unauthorized();
            return Results.Ok(new
            {
                ok = true,
                enabled = _runtime.Settings.CameraShareEnabled,
                streaming = _runtime.Camera.IsStreaming,
                deviceName = _runtime.Camera.DeviceName
            });
        });

        _app.MapGet("/api/camera/stream", async (HttpContext ctx) =>
        {
            if (!NetworkPolicy.IsPrivateOrLoopback(ctx.Connection.RemoteIpAddress))
            {
                ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            if (!TryAuthorize(ctx, _runtime.PairingService))
            {
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return;
            }
            if (!_runtime.Settings.CameraShareEnabled || !_runtime.Camera.IsStreaming)
            {
                ctx.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
                await ctx.Response.WriteAsJsonAsync(new { ok = false, error = "camera-unavailable" });
                return;
            }

            ctx.Response.ContentType = "application/octet-stream";
            ctx.Response.Headers["Cache-Control"] = "no-store";
            ctx.Response.Headers["X-InputBridge-Camera"] = "jpeg-framed-v1";
            await ctx.Response.StartAsync();
            await _runtime.Camera.WriteStreamAsync(ctx.Response.Body, ctx.RequestAborted);
        });

        await _app.StartAsync();
    }

    private static bool TryAuthorize(HttpContext context, PairingService pairing)
    {
        var value = context.Request.Headers.Authorization.ToString();
        const string prefix = "Bearer ";
        return value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
               && pairing.IsTrusted(value[prefix.Length..].Trim());
    }

    public async ValueTask DisposeAsync()
    {
        if (_app is null) return;

        var app = _app;
        _app = null;
        await app.StopAsync();
        await app.DisposeAsync();
    }

    private sealed record PairRequest(Guid ClientId, string? ClientName);
}
