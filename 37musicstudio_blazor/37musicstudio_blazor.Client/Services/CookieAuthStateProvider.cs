using System;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Components.Authorization;

public sealed class CookieAuthStateProvider : AuthenticationStateProvider
{
    private static readonly ClaimsPrincipal AnonymousUser = new(new ClaimsIdentity());

    private readonly HttpClient httpClient;

    public CookieAuthStateProvider(HttpClient httpClient)
    {
        this.httpClient = httpClient;
    }

    public override async Task<AuthenticationState> GetAuthenticationStateAsync()
    {
        try
        {
            var info = await httpClient.GetFromJsonAsync<LocalAuthUserInfo>("/local-auth/me");

            if (info?.IsAuthenticated == true)
            {
                var claims = new[]
                {
                    new Claim(ClaimTypes.Name, info.Username ?? "admin")
                }
                .Concat((info.Roles ?? Array.Empty<string>()).Select(role => new Claim(ClaimTypes.Role, role)));

                var identity = new ClaimsIdentity(claims, "LocalCookie");
                return new AuthenticationState(new ClaimsPrincipal(identity));
            }
        }
        catch
        {
        }

        return new AuthenticationState(AnonymousUser);
    }

    private sealed class LocalAuthUserInfo
    {
        public bool IsAuthenticated { get; set; }

        public string? Username { get; set; }

        public string[]? Roles { get; set; }
    }
}