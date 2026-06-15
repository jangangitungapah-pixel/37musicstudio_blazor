$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ROOT = (Get-Location).Path
$STAMP = Get-Date -Format "yyyyMMddHHmmss"

function Fail($message) { throw "[FAILED] $message" }
function Info($message) { Write-Host "[OK] $message" }
function Is-IgnoredPath($path) { return $path -match "\\(bin|obj|node_modules|TestResults|\.git)\\" }
function Read-Text($path) { [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }

function Write-TextIfChanged($path, $content) {
  $old = ""
  if (Test-Path $path) { $old = Read-Text $path }

  if ($old -ne $content) {
    Copy-Item $path "$path.bak-$STAMP" -Force
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
    Info "Updated: $path"
  } else {
    Info "No changes: $path"
  }
}

$clientProject = Get-ChildItem -Path $ROOT -Recurse -File -Filter "*.Client.csproj" |
  Where-Object { -not (Is-IgnoredPath $_.FullName) } |
  Sort-Object FullName |
  Select-Object -First 1

$hostProject = Get-ChildItem -Path $ROOT -Recurse -File -Filter "*.csproj" |
  Where-Object {
    -not (Is-IgnoredPath $_.FullName) -and
    $_.Name -notmatch "\.Client\.csproj$" -and
    $_.Name -notmatch "(Test|Tests)\.csproj$" -and
    (Test-Path (Join-Path $_.DirectoryName "Program.cs"))
  } |
  Sort-Object FullName |
  Select-Object -First 1

if (-not $clientProject) { Fail "Client project tidak ditemukan." }
if (-not $hostProject) { Fail "Host project tidak ditemukan." }

$galleryPath = Join-Path $clientProject.DirectoryName "Pages\Gallery.razor"
$programPath = Join-Path $hostProject.DirectoryName "Program.cs"

if (-not (Test-Path $galleryPath)) { Fail "Gallery.razor tidak ditemukan." }
if (-not (Test-Path $programPath)) { Fail "Program.cs tidak ditemukan." }

# =========================================================
# 1) Program.cs: endpoint signature jangan pakai JSON body.
#    Pakai query string folder supaya tidak ada error content-type.
# =========================================================

$programText = Read-Text $programPath

if ($programText -notmatch '"/cloudinary/sign-upload"') {
  Fail "Endpoint /cloudinary/sign-upload tidak ditemukan di Program.cs."
}

$programText = $programText.Replace(
  'app.MapPost("/cloudinary/sign-upload", async (CloudinarySignatureRequest request, IWebHostEnvironment environment) =>',
  'app.MapPost("/cloudinary/sign-upload", async (string? folder, IWebHostEnvironment environment) =>'
)

$oldFolderBlock = @'
        var options = await CloudinaryUploadSupport.LoadOptionsAsync(environment.ContentRootPath);
        var folder = string.IsNullOrWhiteSpace(request.Folder)
            ? options.Folder
            : request.Folder.Trim();

        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
'@

$newFolderBlock = @'
        var options = await CloudinaryUploadSupport.LoadOptionsAsync(environment.ContentRootPath);
        var resolvedFolder = string.IsNullOrWhiteSpace(folder)
            ? options.Folder
            : folder.Trim();

        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
'@

if ($programText.Contains($oldFolderBlock)) {
  $programText = $programText.Replace($oldFolderBlock, $newFolderBlock)
} elseif ($programText -notmatch 'var\s+resolvedFolder\s*=') {
  Fail "Anchor folder block endpoint Cloudinary tidak ditemukan."
}

$programText = $programText.Replace(
  '        if (!string.IsNullOrWhiteSpace(folder))
        {
            parameters["folder"] = folder;
        }',
  '        if (!string.IsNullOrWhiteSpace(resolvedFolder))
        {
            parameters["folder"] = resolvedFolder;
        }'
)

$programText = $programText.Replace(
  '            folder ?? string.Empty',
  '            resolvedFolder ?? string.Empty'
)

if ($programText -match 'CloudinarySignatureRequest request') {
  Fail "Endpoint masih memakai CloudinarySignatureRequest sebagai body."
}

if ($programText -notmatch 'async\s*\(string\?\s+folder,\s+IWebHostEnvironment\s+environment\)') {
  Fail "Endpoint belum memakai query string folder."
}

if ($programText -notmatch 'resolvedFolder') {
  Fail "resolvedFolder belum terpasang."
}

Write-TextIfChanged $programPath $programText

# =========================================================
# 2) Gallery.razor: request signature pakai query string,
#    bukan PostAsJsonAsync body.
# =========================================================

$galleryText = Read-Text $galleryPath

if ($galleryText -notmatch '@inject\s+NavigationManager\s+NavigationManager') {
  if ($galleryText -match '@inject\s+HttpClient\s+Http') {
    $galleryText = [regex]::Replace(
      $galleryText,
      '(@inject\s+HttpClient\s+Http)',
      "`$1`r`n@inject NavigationManager NavigationManager",
      1
    )
  } else {
    Fail "Anchor @inject HttpClient Http tidak ditemukan."
  }
}

$galleryText = [regex]::Replace(
  $galleryText,
  '(?s)var signatureResponse = await Http\.PostAsJsonAsync\(\s*NavigationManager\.ToAbsoluteUri\("/cloudinary/sign-upload"\),\s*new CloudinarySignatureRequest\(CloudinarySettings\.Folder\?\.Trim\(\) \?\? string\.Empty\)\);',
  'var signatureEndpoint = BuildCloudinarySignatureUri();
            var signatureResponse = await Http.PostAsync(signatureEndpoint, content: null);'
)

$galleryText = [regex]::Replace(
  $galleryText,
  '(?s)var signatureResponse = await Http\.PostAsJsonAsync\(\s*"cloudinary/sign-upload",\s*new CloudinarySignatureRequest\(CloudinarySettings\.Folder\?\.Trim\(\) \?\? string\.Empty\)\);',
  'var signatureEndpoint = BuildCloudinarySignatureUri();
            var signatureResponse = await Http.PostAsync(signatureEndpoint, content: null);'
)

if ($galleryText -match 'PostAsJsonAsync\(\s*NavigationManager\.ToAbsoluteUri\("/cloudinary/sign-upload"\)') {
  Fail "Masih ada PostAsJsonAsync ke endpoint signature."
}

if ($galleryText -notmatch 'BuildCloudinarySignatureUri') {
  $helperMethod = @'
    private Uri BuildCloudinarySignatureUri()
    {
        var folder = CloudinarySettings.Folder?.Trim() ?? string.Empty;
        var query = string.IsNullOrWhiteSpace(folder)
            ? string.Empty
            : $"?folder={Uri.EscapeDataString(folder)}";

        return NavigationManager.ToAbsoluteUri($"/cloudinary/sign-upload{query}");
    }

'@

  $anchor = '    private async Task UploadSelectedImageAsync()'

  if (-not $galleryText.Contains($anchor)) {
    Fail "Anchor UploadSelectedImageAsync tidak ditemukan."
  }

  $galleryText = $galleryText.Replace($anchor, "$helperMethod$anchor")
}

if ($galleryText -notmatch 'Http\.PostAsync\(signatureEndpoint,\s*content:\s*null\)') {
  Fail "Request signature belum memakai PostAsync tanpa body."
}

if ($galleryText -notmatch 'private\s+Uri\s+BuildCloudinarySignatureUri\s*\(') {
  Fail "BuildCloudinarySignatureUri belum ada."
}

$galleryText = [regex]::Replace($galleryText, "(`r?`n){3,}", "`r`n`r`n")

Write-TextIfChanged $galleryPath $galleryText

Info "Selesai. Endpoint signature Cloudinary tidak lagi butuh JSON body."