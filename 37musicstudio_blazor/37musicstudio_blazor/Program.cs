using System.Text.Json;
using System.Text;
using System.Security.Cryptography;
using System.Globalization;
using Radzen;
using Microsoft.FluentUI.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Authorization;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication;
using System.Security.Claims;
using System.Linq;
using System;
using _37musicstudio_blazor.Components;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents()
    .AddInteractiveWebAssemblyComponents();

// <studio-local-admin-auth:services>
builder.Services
    .AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.LoginPath = "/login";
        options.LogoutPath = "/login";
        options.AccessDeniedPath = "/login";
        options.Cookie.Name = "ThirtySevenStudio.AdminAuth";
        options.Cookie.HttpOnly = true;
        options.Cookie.SameSite = SameSiteMode.Lax;
        options.Cookie.SecurePolicy = CookieSecurePolicy.SameAsRequest;
        options.ExpireTimeSpan = TimeSpan.FromHours(8);
        options.SlidingExpiration = true;
    });

builder.Services.AddAuthorization();
builder.Services.AddCascadingAuthenticationState();
builder.Services.AddSingleton<LocalAdminCredentialStore>();
// </studio-local-admin-auth:services>

// <studio-fluent-ui:http-client>
builder.Services.AddHttpClient();
// </studio-fluent-ui:http-client>

// <studio-fluent-ui:services>
builder.Services.AddFluentUIComponents();
// </studio-fluent-ui:services>

// <studio-ui:radzen-services>
builder.Services.AddRadzenComponents();
// </studio-ui:radzen-services>

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseWebAssemblyDebugging();
}
else
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}
app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);
app.UseHttpsRedirection();

// <studio-local-admin-auth:middleware>
app.UseAuthentication();
app.UseAuthorization();
// </studio-local-admin-auth:middleware>

app.UseAntiforgery();

app.MapStaticAssets();
// <studio-local-admin-auth:endpoints>
app.MapGet("/local-auth/me", (HttpContext httpContext) =>
{
    var isAuthenticated = httpContext.User.Identity?.IsAuthenticated == true;
    var username = isAuthenticated ? httpContext.User.Identity?.Name : null;
    var roles = httpContext.User.Claims
        .Where(claim => claim.Type == ClaimTypes.Role)
        .Select(claim => claim.Value)
        .ToArray();

    return Results.Json(new
    {
        isAuthenticated,
        username,
        roles
    });
}).AllowAnonymous();

app.MapPost("/local-auth/sign-in", async (
    HttpContext httpContext,
    LocalAdminCredentialStore credentialStore) =>
{
    var form = await httpContext.Request.ReadFormAsync();

    var username = form["username"].ToString();
    var password = form["password"].ToString();
    var returnUrl = StudioAuthReturnUrl.Sanitize(form["returnUrl"].ToString());

    bool isValid;

    try
    {
        isValid = await credentialStore.ValidateAsync(username, password);
    }
    catch
    {
        return Results.Redirect(StudioAuthReturnUrl.BuildLoginErrorRedirect("config", returnUrl));
    }

    if (!isValid)
    {
        return Results.Redirect(StudioAuthReturnUrl.BuildLoginErrorRedirect("invalid", returnUrl));
    }

    var claims = new[]
    {
        new Claim(ClaimTypes.Name, username.Trim()),
        new Claim(ClaimTypes.Role, "Admin"),
        new Claim("studio", "37-music-studio")
    };

    var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
    var principal = new ClaimsPrincipal(identity);

    await httpContext.SignInAsync(
        CookieAuthenticationDefaults.AuthenticationScheme,
        principal,
        new AuthenticationProperties
        {
            IsPersistent = true,
            AllowRefresh = true,
            ExpiresUtc = DateTimeOffset.UtcNow.AddHours(8)
        });

    return Results.Redirect(returnUrl);
}).AllowAnonymous();

app.MapPost("/local-auth/sign-out", async (HttpContext httpContext) =>
{
    await httpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);

    return Results.Redirect("/login");
}).RequireAuthorization();
// </studio-local-admin-auth:endpoints>

