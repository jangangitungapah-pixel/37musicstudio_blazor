$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ROOT = (Get-Location).Path
$STAMP = Get-Date -Format "yyyyMMddHHmmss"

function Fail($message) {
  throw "❌ $message"
}

function Info($message) {
  Write-Host "✅ $message"
}

function Ensure-Dir($path) {
  if (-not [string]::IsNullOrWhiteSpace($path)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
  }
}

function Read-Text($path) {
  [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Write-TextIfChanged($path, $content) {
  $parent = Split-Path -Parent $path
  Ensure-Dir $parent

  $old = $null
  if (Test-Path $path) {
    $old = Read-Text $path
  }

  if ($old -ne $content) {
    if (Test-Path $path) {
      Copy-Item $path "$path.bak-$STAMP" -Force
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
    Info "Updated: $path"
  } else {
    Info "No changes: $path"
  }
}

function Add-LinesOnce($path, [string[]]$lines) {
  $content = ""
  if (Test-Path $path) {
    $content = Read-Text $path
  }

  $changed = $false

  foreach ($line in $lines) {
    if ($content -notmatch [regex]::Escape($line)) {
      if (-not $content.EndsWith("`r`n") -and $content.Length -gt 0) {
        $content += "`r`n"
      }

      $content += "$line`r`n"
      $changed = $true
    }
  }

  if ($changed) {
    Write-TextIfChanged $path $content
  } else {
    Info "No changes: $path"
  }
}

function Insert-BeforeFirstMatch($content, [string[]]$patterns, $insertBlock, $contextName) {
  foreach ($pattern in $patterns) {
    $match = [regex]::Match($content, $pattern)
    if ($match.Success) {
      return $content.Insert($match.Index, "$insertBlock`r`n`r`n")
    }
  }

  Fail "Anchor tidak ditemukan untuk $contextName."
}

function Ensure-ProgramUsing($content, $usingLine) {
  if ($content -match [regex]::Escape($usingLine)) {
    return $content
  }

  return "$usingLine`r`n$content"
}

$projectFiles = Get-ChildItem -Path $ROOT -Recurse -File -Filter "*.csproj" |
  Where-Object {
    $_.FullName -notmatch "\\(bin|obj|TestResults)\\" -and
    $_.Name -notmatch "(Test|Tests)\.csproj$"
  }

if (-not $projectFiles -or $projectFiles.Count -eq 0) {
  Fail "Tidak ada file .csproj yang cocok di repo ini."
}

$projectFile = $projectFiles |
  Where-Object { Test-Path (Join-Path $_.DirectoryName "Program.cs") } |
  Sort-Object FullName |
  Select-Object -First 1

if (-not $projectFile) {
  Fail "Tidak menemukan project Blazor dengan Program.cs."
}

$projectDir = $projectFile.DirectoryName
$programPath = Join-Path $projectDir "Program.cs"

Info "Project terdeteksi: $($projectFile.FullName)"

$componentsDir = Join-Path $projectDir "Components"
$componentsPagesDir = Join-Path $componentsDir "Pages"
$classicPagesDir = Join-Path $projectDir "Pages"

if (Test-Path $componentsPagesDir) {
  $pagesDir = $componentsPagesDir
} elseif (Test-Path $classicPagesDir) {
  $pagesDir = $classicPagesDir
} else {
  $pagesDir = $componentsPagesDir
  Ensure-Dir $pagesDir
}

$servicesDir = Join-Path $projectDir "Services"
Ensure-Dir $servicesDir

$routerCandidates = @(
  (Join-Path $componentsDir "Routes.razor"),
  (Join-Path $projectDir "App.razor"),
  (Join-Path $componentsDir "App.razor")
) | Where-Object { Test-Path $_ }

$routerPath = $null

foreach ($candidate in $routerCandidates) {
  $candidateText = Read-Text $candidate
  if ($candidateText -match "<Router\b") {
    $routerPath = $candidate
    break
  }
}

if (-not $routerPath) {
  Fail "Tidak menemukan file Router Blazor. Cek Components/Routes.razor atau App.razor."
}

$routerDir = Split-Path -Parent $routerPath

Info "Router terdeteksi: $routerPath"
Info "Pages target: $pagesDir"

$gitignorePath = Join-Path $ROOT ".gitignore"

Add-LinesOnce $gitignorePath @(
  "",
  "# 37 Music Studio local-only auth credentials",
  ".local/",
  "**/.local/",
  "*.local.json"
)

$localDir = Join-Path $projectDir ".local"
$localAuthPath = Join-Path $localDir "auth.local.json"
Ensure-Dir $localDir

if (-not (Test-Path $localAuthPath)) {
  $localAuthJson = @'
{
  "username": "admin",
  "password": "12345678"
}
'@

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($localAuthPath, $localAuthJson, $utf8NoBom)
  Info "Created local-only auth file: $localAuthPath"
} else {
  Info "Local auth file already exists, tidak ditimpa: $localAuthPath"
}

$credentialStorePath = Join-Path $servicesDir "LocalAdminCredentialStore.cs"

$credentialStoreCode = @'
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Extensions.Hosting;

public sealed class LocalAdminCredentialStore
{
    private const string CredentialDirectoryName = ".local";
    private const string CredentialFileName = "auth.local.json";

    private readonly IHostEnvironment environment;

    public LocalAdminCredentialStore(IHostEnvironment environment)
    {
        this.environment = environment;
    }

    public async Task<bool> ValidateAsync(string? username, string? password)
    {
        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password))
        {
            return false;
        }

        var credential = await LoadCredentialAsync();

        if (string.IsNullOrWhiteSpace(credential.Username) || string.IsNullOrEmpty(credential.Password))
        {
            return false;
        }

        return FixedEquals(username.Trim(), credential.Username.Trim()) &&
               FixedEquals(password, credential.Password);
    }

    private async Task<LocalAdminCredential> LoadCredentialAsync()
    {
        foreach (var candidatePath in GetCandidatePaths())
        {
            if (!File.Exists(candidatePath))
            {
                continue;
            }

            await using var stream = File.OpenRead(candidatePath);

            var credential = await JsonSerializer.DeserializeAsync<LocalAdminCredential>(
                stream,
                new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });

            if (credential is not null)
            {
                return credential;
            }
        }

        throw new FileNotFoundException(
            "File local auth tidak ditemukan. Buat file .local/auth.local.json di project Blazor.",
            Path.Combine(environment.ContentRootPath, CredentialDirectoryName, CredentialFileName));
    }

    private IEnumerable<string> GetCandidatePaths()
    {
        yield return Path.Combine(environment.ContentRootPath, CredentialDirectoryName, CredentialFileName);

        var parent = Directory.GetParent(environment.ContentRootPath)?.FullName;

        if (!string.IsNullOrWhiteSpace(parent))
        {
            yield return Path.Combine(parent, CredentialDirectoryName, CredentialFileName);
        }

        yield return Path.Combine(Directory.GetCurrentDirectory(), CredentialDirectoryName, CredentialFileName);
    }

    private static bool FixedEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);

        return leftBytes.Length == rightBytes.Length &&
               CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
    }

    private sealed class LocalAdminCredential
    {
        public string? Username { get; set; }

        public string? Password { get; set; }
    }
}
'@

