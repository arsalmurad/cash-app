# Windows release helper. Preflight reuses existing tools without installing.
# The release command retains wasm-pack's normal binding-tool/cache behaviour.
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$WasmToolchain = 'nightly'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$savedEnvironment = @{}
$names = @('PATH', 'CC_wasm32_unknown_unknown', 'AR_wasm32_unknown_unknown', 'CFLAGS_wasm32_unknown_unknown')
foreach ($name in $names) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Assert-Version([string]$Executable, [string[]]$Arguments, [string]$Expected) {
    $output = (& $Executable @Arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $output -notmatch $Expected) {
        throw "Pinned tool check failed for $Executable. Restore the recorded toolchain; preflight installs nothing."
    }
}

try {
    $env:PATH = "$repo\.toolchains\flutter\bin;$env:USERPROFILE\.cargo\bin;$env:PATH"
    # Honour explicit compiler paths, otherwise find only the known-working NDK.
    $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, 'D:\Android\Sdk') |
        Where-Object { $_ } | Select-Object -Unique
    $compilerDirectory = $null
    foreach ($sdk in $sdkRoots) {
        $candidate = Join-Path $sdk 'ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin'
        if (Test-Path -LiteralPath (Join-Path $candidate 'clang.exe')) {
            $compilerDirectory = $candidate
            break
        }
    }
    if (-not $env:CC_wasm32_unknown_unknown) {
        if (-not $compilerDirectory) { throw 'Pinned NDK 28.2 compiler missing. Set CC_wasm32_unknown_unknown to the recorded Clang 19.0.1 path.' }
        $env:CC_wasm32_unknown_unknown = Join-Path $compilerDirectory 'clang.exe'
    }
    if (-not $env:AR_wasm32_unknown_unknown) {
        if (-not $compilerDirectory) { throw 'Pinned NDK archive tool missing. Set AR_wasm32_unknown_unknown to the recorded llvm-ar 19.0.1 path.' }
        $env:AR_wasm32_unknown_unknown = Join-Path $compilerDirectory 'llvm-ar.exe'
    }
    Assert-Version 'rustup.exe' @('run', $WasmToolchain, 'rustc', '--version') '^rustc 1\.100\.0-nightly \(6eeff9a52 2026-09-23\)'
    Assert-Version 'flutter_rust_bridge_codegen.exe' @('--version') 'flutter_rust_bridge_codegen 2\.13\.0\b'
    Assert-Version 'wasm-pack.exe' @('--version') '^wasm-pack 0\.15\.0\b'
    Assert-Version $env:CC_wasm32_unknown_unknown @('--version') 'clang version 19\.0\.1\b'
    Assert-Version $env:AR_wasm32_unknown_unknown @('--version') 'LLVM version 19\.0\.1\b'
    $env:CFLAGS_wasm32_unknown_unknown = '-matomics -mbulk-memory'
    Write-Output "Pinned WASM compiler, archive tool and FRB verified; release build uses $WasmToolchain."
    if (-not $CheckOnly) {
        Push-Location (Join-Path $repo 'app')
        try {
            & flutter_rust_bridge_codegen.exe build-web --rust-root ../rust/api --release --wasm-pack-rustup-toolchain $WasmToolchain
            if ($LASTEXITCODE -ne 0) { throw 'Release WASM bridge build failed. Preserve caches and inspect the first compiler failure.' }
        } finally { Pop-Location }
    }
} finally {
    foreach ($name in $names) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
        }
    }
}
