[CmdletBinding()]
param(
  [ValidateSet('check','diagnose','report')]
  [string]$Mode = 'check',
  [switch]$OnlineChecks,
  [switch]$JsonOnly,
  [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PhoenixVersion = '0.1'
$VaultRelative = 'OECUMENE_HUB\10_VAULTS\OECUMENE_Corpus'
$ExportRoot = 'AI-Export'
$LocalStateRoot = Join-Path $env:LOCALAPPDATA 'OECUMENE'
$LocalEnvironmentFile = Join-Path $LocalStateRoot 'environment.json'
$DefaultReportRoot = Join-Path $LocalStateRoot 'phoenix'

function Add-Finding {
  param(
    [System.Collections.ArrayList]$List,
    [string]$Id,
    [ValidateSet('PASS','WARN','FAIL','INFO')]
    [string]$Status,
    [string]$Message,
    [string]$RepairHint
  )

  [void]$List.Add([pscustomobject]@{
    id = $Id
    status = $Status
    message = $Message
    repair_hint = $RepairHint
  })
}

function Read-JsonSafe([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
  catch { return $null }
}

function Find-OecumeneVaultCandidates {
  $items = @()
  foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
    if (-not $drive.Root) { continue }
    $vault = Join-Path $drive.Root $VaultRelative
    if (Test-Path -LiteralPath $vault -PathType Container) {
      $items += [pscustomobject]@{
        drive = $drive.Name
        vault_path = $vault
        has_obsidian = Test-Path -LiteralPath (Join-Path $vault '.obsidian') -PathType Container
        has_export = Test-Path -LiteralPath (Join-Path $vault $ExportRoot) -PathType Container
        has_vault_manifest = Test-Path -LiteralPath (Join-Path $vault '.oecumene-environment.json') -PathType Leaf
      }
    }
  }
  $items
}

function Test-OnlineEndpoint {
  param([string]$Uri)
  try {
    $r = Invoke-WebRequest -Uri $Uri -Method Head -UseBasicParsing -TimeoutSec 10
    return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
  } catch {
    try {
      $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 10
      return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400)
    } catch {
      return $false
    }
  }
}

function Get-Classification {
  param([object[]]$Findings)

  $fails = @($Findings | Where-Object status -eq 'FAIL')
  $warns = @($Findings | Where-Object status -eq 'WARN')

  if ($fails.Count -eq 0 -and $warns.Count -eq 0) { return 'HEALTHY' }

  $vaultMissing = $Findings | Where-Object { $_.id -eq 'VAULT_FOUND' -and $_.status -eq 'FAIL' }
  $manifestBad = $Findings | Where-Object { $_.id -eq 'LOCAL_MANIFEST_JSON' -and $_.status -eq 'FAIL' }
  $obsidianMissing = $Findings | Where-Object { $_.id -eq 'OBSIDIAN_MARKER' -and $_.status -eq 'FAIL' }

  if ($vaultMissing) { return 'REBUILD_REQUIRED' }
  if ($manifestBad -or $obsidianMissing) { return 'RECOVERABLE' }
  if ($fails.Count -gt 0) { return 'MANUAL_ESCALATION' }
  return 'DEGRADED'
}

$findings = [System.Collections.ArrayList]::new()
$candidates = @(Find-OecumeneVaultCandidates)

if ($candidates.Count -gt 0) {
  Add-Finding $findings 'VAULT_FOUND' 'PASS' "Found $($candidates.Count) OECUMENE vault candidate(s)." 'None'
} else {
  Add-Finding $findings 'VAULT_FOUND' 'FAIL' 'No OECUMENE vault signature was found on mounted filesystem drives.' 'Connect SIM-2 or restore/mount an OECUMENE cloud clone.'
}

$localManifestExists = Test-Path -LiteralPath $LocalEnvironmentFile -PathType Leaf
if ($localManifestExists) {
  Add-Finding $findings 'LOCAL_MANIFEST_EXISTS' 'PASS' "Local environment manifest exists: $LocalEnvironmentFile" 'None'
} else {
  Add-Finding $findings 'LOCAL_MANIFEST_EXISTS' 'WARN' "Local environment manifest missing: $LocalEnvironmentFile" 'Regenerate environment manifest with bootstrap/resolver.'
}

$localManifest = Read-JsonSafe $LocalEnvironmentFile
if ($localManifestExists -and $null -eq $localManifest) {
  Add-Finding $findings 'LOCAL_MANIFEST_JSON' 'FAIL' 'Local environment manifest exists but is not valid JSON.' 'Quarantine the invalid manifest and regenerate it from resolver.'
} elseif ($localManifest) {
  Add-Finding $findings 'LOCAL_MANIFEST_JSON' 'PASS' 'Local environment manifest parses as JSON.' 'None'
} else {
  Add-Finding $findings 'LOCAL_MANIFEST_JSON' 'INFO' 'Local environment manifest not available for parsing.' 'None'
}

$selected = $null
if ($localManifest -and $localManifest.vault -and $localManifest.vault.path) {
  $manifestVaultPath = [string]$localManifest.vault.path
  if (Test-Path -LiteralPath $manifestVaultPath -PathType Container) {
    $selected = [pscustomobject]@{
      drive = $null
      vault_path = $manifestVaultPath
      has_obsidian = Test-Path -LiteralPath (Join-Path $manifestVaultPath '.obsidian') -PathType Container
      has_export = Test-Path -LiteralPath (Join-Path $manifestVaultPath $ExportRoot) -PathType Container
      has_vault_manifest = Test-Path -LiteralPath (Join-Path $manifestVaultPath '.oecumene-environment.json') -PathType Leaf
    }
  } else {
    Add-Finding $findings 'MANIFEST_VAULT_PATH' 'WARN' "Manifest points to unavailable vault: $manifestVaultPath" 'Resolver should rediscover current environment and rewrite manifest.'
  }
}

if (-not $selected -and $candidates.Count -gt 0) {
  $selected = $candidates | Sort-Object @{Expression='has_obsidian';Descending=$true}, @{Expression='has_export';Descending=$true} | Select-Object -First 1
}

if ($selected) {
  if ($selected.has_obsidian) {
    Add-Finding $findings 'OBSIDIAN_MARKER' 'PASS' "Obsidian marker exists in $($selected.vault_path)." 'None'
  } else {
    Add-Finding $findings 'OBSIDIAN_MARKER' 'FAIL' "Missing .obsidian marker in $($selected.vault_path)." 'Restore Obsidian vault metadata from trusted source or reopen the vault if only metadata is absent.'
  }

  if ($selected.has_export) {
    Add-Finding $findings 'AI_EXPORT_ROOT' 'PASS' "AI-Export exists in $($selected.vault_path)." 'None'
  } else {
    Add-Finding $findings 'AI_EXPORT_ROOT' 'WARN' "AI-Export is missing in $($selected.vault_path)." 'Recreate only after verifying no user data is being overwritten.'
  }

  if ($selected.has_vault_manifest) {
    $vaultManifestPath = Join-Path $selected.vault_path '.oecumene-environment.json'
    $vaultManifest = Read-JsonSafe $vaultManifestPath
    if ($vaultManifest) {
      Add-Finding $findings 'VAULT_MANIFEST_JSON' 'PASS' 'Vault mirror environment manifest parses as JSON.' 'None'
    } else {
      Add-Finding $findings 'VAULT_MANIFEST_JSON' 'WARN' 'Vault mirror environment manifest exists but is invalid JSON.' 'Do not overwrite automatically; regenerate after resolver verification.'
    }
  } else {
    Add-Finding $findings 'VAULT_MANIFEST_EXISTS' 'INFO' 'Vault mirror environment manifest is absent.' 'Expected in ephemeral mode; otherwise resolver may recreate it in trusted mode.'
  }
}

if ($OnlineChecks) {
  $bootstrapOk = Test-OnlineEndpoint 'https://oecumene.space/bootstrap.ps1'
  Add-Finding $findings 'PUBLIC_BOOTSTRAP' $(if($bootstrapOk){'PASS'}else{'WARN'}) $(if($bootstrapOk){'Public bootstrap endpoint is reachable.'}else{'Public bootstrap endpoint is not reachable.'}) 'If unavailable, use local Phoenix/Bootstrap copy or another trusted source.'

  $githubOk = Test-OnlineEndpoint 'https://github.com'
  Add-Finding $findings 'GITHUB_REACHABILITY' $(if($githubOk){'PASS'}else{'WARN'}) $(if($githubOk){'GitHub is reachable.'}else{'GitHub is not reachable.'}) 'Use local recovery assets or retry when network is available.'
}

$classification = Get-Classification -Findings @($findings)
$recommendedAction = switch ($classification) {
  'HEALTHY' { 'No repair required.' }
  'DEGRADED' { 'Review warnings; continue only if current task does not depend on degraded component.' }
  'RECOVERABLE' { 'Prepare reversible repair plan; do not modify user data automatically.' }
  'REBUILD_REQUIRED' { 'Restore service layer from trusted source; preserve and verify existing user data first.' }
  'MANUAL_ESCALATION' { 'Create sanitized diagnostic bundle and escalate for technical review.' }
}

$report = [ordered]@{
  schema_version = 1
  phoenix_version = $PhoenixVersion
  created_at = (Get-Date).ToString('o')
  machine = $env:COMPUTERNAME
  mode = $Mode
  classification = $classification
  recommended_action = $recommendedAction
  selected_vault = if ($selected) { $selected.vault_path } else { $null }
  findings = @($findings)
  safety = [ordered]@{
    user_data_modified = $false
    repair_performed = $false
    reversible_by_default = $true
  }
}

if (-not $ReportPath) {
  New-Item -ItemType Directory -Path $DefaultReportRoot -Force | Out-Null
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ReportPath = Join-Path $DefaultReportRoot "phoenix-report-$stamp.json"
}

$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

if ($JsonOnly) {
  $report | ConvertTo-Json -Depth 10
  exit 0
}

Write-Host ''
Write-Host "OECUMENE PHOENIX v$PhoenixVersion"
Write-Host "Classification : $classification"
Write-Host "Mode           : $Mode"
Write-Host "Selected vault : $(if($selected){$selected.vault_path}else{'<none>'})"
Write-Host "Report         : $ReportPath"
Write-Host ''
foreach ($f in $findings) {
  Write-Host ("[{0}] {1}: {2}" -f $f.status, $f.id, $f.message)
}
Write-Host ''
Write-Host "Recommended    : $recommendedAction"
Write-Host 'Repair         : NOT PERFORMED (Phoenix v0.1 is diagnostic-only)'