app.MapPost("/cloudinary/sign-upload", async (CloudinarySignatureRequest request, IWebHostEnvironment environment) =>
{
    try
    {
        var options = await CloudinaryUploadSupport.LoadOptionsAsync(environment.ContentRootPath);
        var folder = string.IsNullOrWhiteSpace(request.Folder)
            ? options.Folder
            : request.Folder.Trim();

        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        var parameters = new SortedDictionary<string, string>(StringComparer.Ordinal)
        {
            ["timestamp"] = timestamp.ToString(CultureInfo.InvariantCulture)
        };

        if (!string.IsNullOrWhiteSpace(folder))
        {
            parameters["folder"] = folder;
        }

        var signature = CloudinaryUploadSupport.SignParameters(parameters, options.ApiSecret);

        return Results.Ok(new CloudinarySignatureResponse(
            options.CloudName,
            options.ApiKey,
            timestamp,
            signature,
            folder ?? string.Empty
        ));
    }
    catch (Exception ex)
    {
        return Results.Problem(
            title: "Cloudinary signature failed",
            detail: ex.Message,
            statusCode: StatusCodes.Status500InternalServerError);
    }
}).RequireAuthorization();
app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode()
    .AddInteractiveWebAssemblyRenderMode()
    .AddAdditionalAssemblies(typeof(_37musicstudio_blazor.Client._Imports).Assembly);

app.Run();

sealed record CloudinarySignatureRequest(string? Folder);

sealed record CloudinarySignatureResponse(
    string CloudName,
    string ApiKey,
    long Timestamp,
    string Signature,
    string Folder);

sealed class CloudinaryLocalOptions
{
    public string CloudName { get; set; } = string.Empty;
    public string ApiKey { get; set; } = string.Empty;
    public string ApiSecret { get; set; } = string.Empty;
    public string Folder { get; set; } = "37-music-studio/gallery";
}

static class CloudinaryUploadSupport
{
    public static async Task<CloudinaryLocalOptions> LoadOptionsAsync(string contentRootPath)
    {
        var candidates = EnumerateConfigPaths(contentRootPath).ToArray();
        var path = candidates.FirstOrDefault(File.Exists);

        if (path is null)
        {
            throw new InvalidOperationException(
                "File .local/cloudinary.local.json belum ada. Buat di root repo atau host project.");
        }

        var json = await File.ReadAllTextAsync(path, Encoding.UTF8);
        var options = JsonSerializer.Deserialize<CloudinaryLocalOptions>(
            json,
            new JsonSerializerOptions(JsonSerializerDefaults.Web));

        if (options is null ||
            string.IsNullOrWhiteSpace(options.CloudName) ||
            string.IsNullOrWhiteSpace(options.ApiKey) ||
            string.IsNullOrWhiteSpace(options.ApiSecret))
        {
            throw new InvalidOperationException(
                "Cloudinary local config wajib berisi cloudName, apiKey, dan apiSecret.");
        }

        options.CloudName = options.CloudName.Trim();
        options.ApiKey = options.ApiKey.Trim();
        options.ApiSecret = options.ApiSecret.Trim();
        options.Folder = string.IsNullOrWhiteSpace(options.Folder)
            ? "37-music-studio/gallery"
            : options.Folder.Trim();

        return options;
    }

    public static string SignParameters(SortedDictionary<string, string> parameters, string apiSecret)
    {
        var payload = string.Join("&", parameters.Select(item => $"{item.Key}={item.Value}"));
        var bytes = SHA1.HashData(Encoding.UTF8.GetBytes(payload + apiSecret));

        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    private static IEnumerable<string> EnumerateConfigPaths(string contentRootPath)
    {
        var current = new DirectoryInfo(contentRootPath);

        for (var index = 0; index < 6 && current is not null; index++)
        {
            yield return Path.Combine(current.FullName, ".local", "cloudinary.local.json");
            current = current.Parent;
        }
    }
}
