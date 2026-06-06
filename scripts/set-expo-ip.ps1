<#
  Set EXPO_PUBLIC_API_BASE_URL for both Expo apps (customer & driver) based on host IPv4.

  Usage:
    .\scripts\set-expo-ip.ps1            # auto-pick primary IPv4
    .\scripts\set-expo-ip.ps1 -Ip 192.168.56.1  # force a specific IP

  Notes:
    - Updates only EXPO_PUBLIC_API_BASE_URL lines in:
        apps/customer-app/.env
        apps/driver-app/.env
    - Leaves other lines untouched.
#>

[CmdletBinding()]
param(
    [string] $Ip
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Pick-IPv4 {
    param([string] $PreferredIp)
    if ($PreferredIp) { return $PreferredIp }

    $candidates = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.IPv4Address -and $_.IPv4Address.Count -gt 0 -and $_.NetAdapter.Status -eq 'Up'
    } | Sort-Object `
        { if ($_.InterfaceAlias -match 'vEthernet|Hyper-V|Loopback') { 2 } else { 0 } }, `
        { if ($_.IPv4DefaultGateway) { 0 } else { 1 } }

    if (-not $candidates) {
        throw "No valid IPv4 found (interface Up). Pass -Ip to override."
    }

    return $candidates[0].IPv4Address[0].IPAddress
}

function Update-EnvFile {
    param(
        [string] $Path,
        [string] $Ip
    )
    if (-not (Test-Path $Path)) {
        Write-Warning "$Path not found, skipping."
        return
    }

    $newLine = "EXPO_PUBLIC_API_BASE_URL=http://$Ip`:42100"
    $lines = Get-Content $Path
    $found = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match '^EXPO_PUBLIC_API_BASE_URL=') {
            $found = $true
            $newLine
        } else {
            $_
        }
    }
    if (-not $found) { $lines += $newLine }
    Set-Content -Path $Path -Value $lines -Encoding ASCII
    Write-Host "Updated $Path -> $newLine"
}

$chosenIp = Pick-IPv4 -PreferredIp $Ip
Write-Host "Using IPv4: $chosenIp"

Update-EnvFile -Path (Join-Path $repoRoot "apps/customer-app/.env") -Ip $chosenIp
Update-EnvFile -Path (Join-Path $repoRoot "apps/driver-app/.env") -Ip $chosenIp

Write-Host "Done. Restart Expo to apply."
