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

$oldBlock = @'
            if (!response.IsSuccessStatusCode)
            {
                FormMessage = $"Upload Cloudinary via server gagal: {(int)response.StatusCode}. {TrimResponse(responseText)}";
                return;
            }

            var cloudinaryResult = JsonSerializer.Deserialize<CloudinaryUploadResponse>(responseText, LocalJsonOptions);
'@

$newBlock = @'
            var responseContentType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
            var responseLooksJson = responseText.TrimStart().StartsWith("{", StringComparison.Ordinal) ||
                responseContentType.Contains("json", StringComparison.OrdinalIgnoreCase);

            if (!response.IsSuccessStatusCode)
            {
                FormMessage = $"Upload Cloudinary via server gagal: {(int)response.StatusCode}. {TrimResponse(responseText)}";
                return;
            }

            if (!responseLooksJson)
            {
                FormMessage = $"Upload gagal: server mengembalikan non-JSON ({responseContentType}). Kemungkinan endpoint /cloudinary/upload belum aktif atau request diarahkan ke halaman login. Response awal: {TrimResponse(responseText)}";
                return;
            }

            var cloudinaryResult = JsonSerializer.Deserialize<CloudinaryUploadResponse>(responseText, LocalJsonOptions);
'@

if ($text.Contains($oldBlock)) {
  $text = $text.Replace($oldBlock, $newBlock)
} else {
  $pattern = '(?s)\s*if\s*\(!response\.IsSuccessStatusCode\)\s*\{\s*FormMessage\s*=\s*\$"Upload Cloudinary.*?return;\s*\}\s*var cloudinaryResult = JsonSerializer\.Deserialize<CloudinaryUploadResponse>\(responseText, LocalJsonOptions\);'

  if ($text -notmatch $pattern) {
    Fail "Block parse response upload tidak ditemukan. Kirim context sekitar responseText dan CloudinaryUploadResponse."
  }

  $text = [regex]::Replace($text, $pattern, "`r`n$newBlock", 1)
}

if ($text -notmatch 'responseLooksJson') {
  Fail "Guard non-JSON belum terpasang."
}

Write-TextIfChanged $galleryPath $text

Info "Selesai. Gallery sekarang tidak crash kalau /cloudinary/upload membalas HTML."