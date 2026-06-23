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
        if (_app is not null) await _app.StopAsync();
        _app?.Dispose();
    }

    private sealed record PairRequest(Guid ClientId, string? ClientName);
}
