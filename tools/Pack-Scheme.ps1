param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][string]$Output
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$packageDirectory = (Resolve-Path -LiteralPath $Directory).Path
$outputPath = [IO.Path]::GetFullPath($Output)
if ($outputPath.StartsWith($packageDirectory + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Output ZIP must be outside the payload directory.' }
$manifestPath = Join-Path $packageDirectory 'manifest.json'
$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$hashes = [ordered]@{}
$payloadFiles = Get-ChildItem -LiteralPath $packageDirectory -Recurse -File | Where-Object { $_.FullName -ne $manifestPath }
foreach ($payloadFile in $payloadFiles) {
    $relativePath = $payloadFile.FullName.Substring($packageDirectory.Length + 1).Replace('\', '/')
    if ($relativePath -notmatch '^[A-Za-z0-9._/-]{1,240}$' -or ($relativePath.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' })) { throw "Invalid payload path: $relativePath" }
    $hashes[$relativePath] = (Get-FileHash -LiteralPath $payloadFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
if (-not $hashes.Contains('entry.sh')) { throw 'Missing entry.sh' }
$manifest | Add-Member -NotePropertyName files -NotePropertyValue $hashes -Force
$manifestJson = $manifest | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Split-Path $outputPath -Parent) -Force | Out-Null
$zipStream = [IO.File]::Open($outputPath, [IO.FileMode]::Create)
$archive = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($payloadFile in Get-ChildItem -LiteralPath $packageDirectory -Recurse -File) {
        $relativePath = $payloadFile.FullName.Substring($packageDirectory.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry($relativePath, [IO.Compression.CompressionLevel]::Optimal)
        $input = $payloadFile.OpenRead()
        $destination = $entry.Open()
        try { $input.CopyTo($destination) } finally { $destination.Dispose(); $input.Dispose() }
    }
} finally { $archive.Dispose(); $zipStream.Dispose() }
Write-Output "Packed: $outputPath"
