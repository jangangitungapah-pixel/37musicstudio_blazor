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