<#
    Start the full CAB Booking System stack (Docker infra + 3 UIs) with one command.

    Usage examples:
      .\scripts\start-all.ps1                  # Start infra + UIs
      .\scripts\start-all.ps1 -Observability   # Include observability stack
      .\scripts\start-all.ps1 -SkipUi          # Only infra (no UIs)
      .\scripts\start-all.ps1 -Seed            # Seed demo data after infra is up

    Requirements: Docker Desktop running, Docker Compose, Node.js 18+, npm.
#>

[CmdletBinding()]
param(
    [switch] $Observability,
    [switch] $SkipInfra,
    [switch] $SkipUi,
    [switch] $Seed,
    [switch] $NoInstall,
    [switch] $SkipKafkaBootstrap,
    [switch] $KafkaVerbose
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
function Get-PrimaryIPv4 {
    $candidates = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object {
        $_.IPv4Address -and $_.IPv4Address.Count -gt 0 -and $_.NetAdapter.Status -eq 'Up'
    } | Sort-Object `
        { if ($_.InterfaceAlias -match 'vEthernet|Hyper-V|Loopback') { 2 } else { 0 } }, `
        { if ($_.IPv4DefaultGateway) { 0 } else { 1 } }

    if (-not $candidates) {
        throw "Không tìm thấy IPv4 hợp lệ (interface Up). Kiểm tra kết nối mạng."
    }

    $primary = $candidates[0].IPv4Address[0].IPAddress
    return $primary
}

function Set-ExpoBaseUrl {
    param(
        [string] $EnvPath,
        [string] $Ip
    )

    if (-not (Test-Path $EnvPath)) {
        throw "Không tìm thấy file $EnvPath để cập nhật EXPO_PUBLIC_API_BASE_URL."
    }

    $baseUrl = "EXPO_PUBLIC_API_BASE_URL=http://$Ip`:42100"
    $pattern = '^\s*EXPO_PUBLIC_API_BASE_URL\s*='
    $lines = Get-Content $EnvPath

    # Remove any existing lines for this key (covers spacing / duplicate cases)
    $lines = $lines | Where-Object { $_ -notmatch $pattern }
    # Append the fresh value once
    $lines += $baseUrl

    Set-Content -Path $EnvPath -Value $lines -Encoding ASCII
}

function Ensure-Command {
    param([string] $Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required but not found. Install it and retry."
    }
}

function Ensure-DockerRunning {
    try {
        docker info | Out-Null
    } catch {
        throw "Docker Desktop is not running. Please start it and rerun the script."
    }
}

function Run-NpmScript {
    param([string] $ScriptName)
    npm run $ScriptName
    if ($LASTEXITCODE -ne 0) {
        throw "npm run $ScriptName failed. Check the output above."
    }
}

function Maybe-InstallDependencies {
    param([string] $Path)
    if ($NoInstall) { return }
    if (-not (Test-Path (Join-Path $Path "node_modules"))) {
        Write-Host "Installing dependencies in $Path ..."
        Push-Location $Path
        npm install
        Pop-Location
    }
}

Push-Location $repoRoot
Write-Host "Repo root: $repoRoot"

Ensure-Command "docker"
Ensure-Command "npm"
Ensure-DockerRunning

$composeScript = if ($Observability) { "dev:observability" } else { "dev:infra" }

if (-not $SkipInfra) {
    $running = docker compose --env-file .env -f infra/docker-compose.dev.yml ps -q 2>$null | Select-Object -First 1
    if ($running) {
        Write-Host "Docker stack already running -> skipping 'npm run $composeScript'. Use -SkipInfra:$false to force rerun."
    } else {
        Write-Host "Starting backend stack with 'npm run $composeScript' ..."
        Run-NpmScript $composeScript
    }

    if (-not $SkipKafkaBootstrap) {
        if (-not $env:KAFKA_BOOTSTRAP_WAIT_ATTEMPTS) { $env:KAFKA_BOOTSTRAP_WAIT_ATTEMPTS = 120 }
        if (-not $env:KAFKA_BOOTSTRAP_WAIT_MS) { $env:KAFKA_BOOTSTRAP_WAIT_MS = 2000 }
        if ($KafkaVerbose) { $env:KAFKA_BOOTSTRAP_VERBOSE = "true" }

        Write-Host "Bootstrapping Kafka topics ..."
        try {
            Run-NpmScript "kafka:topics:bootstrap"
        } catch {
            Write-Warning "Kafka topic bootstrap failed: $($_.Exception.Message). Stack is still up; rerun with -SkipInfra:$false after Kafka is healthy."
        }
    } else {
        Write-Host "SkipKafkaBootstrap requested -> skipping Kafka topic bootstrap."
    }

    if ($Seed) {
        Write-Host "Seeding demo data (npm run seed:all) ..."
        Run-NpmScript "seed:all"
    }
} else {
    Write-Host "SkipInfra requested -> not touching Docker stack."
}

Pop-Location

function Update-ExpoEnv {
    $ip = Get-PrimaryIPv4
    Write-Host "Detected IPv4: $ip -> cập nhật EXPO_PUBLIC_API_BASE_URL cho customer & driver ..."

    $expoEnvPaths = @(
        "$repoRoot\apps\customer-app\.env",
        "$repoRoot\apps\driver-app\.env"
    )

    foreach ($envPath in $expoEnvPaths) {
        if (Test-Path $envPath) {
            Set-ExpoBaseUrl -EnvPath $envPath -Ip $ip
            Write-Host "  -> updated $envPath"
        } else {
            Write-Warning "  -> skip $envPath (không tìm thấy file)"
        }
    }
}

function Start-Ui {
    param(
        [string] $Name,
        [string] $Path,
        [string] $Script
    )

    Write-Host "Launching $Name (npm run $Script) ..."
    Maybe-InstallDependencies -Path $Path

    Start-Process -FilePath "powershell" -WorkingDirectory $Path -ArgumentList "-NoExit", "-Command", "npm run $Script" | Out-Null
    Write-Host "  -> started in its own terminal window."
}

if (-not $SkipUi) {
    Update-ExpoEnv
    Start-Ui -Name "Admin Dashboard" -Path "$repoRoot\apps\admin-dashboard" -Script "dev"
    Start-Ui -Name "Driver App (Expo QR)" -Path "$repoRoot\apps\driver-app" -Script "start"
    Start-Ui -Name "Customer App (Expo QR)" -Path "$repoRoot\apps\customer-app" -Script "start"
} else {
    Write-Host "SkipUi requested -> UI apps will not be launched."
}

Write-Host ""
Write-Host "All services launched."
Write-Host "Quick access:"
Write-Host "  API Gateway:   http://localhost:42100"
Write-Host "  Admin UI:      http://localhost:42170  (user: admin@cab.local / password)"
Write-Host "  Customer Expo: scan QR in its terminal; Metro http://localhost:42181"
Write-Host "  Driver Expo:   scan QR in its terminal; Metro http://localhost:42182"
Write-Host "  PgAdmin:       http://localhost:42137  (user: admin@example.com / admin123)"
Write-Host ""
Write-Host "Seeded demo accounts (Auth service):"
Write-Host "  Admin:    admin@cab.local / password"
Write-Host "  Customer: customer@cab.local / 123456"
Write-Host "  Driver:   driver@cab.local / password"