Write-TextIfChanged $credentialStorePath $credentialStoreCode

$returnUrlPath = Join-Path $servicesDir "StudioAuthReturnUrl.cs"

$returnUrlCode = @'
using System;

public static class StudioAuthReturnUrl
{
    public static string Sanitize(string? rawReturnUrl)
    {
        if (string.IsNullOrWhiteSpace(rawReturnUrl))
        {
            return "/admin";
        }

        var candidate = Uri.UnescapeDataString(rawReturnUrl.Trim()).Replace('\\', '/');

        if (candidate.StartsWith("~", StringComparison.Ordinal))
        {
            candidate = candidate[1..];
        }

        if (Uri.TryCreate(candidate, UriKind.Absolute, out _))
        {
            return "/admin";
        }

        if (!candidate.StartsWith("/", StringComparison.Ordinal))
        {
            candidate = "/" + candidate.TrimStart('/');
        }

        if (candidate.StartsWith("//", StringComparison.Ordinal))
        {
            return "/admin";
        }

        if (candidate.Equals("/login", StringComparison.OrdinalIgnoreCase) ||
            candidate.StartsWith("/login?", StringComparison.OrdinalIgnoreCase) ||
            candidate.StartsWith("/local-auth", StringComparison.OrdinalIgnoreCase))
        {
            return "/admin";
        }

        return candidate;
    }

    public static string BuildLoginErrorRedirect(string errorCode, string? returnUrl)
    {
        var safeReturnUrl = Sanitize(returnUrl);

        return $"/login?error={Uri.EscapeDataString(errorCode)}&returnUrl={Uri.EscapeDataString(safeReturnUrl)}";
    }
}
'@

Write-TextIfChanged $returnUrlPath $returnUrlCode

$blankLayoutPath = Join-Path $pagesDir "AdminBlankLayout.razor"

$blankLayoutCode = @'
@inherits Microsoft.AspNetCore.Components.LayoutComponentBase

