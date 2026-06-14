using Microsoft.FluentUI.AspNetCore.Components;
using Microsoft.AspNetCore.Components.Authorization;
using System.Net.Http;
using System;
using Microsoft.AspNetCore.Components.WebAssembly.Hosting;

var builder = WebAssemblyHostBuilder.CreateDefault(args);

// <studio-local-admin-auth:http-client>
builder.Services.AddScoped(_ => new HttpClient
{
    BaseAddress = new Uri(builder.HostEnvironment.BaseAddress)
});
// </studio-local-admin-auth:http-client>

// <studio-local-admin-auth:client-services>
builder.Services.AddAuthorizationCore();
builder.Services.AddCascadingAuthenticationState();
builder.Services.AddScoped<AuthenticationStateProvider, CookieAuthStateProvider>();
// </studio-local-admin-auth:client-services>

// <studio-fluent-ui:client-services>
builder.Services.AddFluentUIComponents();
// </studio-fluent-ui:client-services>

await builder.Build().RunAsync();
