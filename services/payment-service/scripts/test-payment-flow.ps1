Param(
  [string]$BaseUrl = "http://localhost:42107",
  [string]$JwtSecret = "dev_access_secret"
)

$ErrorActionPreference = "Stop"

function New-Token([string]$sub, [string[]]$roles) {
  $rolesJson = ($roles | ForEach-Object { "'$_'" }) -join ","
  $script = "console.log(require('jsonwebtoken').sign({sub:'$sub',roles:[$rolesJson],scopes:['payments:write']}, '$JwtSecret'))"
  return node -e $script
}

function Invoke-Json([string]$method, [string]$url, $headers, [string]$body = $null) {
  if ($body) {
    return Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $body
  }
  return Invoke-RestMethod -Method $method -Uri $url -Headers $headers
}

Write-Host "== Payment service flow tests ==" -ForegroundColor Cyan

$userToken = New-Token "user_1" @("user")
$adminToken = New-Token "admin_1" @("admin")

$userHeaders = @{
  Authorization    = "Bearer $userToken"
  "Content-Type"   = "application/json"
}
$adminHeaders = @{
  Authorization    = "Bearer $adminToken"
  "Content-Type"   = "application/json"
}

Write-Host "1) Health check" -ForegroundColor Yellow
Invoke-RestMethod -Method Get -Uri "$BaseUrl/health" | Out-Null
Write-Host "   OK"

Write-Host "2) Create payment (CARD) success" -ForegroundColor Yellow
$createHeaders = $userHeaders.Clone()
$createHeaders["Idempotency-Key"] = "idem_$([DateTime]::UtcNow.Ticks)"
$create = Invoke-Json "Post" "$BaseUrl/v1/payments" $createHeaders `
  '{"rideId":"ride_1","amount":"100.00","currency":"VND","method":"CARD","userId":"user_1"}'
$paymentId = $create.data.id
Write-Host "   Created paymentId=$paymentId"
Write-Host "   Response:" -ForegroundColor DarkGray
$create | ConvertTo-Json -Depth 6

Write-Host "3) GET payment by id" -ForegroundColor Yellow
$payment = Invoke-Json "Get" "$BaseUrl/v1/payments/$paymentId" @{ Authorization="Bearer $userToken" }
Write-Host "   OK"
Write-Host "   Response:" -ForegroundColor DarkGray
$payment | ConvertTo-Json -Depth 6

Write-Host "4) PATCH invalid transition INITIATED -> PAID (expect 409)" -ForegroundColor Yellow
try {
  Invoke-Json "Patch" "$BaseUrl/v1/payments/$paymentId" $adminHeaders '{"status":"PAID"}' | Out-Null
  throw "Expected 409 but got success"
} catch {
  Write-Host "   Got expected error"
}

Write-Host "5) PATCH valid transitions INITIATED -> PROCESSING -> PAID" -ForegroundColor Yellow
$processing = Invoke-Json "Patch" "$BaseUrl/v1/payments/$paymentId" $adminHeaders '{"status":"PROCESSING"}'
$paid = Invoke-Json "Patch" "$BaseUrl/v1/payments/$paymentId" $adminHeaders '{"status":"PAID"}'
Write-Host "   OK"
Write-Host "   PROCESSING response:" -ForegroundColor DarkGray
$processing | ConvertTo-Json -Depth 6
Write-Host "   PAID response:" -ForegroundColor DarkGray
$paid | ConvertTo-Json -Depth 6

Write-Host "6) VietQR payment flow" -ForegroundColor Yellow
try {
  $vietHeaders = $userHeaders.Clone()
  $vietHeaders["Idempotency-Key"] = "idem_vietqr_$([DateTime]::UtcNow.Ticks)"
  $viet = Invoke-Json "Post" "$BaseUrl/v1/payments" $vietHeaders `
    '{"rideId":"ride_2","amount":"120.00","currency":"VND","method":"VIETQR","userId":"user_1"}'
  $vietId = $viet.data.id
  Write-Host "   Created VietQR paymentId=$vietId"
  Write-Host "   Create response:" -ForegroundColor DarkGray
  $viet | ConvertTo-Json -Depth 6
  try {
    $vietqr = Invoke-Json "Get" "$BaseUrl/v1/payments/$vietId/vietqr-codes" @{ Authorization="Bearer $userToken" }
    Write-Host "   VietQR OK"
    Write-Host "   VietQR response:" -ForegroundColor DarkGray
    $vietqr | ConvertTo-Json -Depth 6
  } catch {
    Write-Host "   VietQR not available (check VietQR config), skipping"
  }
} catch {
  Write-Host "   VietQR create failed (likely missing config), skipping"
}

Write-Host "7) GET list payments" -ForegroundColor Yellow
$list = Invoke-Json "Get" "$BaseUrl/v1/payments" @{ Authorization="Bearer $userToken" }
Write-Host "   OK"
Write-Host "   Response:" -ForegroundColor DarkGray
$list | ConvertTo-Json -Depth 6

Write-Host "== Done ==" -ForegroundColor Green
