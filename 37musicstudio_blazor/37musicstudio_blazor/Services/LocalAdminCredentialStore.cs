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
            "File local auth tidak ditemukan. Buat file .local/auth.local.json di host project Blazor.",
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