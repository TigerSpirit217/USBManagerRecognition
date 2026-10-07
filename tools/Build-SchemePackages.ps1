param(
    [string]$SdkPath = $env:ANDROID_SDK_ROOT,
    [string]$NdkVersion = '30.0.16248370',
    [string]$BuildToolsVersion = '37.0.0',
    [ValidateSet('armeabi-v7a', 'arm64-v8a', 'x86', 'x86_64', 'riscv64')]
    [string[]]$Abis = @('armeabi-v7a', 'arm64-v8a', 'x86', 'x86_64', 'riscv64')
)
$ErrorActionPreference = 'Stop'
if (-not $SdkPath) { $SdkPath = $env:ANDROID_HOME }
if (-not $SdkPath) { throw 'Provide -SdkPath or set ANDROID_SDK_ROOT.' }
$sdkDirectory = (Resolve-Path -LiteralPath $SdkPath).Path
$projectDirectory = Split-Path $PSScriptRoot -Parent
$buildDirectory = Join-Path $projectDirectory ('build/' + [guid]::NewGuid().ToString())
$classDirectory = Join-Path $buildDirectory 'classes'
$dexDirectory = Join-Path $buildDirectory 'dex'
$nativeDirectory = Join-Path $buildDirectory 'native'
New-Item -ItemType Directory -Path $classDirectory,$dexDirectory,$nativeDirectory -Force | Out-Null
$javaSources = @(Get-ChildItem -LiteralPath (Join-Path $projectDirectory 'runtime/java') -Recurse -Filter '*.java' | ForEach-Object { $_.FullName })
& javac '-J-Duser.language=en' --release 8 -Xlint:-options -encoding UTF-8 -d $classDirectory @javaSources
if ($LASTEXITCODE -ne 0) { throw 'Java daemon compilation failed.' }
$classFiles = @(Get-ChildItem -LiteralPath $classDirectory -Recurse -Filter '*.class' | ForEach-Object { $_.FullName })
& (Join-Path $sdkDirectory "build-tools/$BuildToolsVersion/d8.bat") --release --min-api 26 --output $dexDirectory @classFiles
if ($LASTEXITCODE -ne 0) { throw 'Daemon DEX compilation failed.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$daemonJar = Join-Path $buildDirectory 'daemon.jar'
[IO.Compression.ZipFile]::CreateFromDirectory($dexDirectory, $daemonJar)
$ndkArguments = @(
    'NDK_PROJECT_PATH=null',
    "APP_BUILD_SCRIPT=$(Join-Path $projectDirectory 'runtime/native/Android.mk')",
    "NDK_APPLICATION_MK=$(Join-Path $projectDirectory 'runtime/native/Application.mk')",
    "NDK_OUT=$(Join-Path $nativeDirectory 'obj')",
    "NDK_LIBS_OUT=$(Join-Path $nativeDirectory 'lib')",
    "APP_ABI=$($Abis -join ' ')",
    'NDK_DEBUG=0'
)
& (Join-Path $sdkDirectory "ndk/$NdkVersion/ndk-build.cmd") @ndkArguments
if ($LASTEXITCODE -ne 0) { throw 'Native daemon compilation failed.' }
foreach ($schemeDirectory in Get-ChildItem -LiteralPath (Join-Path $projectDirectory 'schemes') -Directory) {
    $metadataPath = Join-Path $schemeDirectory.FullName 'scheme.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) { continue }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $packageDirectory = Join-Path $buildDirectory ('packages/' + $metadata.id)
    $runtimeDirectory = Join-Path $packageDirectory 'runtime'
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    foreach ($name in @('entry.sh', 'scheme.sh')) {
        Copy-Item -LiteralPath (Join-Path $schemeDirectory.FullName $name) -Destination (Join-Path $packageDirectory $name)
    }
    Copy-Item -LiteralPath $daemonJar -Destination (Join-Path $runtimeDirectory 'daemon.jar')
    Copy-Item -LiteralPath (Join-Path $projectDirectory 'runtime/usb_auth_root.sh') -Destination (Join-Path $runtimeDirectory 'usb_auth_root.sh')
    Copy-Item -LiteralPath (Join-Path $projectDirectory 'runtime/LICENSE') -Destination (Join-Path $runtimeDirectory 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $nativeDirectory 'lib') -Destination (Join-Path $packageDirectory 'lib') -Recurse
    $metadata | Add-Member -NotePropertyName abis -NotePropertyValue @($Abis) -Force
    $json = $metadata | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText((Join-Path $packageDirectory 'manifest.json'), $json, [Text.UTF8Encoding]::new($false))
    $suffix = if ($Abis.Count -eq 5) { 'universal' } else { $Abis -join '_' }
    & (Join-Path $PSScriptRoot 'Pack-Scheme.ps1') -Directory $packageDirectory -Output (Join-Path $projectDirectory "dist/$($metadata.id)-$($metadata.version)-$suffix.zip")
}
