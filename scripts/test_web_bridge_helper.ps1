# Uses installed tools only; no build, install, cache deletion or SDK download.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$helper = Join-Path $PSScriptRoot 'build_web_bridge.ps1'
$wasm = Join-Path $repo 'app/web/pkg/rust_lib_cash_app_bg.wasm'
$beforeHash = if (Test-Path -LiteralPath $wasm) { (Get-FileHash -LiteralPath $wasm).Hash } else { $null }
$names = @('PATH', 'CC_wasm32_unknown_unknown', 'AR_wasm32_unknown_unknown', 'CFLAGS_wasm32_unknown_unknown')
$before = @{}
foreach ($name in $names) { $before[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    & $helper -CheckOnly
    $env:CC_wasm32_unknown_unknown = 'C:\cash-app-missing-compiler\clang.exe'
    $refused = $false
    try { & $helper -CheckOnly } catch { $refused = $true }
    if (-not $refused) { throw 'Missing compiler was not refused.' }
    if ($null -eq $before['CC_wasm32_unknown_unknown']) {
        Remove-Item -LiteralPath Env:CC_wasm32_unknown_unknown -ErrorAction SilentlyContinue
    } else {
        [Environment]::SetEnvironmentVariable('CC_wasm32_unknown_unknown', $before['CC_wasm32_unknown_unknown'], 'Process')
    }
    $refused = $false
    try { & $helper -CheckOnly -WasmToolchain stable } catch {
        if ($_.Exception.Message -notlike 'Pinned tool check failed*') { throw }
        $refused = $true
    }
    if (-not $refused) { throw 'Wrong compiler version was not refused.' }
    foreach ($name in $names) {
        if ([Environment]::GetEnvironmentVariable($name, 'Process') -cne $before[$name]) {
            throw "Helper changed caller environment: $name"
        }
    }
    $afterHash = if (Test-Path -LiteralPath $wasm) { (Get-FileHash -LiteralPath $wasm).Hash } else { $null }
    if ($beforeHash -cne $afterHash) { throw 'Check-only changed the WASM artifact.' }
    Write-Output 'PASS: pinned preflight, missing tool, wrong version, environment restoration and unchanged artifact.'
} finally {
    foreach ($name in $names) {
        if ($null -eq $before[$name]) {
            Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $before[$name], 'Process')
        }
    }
}
