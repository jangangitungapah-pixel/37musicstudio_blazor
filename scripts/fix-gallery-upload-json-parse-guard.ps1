$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ROOT = (Get-Location).Path
$STAMP = Get-Date -Format "yyyyMMddHHmmss"

function Fail($message) { throw "[FAILED] $message" }
function Info($message) { Write-Host "[OK] $message" }
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

$galleryPath = Join-Path $ROOT "37musicstudio_blazor\37musicstudio_blazor.Client\Pages\Gallery.razor"

if (-not (Test-Path $galleryPath)) {
  Fail "Gallery.razor tidak ditemukan: $galleryPath"
}

$text = Read-Text $galleryPath

$old = @'
            var cloudinaryResult = JsonSerializer.Deserialize<CloudinaryUploadResponse>(responseText, LocalJsonOptions);

            if (cloudinaryResult is null || string.IsNullOrWhiteSpace(cloudinaryResult.SecureUrl))
            {
                FormMessage = "Upload berhasil, tapi response Cloudinary tidak lengkap.";
                return;
            }
'@

$new = @'
            CloudinaryUploadResponse? cloudinaryResult;

            try
            {
                cloudinaryResult = JsonSerializer.Deserialize<CloudinaryUploadResponse>(responseText, LocalJsonOptions);
            }
            catch (JsonException)
            {
                FormMessage = $"Upload gagal: server tidak mengembalikan JSON valid. Response awal: {TrimResponse(responseText)}";
                return;
            }

            if (cloudinaryResult is null || string.IsNullOrWhiteSpace(cloudinaryResult.SecureUrl))
            {
                FormMessage = $"Upload berhasil, tapi response Cloudinary tidak lengkap. Response awal: {TrimResponse(responseText)}";
                return;
            }
'@

if ($text.Contains($old)) {
  $text = $text.Replace($old, $new)
} elseif ($text -notmatch 'catch\s*\(JsonException\)') {
  Fail "Block JsonSerializer.Deserialize<CloudinaryUploadResponse> tidak cocok. Kirim context sekitar baris deserialize."
}

if ($text -notmatch 'catch\s*\(JsonException\)') {
  Fail "Guard JsonException belum terpasang."
}

Write-TextIfChanged $galleryPath $text

Info "Selesai. Gallery tidak akan crash kalau response upload bukan JSON."