<div class="studio-blank-layout">
    @Body
</div>
'@

Write-TextIfChanged $blankLayoutPath $blankLayoutCode

$blankLayoutCssPath = Join-Path $pagesDir "AdminBlankLayout.razor.css"

$blankLayoutCssCode = @'
.studio-blank-layout {
    min-height: 100dvh;
    background:
        radial-gradient(circle at top left, color-mix(in srgb, var(--ui-accent, #d8a85f) 14%, transparent), transparent 34rem),
        var(--ui-bg-page, #f7f2ea);
    color: var(--ui-text-main, #241b13);
}
'@

Write-TextIfChanged $blankLayoutCssPath $blankLayoutCssCode

$loginPath = Join-Path $pagesDir "Login.razor"

$loginCode = @'
@page "/login"
@attribute [Microsoft.AspNetCore.Authorization.AllowAnonymous]
@layout AdminBlankLayout

<PageTitle>Login Admin | 37 Music Studio</PageTitle>

<main class="studio-login-page theme-container" aria-labelledby="studioLoginTitle">
    <section class="studio-login-panel" aria-label="Login admin 37 Music Studio">
        <div class="studio-login-brand">
            <div class="studio-login-brand__mark" aria-hidden="true">37</div>

            <div class="studio-login-brand__copy">
                <p class="studio-login-brand__eyebrow">Admin Portal</p>
                <h1 id="studioLoginTitle">37 Music Studio</h1>
                <p>Masuk ke ruang kendali studio.</p>
            </div>
        </div>

        <form class="studio-login-card" method="post" action="/local-auth/sign-in" autocomplete="on">
            <input type="hidden" name="returnUrl" value="@SafeReturnUrl" />

            <div class="studio-login-card__header">
                <p>Secure Local Access</p>
                <h2>Login Admin</h2>
            </div>

            @if (HasError)
            {
                <div class="studio-login-alert" role="alert">
                    @ErrorMessage
                </div>
            }

            <label class="studio-login-field">
                <span>Username</span>
                <input
                    name="username"
                    type="text"
                    autocomplete="username"
                    inputmode="text"
                    spellcheck="false"
                    placeholder="Masukkan username"
                    required />
            </label>

            <label class="studio-login-field">
                <span>Password</span>
                <input
                    name="password"
                    type="password"
                    autocomplete="current-password"
                    placeholder="Masukkan password"
                    required />
            </label>

            <button class="studio-login-submit" type="submit">
                Masuk ke Admin
            </button>

            <p class="studio-login-note">
                Credential aktif dibaca dari file lokal yang tidak ikut commit.
            </p>
        </form>
    </section>
</main>

@code {
    [Microsoft.AspNetCore.Components.SupplyParameterFromQuery(Name = "error")]
    public string? Error { get; set; }

    [Microsoft.AspNetCore.Components.SupplyParameterFromQuery(Name = "returnUrl")]
    public string? ReturnUrl { get; set; }

    private string SafeReturnUrl => StudioAuthReturnUrl.Sanitize(ReturnUrl);

    private bool HasError => !string.IsNullOrWhiteSpace(Error);

    private string ErrorMessage => Error?.Trim().ToLowerInvariant() switch
    {
        "config" => "File auth lokal belum siap atau tidak bisa dibaca. Cek .local/auth.local.json.",
        _ => "Username atau password belum cocok."
    };
}
'@

Write-TextIfChanged $loginPath $loginCode

$loginCssPath = Join-Path $pagesDir "Login.razor.css"

$loginCssCode = @'
.studio-login-page {
    min-height: 100dvh;
    display: grid;
    place-items: center;
    padding: clamp(1.25rem, 3vw, 3rem);
    background:
        radial-gradient(circle at 16% 18%, color-mix(in srgb, var(--ui-accent, #d8a85f) 18%, transparent), transparent 22rem),
        radial-gradient(circle at 86% 12%, color-mix(in srgb, var(--ui-control, #7d5fff) 12%, transparent), transparent 24rem),
        var(--ui-bg-page, #f7f2ea);
    color: var(--ui-text-main, #241b13);
}

.studio-login-panel {
    width: min(100%, 68rem);
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(20rem, 28rem);
    gap: clamp(1rem, 3vw, 2rem);
    align-items: stretch;
}

.studio-login-brand {
    min-height: 33rem;
    display: flex;
    flex-direction: column;
    justify-content: space-between;
    padding: clamp(1.5rem, 4vw, 3rem);
    border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    border-radius: 2rem;
    background:
        linear-gradient(135deg, color-mix(in srgb, var(--ui-surface, #ffffff) 88%, transparent), color-mix(in srgb, var(--ui-bg-page, #f7f2ea) 76%, transparent)),
        var(--ui-surface, #ffffff);
    box-shadow: var(--ui-shadow-soft, 0 24px 70px rgba(35, 25, 14, 0.14));
    overflow: hidden;
    position: relative;
}

.studio-login-brand::after {
    content: "";
    position: absolute;
    inset: auto -12rem -15rem auto;
    width: 28rem;
    aspect-ratio: 1;
    border-radius: 999px;
    background: color-mix(in srgb, var(--ui-accent, #d8a85f) 18%, transparent);
    filter: blur(1px);
    pointer-events: none;
}

.studio-login-brand__mark {
    width: 5.25rem;
    height: 5.25rem;
    display: grid;
    place-items: center;
    border-radius: 1.4rem;
    border: 1px solid color-mix(in srgb, var(--ui-accent, #d8a85f) 38%, var(--ui-border, rgba(36, 27, 19, 0.12)));
    background: color-mix(in srgb, var(--ui-accent, #d8a85f) 14%, var(--ui-surface, #ffffff));
    color: var(--ui-text-strong, #17100b);
    font-size: 1.8rem;
    font-weight: 900;
    letter-spacing: -0.08em;
}

.studio-login-brand__copy {
    position: relative;
    z-index: 1;
    max-width: 34rem;
}

.studio-login-brand__eyebrow,
.studio-login-card__header p {
    margin: 0 0 0.65rem;
    color: var(--ui-text-muted, #7a6b5e);
    font-size: 0.78rem;
    font-weight: 800;
    letter-spacing: 0.16em;
    text-transform: uppercase;
}

.studio-login-brand h1 {
    margin: 0;
    color: var(--ui-text-strong, #17100b);
    font-size: clamp(2.4rem, 7vw, 5.6rem);
    line-height: 0.92;
    letter-spacing: -0.08em;
}

.studio-login-brand p:last-child {
    margin: 1rem 0 0;
    max-width: 28rem;
    color: var(--ui-text-muted, #7a6b5e);
    font-size: 1.02rem;
    line-height: 1.7;
}

.studio-login-card {
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 1rem;
    padding: clamp(1.25rem, 3vw, 2rem);
    border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    border-radius: 2rem;
    background: color-mix(in srgb, var(--ui-surface, #ffffff) 94%, transparent);
    box-shadow: var(--ui-shadow-soft, 0 24px 70px rgba(35, 25, 14, 0.14));
}

.studio-login-card__header h2 {
    margin: 0;
    color: var(--ui-text-strong, #17100b);
    font-size: clamp(1.75rem, 4vw, 2.5rem);
    letter-spacing: -0.06em;
}

.studio-login-alert {
    border: 1px solid color-mix(in srgb, #e14b4b 45%, var(--ui-border, rgba(36, 27, 19, 0.12)));
    border-radius: 1rem;
    padding: 0.85rem 1rem;
    background: color-mix(in srgb, #e14b4b 10%, var(--ui-surface, #ffffff));
    color: var(--ui-text-strong, #17100b);
    font-size: 0.92rem;
    line-height: 1.5;
}

.studio-login-field {
    display: grid;
    gap: 0.45rem;
}

.studio-login-field span {
    color: var(--ui-text-strong, #17100b);
    font-size: 0.88rem;
    font-weight: 800;
}

.studio-login-field input {
    width: 100%;
    min-height: 3.25rem;
    border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    border-radius: 1rem;
    padding: 0 1rem;
    outline: none;
    background: color-mix(in srgb, var(--ui-surface, #ffffff) 72%, var(--ui-bg-page, #f7f2ea));
    color: var(--ui-text-main, #241b13);
    font: inherit;
    transition: border-color 160ms ease, box-shadow 160ms ease, transform 160ms ease;
}

.studio-login-field input:focus {
    border-color: color-mix(in srgb, var(--ui-accent, #d8a85f) 68%, var(--ui-border, rgba(36, 27, 19, 0.12)));
    box-shadow: 0 0 0 4px color-mix(in srgb, var(--ui-accent, #d8a85f) 16%, transparent);
}

.studio-login-submit {
    min-height: 3.35rem;
    border: 0;
    border-radius: 1rem;
    cursor: pointer;
    background: var(--ui-accent, #d8a85f);
    color: var(--ui-accent-contrast, #17100b);
    font: inherit;
    font-weight: 900;
    letter-spacing: -0.02em;
    box-shadow: 0 16px 34px color-mix(in srgb, var(--ui-accent, #d8a85f) 30%, transparent);
    transition: transform 160ms ease, filter 160ms ease;
}

.studio-login-submit:hover {
    transform: translateY(-1px);
    filter: brightness(1.03);
}

.studio-login-note {
    margin: 0;
    color: var(--ui-text-muted, #7a6b5e);
    font-size: 0.86rem;
    line-height: 1.55;
}

@media (max-width: 820px) {
    .studio-login-page {
        align-items: start;
        padding: 1rem;
    }

    .studio-login-panel {
        grid-template-columns: 1fr;
    }

    .studio-login-brand {
        min-height: 15rem;
    }
}
'@

Write-TextIfChanged $loginCssPath $loginCssCode

$adminPath = Join-Path $pagesDir "Admin.razor"

$adminCode = @'
@page "/admin"
@attribute [Microsoft.AspNetCore.Authorization.Authorize(Roles = "Admin")]
@layout AdminBlankLayout

<PageTitle>Admin | 37 Music Studio</PageTitle>

<div class="studio-admin-shell theme-container">
    <input class="studio-admin-sidebar-toggle" id="studioAdminSidebarToggle" type="checkbox" aria-label="Collapse sidebar" />

    <aside class="studio-admin-sidebar" aria-label="Navigasi admin desktop">
        <div class="studio-admin-sidebar__top">
            <a class="studio-admin-brand" href="/admin" aria-label="37 Music Studio Admin">
                <span class="studio-admin-brand__mark" aria-hidden="true">37</span>
                <span class="studio-admin-brand__text">
                    <strong>37 Studio</strong>
                    <small>Admin</small>
                </span>
            </a>

            <label class="studio-admin-collapse" for="studioAdminSidebarToggle" title="Collapse sidebar">
                <span aria-hidden="true">‹</span>
            </label>
        </div>

        <nav class="studio-admin-nav" aria-label="Menu admin">
            <a class="studio-admin-nav__item is-active" href="/admin">
                <span aria-hidden="true">⌂</span>
                <strong>Dashboard</strong>
            </a>

            <a class="studio-admin-nav__item" href="/admin">
                <span aria-hidden="true">♫</span>
                <strong>Studio</strong>
            </a>

            <a class="studio-admin-nav__item" href="/admin">
                <span aria-hidden="true">◎</span>
                <strong>Booking</strong>
            </a>

            <a class="studio-admin-nav__item" href="/admin">
                <span aria-hidden="true">☰</span>
                <strong>Settings</strong>
            </a>
        </nav>

        <form class="studio-admin-logout" method="post" action="/local-auth/sign-out">
            <button type="submit">
                <span aria-hidden="true">⎋</span>
                <strong>Logout</strong>
            </button>
        </form>
    </aside>

    <main class="studio-admin-main" aria-label="Area utama admin">
        <header class="studio-admin-header">
            <div>
                <p>Admin Shell</p>
                <h1>Dashboard</h1>
            </div>

            <form method="post" action="/local-auth/sign-out">
                <button class="studio-admin-header__logout" type="submit">Logout</button>
            </form>
        </header>

        <section class="studio-admin-workspace" aria-label="Konten admin kosong"></section>
    </main>

    <nav class="studio-admin-bottom-bar" aria-label="Navigasi admin mobile">
        <a class="is-active" href="/admin">
            <span aria-hidden="true">⌂</span>
            <strong>Home</strong>
        </a>

        <a href="/admin">
            <span aria-hidden="true">♫</span>
            <strong>Studio</strong>
        </a>

        <a href="/admin">
            <span aria-hidden="true">◎</span>
            <strong>Booking</strong>
        </a>

        <form method="post" action="/local-auth/sign-out">
            <button type="submit">
                <span aria-hidden="true">⎋</span>
                <strong>Logout</strong>
            </button>
        </form>
    </nav>
</div>
'@

Write-TextIfChanged $adminPath $adminCode

$adminCssPath = Join-Path $pagesDir "Admin.razor.css"

$adminCssCode = @'
.studio-admin-shell {
    --studio-admin-sidebar-width: 18rem;
    min-height: 100dvh;
    display: grid;
    grid-template-columns: var(--studio-admin-sidebar-width) minmax(0, 1fr);
    background:
        radial-gradient(circle at 16% 10%, color-mix(in srgb, var(--ui-accent, #d8a85f) 13%, transparent), transparent 24rem),
        var(--ui-bg-page, #f7f2ea);
    color: var(--ui-text-main, #241b13);
}

.studio-admin-sidebar-toggle {
    position: absolute;
    width: 1px;
    height: 1px;
    opacity: 0;
    pointer-events: none;
}

.studio-admin-shell:has(.studio-admin-sidebar-toggle:checked) {
    --studio-admin-sidebar-width: 6.5rem;
}

.studio-admin-sidebar {
    position: sticky;
    top: 0;
    height: 100dvh;
    display: flex;
    flex-direction: column;
    gap: 1rem;
    padding: 1rem;
    border-right: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    background: color-mix(in srgb, var(--ui-surface, #ffffff) 88%, transparent);
    backdrop-filter: blur(18px);
}

.studio-admin-sidebar__top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
}

.studio-admin-brand,
.studio-admin-nav__item,
.studio-admin-logout button,
.studio-admin-bottom-bar a,
.studio-admin-bottom-bar button {
    color: inherit;
    text-decoration: none;
}

.studio-admin-brand {
    min-width: 0;
    display: flex;
    align-items: center;
    gap: 0.75rem;
}

.studio-admin-brand__mark {
    width: 3.25rem;
    height: 3.25rem;
    flex: 0 0 auto;
    display: grid;
    place-items: center;
    border-radius: 1rem;
    background: color-mix(in srgb, var(--ui-accent, #d8a85f) 16%, var(--ui-surface, #ffffff));
    border: 1px solid color-mix(in srgb, var(--ui-accent, #d8a85f) 36%, var(--ui-border, rgba(36, 27, 19, 0.12)));
    color: var(--ui-text-strong, #17100b);
    font-weight: 950;
    letter-spacing: -0.08em;
}

.studio-admin-brand__text {
    display: grid;
    min-width: 0;
}

.studio-admin-brand__text strong {
    color: var(--ui-text-strong, #17100b);
    font-size: 0.96rem;
    letter-spacing: -0.04em;
}

.studio-admin-brand__text small {
    color: var(--ui-text-muted, #7a6b5e);
    font-size: 0.78rem;
    font-weight: 800;
    text-transform: uppercase;
    letter-spacing: 0.12em;
}

.studio-admin-collapse {
    width: 2.4rem;
    height: 2.4rem;
    flex: 0 0 auto;
    display: grid;
    place-items: center;
    border-radius: 0.8rem;
    border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    background: color-mix(in srgb, var(--ui-surface, #ffffff) 74%, var(--ui-bg-page, #f7f2ea));
    cursor: pointer;
    user-select: none;
}

.studio-admin-shell:has(.studio-admin-sidebar-toggle:checked) .studio-admin-collapse span {
    transform: rotate(180deg);
}

.studio-admin-nav {
    display: grid;
    gap: 0.5rem;
    margin-top: 1rem;
}

.studio-admin-nav__item,
.studio-admin-logout button {
    min-height: 3rem;
    display: flex;
    align-items: center;
    gap: 0.75rem;
    border-radius: 1rem;
    padding: 0 0.85rem;
    border: 1px solid transparent;
    background: transparent;
    color: var(--ui-text-muted, #7a6b5e);
    font: inherit;
    cursor: pointer;
}

.studio-admin-nav__item span,
.studio-admin-logout span {
    width: 1.65rem;
    flex: 0 0 auto;
    text-align: center;
    font-size: 1rem;
}

.studio-admin-nav__item strong,
.studio-admin-logout strong {
    font-size: 0.9rem;
    font-weight: 850;
}

.studio-admin-nav__item:hover,
.studio-admin-logout button:hover,
.studio-admin-nav__item.is-active {
    border-color: var(--ui-border, rgba(36, 27, 19, 0.12));
    background: color-mix(in srgb, var(--ui-accent, #d8a85f) 11%, var(--ui-surface, #ffffff));
    color: var(--ui-text-strong, #17100b);
}

.studio-admin-logout {
    margin-top: auto;
}

.studio-admin-logout button {
    width: 100%;
}

.studio-admin-shell:has(.studio-admin-sidebar-toggle:checked) .studio-admin-brand__text,
.studio-admin-shell:has(.studio-admin-sidebar-toggle:checked) .studio-admin-nav__item strong,
.studio-admin-shell:has(.studio-admin-sidebar-toggle:checked) .studio-admin-logout strong {
    display: none;
}

.studio-admin-shell:has(.studio-admin-sidebar-toggle:checked) .studio-admin-sidebar {
    align-items: center;
}

.studio-admin-main {
    min-width: 0;
    display: grid;
    grid-template-rows: auto minmax(0, 1fr);
    padding: clamp(1rem, 2vw, 1.5rem);
}

.studio-admin-header {
    min-height: 5rem;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 1rem clamp(1rem, 2vw, 1.5rem);
    border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    border-radius: 1.4rem;
    background: color-mix(in srgb, var(--ui-surface, #ffffff) 82%, transparent);
    box-shadow: var(--ui-shadow-soft, 0 18px 50px rgba(35, 25, 14, 0.10));
}

.studio-admin-header p {
    margin: 0 0 0.25rem;
    color: var(--ui-text-muted, #7a6b5e);
    font-size: 0.75rem;
    font-weight: 900;
    letter-spacing: 0.14em;
    text-transform: uppercase;
}

.studio-admin-header h1 {
    margin: 0;
    color: var(--ui-text-strong, #17100b);
    font-size: clamp(1.4rem, 3vw, 2.2rem);
    letter-spacing: -0.06em;
}

.studio-admin-header__logout {
    min-height: 2.75rem;
    border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
    border-radius: 999px;
    padding: 0 1rem;
    background: color-mix(in srgb, var(--ui-surface, #ffffff) 78%, var(--ui-bg-page, #f7f2ea));
    color: var(--ui-text-main, #241b13);
    font: inherit;
    font-weight: 850;
    cursor: pointer;
}

.studio-admin-workspace {
    min-height: 0;
    margin-top: 1rem;
    border: 1px dashed color-mix(in srgb, var(--ui-border, rgba(36, 27, 19, 0.12)) 88%, var(--ui-accent, #d8a85f));
    border-radius: 1.5rem;
    background:
        linear-gradient(135deg, color-mix(in srgb, var(--ui-surface, #ffffff) 68%, transparent), transparent),
        color-mix(in srgb, var(--ui-bg-page, #f7f2ea) 82%, transparent);
}

.studio-admin-bottom-bar {
    display: none;
}

@media (max-width: 860px) {
    .studio-admin-shell {
        display: block;
        padding-bottom: calc(5rem + env(safe-area-inset-bottom));
    }

    .studio-admin-sidebar,
    .studio-admin-sidebar-toggle {
        display: none;
    }

    .studio-admin-main {
        min-height: 100dvh;
        padding: 1rem;
    }

    .studio-admin-header {
        border-radius: 1.25rem;
    }

    .studio-admin-header__logout {
        display: none;
    }

    .studio-admin-workspace {
        min-height: calc(100dvh - 8rem);
    }

    .studio-admin-bottom-bar {
        position: fixed;
        left: 0.75rem;
        right: 0.75rem;
        bottom: max(0.75rem, env(safe-area-inset-bottom));
        z-index: 20;
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0.35rem;
        padding: 0.45rem;
        border: 1px solid var(--ui-border, rgba(36, 27, 19, 0.12));
        border-radius: 1.35rem;
        background: color-mix(in srgb, var(--ui-surface, #ffffff) 90%, transparent);
        box-shadow: var(--ui-shadow-soft, 0 18px 50px rgba(35, 25, 14, 0.16));
        backdrop-filter: blur(18px);
    }

    .studio-admin-bottom-bar a,
    .studio-admin-bottom-bar button {
        min-height: 3.3rem;
        display: grid;
        place-items: center;
        gap: 0.12rem;
        border: 0;
        border-radius: 1rem;
        background: transparent;
        color: var(--ui-text-muted, #7a6b5e);
        font: inherit;
        cursor: pointer;
    }

    .studio-admin-bottom-bar span {
        font-size: 1rem;
        line-height: 1;
    }

    .studio-admin-bottom-bar strong {
        font-size: 0.7rem;
        font-weight: 850;
        line-height: 1;
    }

    .studio-admin-bottom-bar .is-active {
        background: color-mix(in srgb, var(--ui-accent, #d8a85f) 15%, var(--ui-surface, #ffffff));
        color: var(--ui-text-strong, #17100b);
    }
}
'@

Write-TextIfChanged $adminCssPath $adminCssCode

$redirectPath = Join-Path $routerDir "RedirectToLogin.razor"

$redirectCode = @'
@inject Microsoft.AspNetCore.Components.NavigationManager NavigationManager

@code {
    protected override void OnInitialized()
    {
        var relativePath = NavigationManager.ToBaseRelativePath(NavigationManager.Uri);
        var returnUrl = string.IsNullOrWhiteSpace(relativePath)
            ? "/admin"
            : "/" + relativePath.TrimStart('/');

        var target = "/login?returnUrl=" + Uri.EscapeDataString(returnUrl);

        NavigationManager.NavigateTo(target, forceLoad: true);
    }
}
'@

Write-TextIfChanged $redirectPath $redirectCode

$importCandidates = @(
  (Join-Path $projectDir "_Imports.razor"),
  (Join-Path $componentsDir "_Imports.razor"),
  (Join-Path $pagesDir "_Imports.razor"),
  (Join-Path $routerDir "_Imports.razor")
) | Select-Object -Unique

$existingImports = $importCandidates | Where-Object { Test-Path $_ }

if (-not $existingImports -or $existingImports.Count -eq 0) {
  $defaultImportsPath = Join-Path $projectDir "_Imports.razor"
  Write-TextIfChanged $defaultImportsPath ""
  $existingImports = @($defaultImportsPath)
}

foreach ($importsPath in $existingImports) {
  Add-LinesOnce $importsPath @(
    "@using Microsoft.AspNetCore.Authorization",
    "@using Microsoft.AspNetCore.Components.Authorization"
  )
}

$programText = Read-Text $programPath

if ($programText -match "AddAuthentication\s*\(" -and $programText -notmatch "<studio-local-admin-auth:services>") {
  Fail "Program.cs sudah punya AddAuthentication. Stop dulu biar auth existing tidak ketiban."
}

if ($programText -match "UseAuthentication\s*\(" -and $programText -notmatch "<studio-local-admin-auth:middleware>") {
  Fail "Program.cs sudah punya UseAuthentication. Stop dulu biar middleware existing tidak ketiban."
}

$programText = Ensure-ProgramUsing $programText "using System;"
$programText = Ensure-ProgramUsing $programText "using System.Security.Claims;"
$programText = Ensure-ProgramUsing $programText "using Microsoft.AspNetCore.Authentication;"
$programText = Ensure-ProgramUsing $programText "using Microsoft.AspNetCore.Authentication.Cookies;"
$programText = Ensure-ProgramUsing $programText "using Microsoft.AspNetCore.Components.Authorization;"

$serviceBlock = @'
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
'@

if ($programText -notmatch "<studio-local-admin-auth:services>") {
  $programText = Insert-BeforeFirstMatch $programText @(
    "var\s+app\s*=\s*builder\.Build\s*\(\s*\)\s*;"
  ) $serviceBlock "service auth sebelum builder.Build()"
}

$middlewareBlock = @'
// <studio-local-admin-auth:middleware>
app.UseAuthentication();
app.UseAuthorization();
// </studio-local-admin-auth:middleware>
'@

if ($programText -notmatch "<studio-local-admin-auth:middleware>") {
  $programText = Insert-BeforeFirstMatch $programText @(
    "app\.UseAntiforgery\s*\(\s*\)\s*;",
    "app\.MapRazorComponents\b",
    "app\.MapBlazorHub\s*\(",
    "app\.Run\s*\(\s*\)\s*;"
  ) $middlewareBlock "middleware auth"
}

$endpointBlock = @'
// <studio-local-admin-auth:endpoints>
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
'@

if ($programText -notmatch "<studio-local-admin-auth:endpoints>") {
  $programText = Insert-BeforeFirstMatch $programText @(
    "app\.MapRazorComponents\b",
    "app\.MapBlazorHub\s*\(",
    "app\.Run\s*\(\s*\)\s*;"
  ) $endpointBlock "endpoint local auth"
}

Write-TextIfChanged $programPath $programText

$routerText = Read-Text $routerPath

if ($routerText -notmatch "AuthorizeRouteView") {
  $routeViewPattern = '<RouteView\s+RouteData="@routeData"\s+DefaultLayout="@typeof\((?<layout>[^)]+)\)"\s*/>'
  $routeViewMatch = [regex]::Match($routerText, $routeViewPattern)

  if (-not $routeViewMatch.Success) {
    Fail "Anchor RouteView standar tidak ditemukan di $routerPath."
  }

  $layoutExpr = $routeViewMatch.Groups["layout"].Value

  $authorizeRouteView = @"
<AuthorizeRouteView RouteData="@routeData" DefaultLayout="@typeof($layoutExpr)">
            <NotAuthorized>
                <RedirectToLogin />
            </NotAuthorized>
        </AuthorizeRouteView>
"@

  $routerText = $routerText.Remove($routeViewMatch.Index, $routeViewMatch.Length).Insert($routeViewMatch.Index, $authorizeRouteView)
}

if ($routerText -notmatch "CascadingAuthenticationState") {
  $routerText = [regex]::Replace($routerText, "<Router\b", "<CascadingAuthenticationState>`r`n<Router", 1)
  $routerText = [regex]::Replace($routerText, "</Router>", "</Router>`r`n</CascadingAuthenticationState>", 1)
}

Write-TextIfChanged $routerPath $routerText

Info "Selesai. Login: /login | Admin shell: /admin"
Info "Credential lokal: Username admin | Password 12345678"
Info "Credential tersimpan di $localAuthPath dan sudah di-ignore Git."