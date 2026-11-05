# Creates or updates the SmartThings rule that tells the Honeywell T6 (HomeKit local) which rooms ask for heat.
# Per room: temperature below its heating setpoint -> setRoom(room, "on"), otherwise setRoom(room, "off").
# Needs the SmartThings CLI (https://github.com/SmartThingsCommunity/smartthings-cli), logged in.
#
# Interactive:     powershell -ExecutionPolicy Bypass -File heat-demand-rule.ps1
# Non-interactive: heat-demand-rule.ps1 -RoomIds "<deviceId>,<deviceId>" [-RuleName "My rule"] [-DryRun]
# Remove the rule again in the SmartThings app (Routines) or with: smartthings rules:delete <ruleId>
param(
  [string]$Cli = "smartthings",
  [string]$RuleName = "Heat demand (Honeywell T6)",
  [string]$RoomIds = "",
  [string]$T6Id = "",
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8 # read the CLI output as UTF-8 (names with accents)
$cap = "silvervalley08660.heatDemand"

function Get-Json($argsList) {
  $o = & $Cli @argsList 2>$null | Out-String
  if (-not $o.Trim()) { throw "SmartThings CLI gave no output for: $($argsList -join ' ')" }
  $j = $o | ConvertFrom-Json
  foreach ($e in $j) { $e } # Windows PowerShell 5 returns a JSON array as one object: emit its elements
}
function Has-Cap($d, $id) {
  foreach ($c in $d.components) {
    if ($c.id -eq "main") { foreach ($k in $c.capabilities) { if ($k.id -eq $id) { return $true } } }
  }
  return $false
}

$devs = @(Get-Json @("devices", "-j"))

# the thermostat
$t6s = @($devs | Where-Object { Has-Cap $_ $cap })
if ($T6Id) { $t6s = @($t6s | Where-Object { $_.deviceId -eq $T6Id }) }
if ($t6s.Count -eq 0) { Write-Host "No Honeywell T6 (HomeKit local) device with Heat Demand found. Update the driver first."; exit 1 }
$t6 = $t6s[0]
if ($t6s.Count -gt 1) {
  for ($i = 0; $i -lt $t6s.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $t6s[$i].label) }
  $t6 = $t6s[[int](Read-Host "Which thermostat") - 1]
}
Write-Host "Thermostat: $($t6.label)"

# the rooms: every device with temperature and heating setpoint in the same location
$cands = @($devs | Where-Object { $_.deviceId -ne $t6.deviceId -and $_.locationId -eq $t6.locationId -and
  (Has-Cap $_ "temperatureMeasurement") -and (Has-Cap $_ "thermostatHeatingSetpoint") } | Sort-Object label)
if ($RoomIds) {
  $want = $RoomIds -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  $rooms = @($cands | Where-Object { $want -contains $_.deviceId })
} else {
  Write-Host "Room thermostats (temperature + heating setpoint):"
  for ($i = 0; $i -lt $cands.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $cands[$i].label) }
  $pick = Read-Host "Numbers of the rooms that count, separated by commas (e.g. 1,3,4)"
  $rooms = @($pick -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } |
    ForEach-Object { $cands[[int]$_ - 1] })
}
if ($rooms.Count -eq 0) { Write-Host "No rooms chosen."; exit 1 }

function Dev($id, $c, $a) {
  return @{ device = @{ devices = @($id); component = "main"; capability = $c; attribute = $a; trigger = "Always" } }
}
function Cmd($name, $state) {
  return ,@(@{ command = @{ devices = @($t6.deviceId); commands = @(@{ component = "main"; capability = $cap;
    command = "setRoom"; arguments = @(@{ string = $name }, @{ string = $state }) }) } })
}
$actions = @()
foreach ($r in $rooms) {
  $name = ($r.label -replace '\s+', ' ').Trim()
  if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
  Write-Host "  room: $name"
  $actions += @{ "if" = @{
    lessThan = @{ left = (Dev $r.deviceId "temperatureMeasurement" "temperature");
                  right = (Dev $r.deviceId "thermostatHeatingSetpoint" "heatingSetpoint") }
    "then" = (Cmd $name "on"); "else" = (Cmd $name "off") } }
}
$body = @{ name = $RuleName; actions = $actions }
$file = Join-Path $env:TEMP "heat-demand-rule.json"
[IO.File]::WriteAllText($file, ($body | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))
Write-Host "Rule written to $file"
if ($DryRun) { exit 0 }

$loc = $t6.locationId
$existing = @(Get-Json @("rules", "--location", $loc, "-j") | Where-Object { $_.name -eq $RuleName }) | Select-Object -First 1
if ($existing) {
  & $Cli rules:update $existing.id -i $file --location $loc -j | Out-Null
  Write-Host "Rule '$RuleName' updated ($($rooms.Count) rooms)."
} else {
  & $Cli rules:create -i $file --location $loc -j | Out-Null
  Write-Host "Rule '$RuleName' created ($($rooms.Count) rooms)."
}
Write-Host "Run this script again to change the rooms. A new custom capability can take a few minutes before rules accept it."
