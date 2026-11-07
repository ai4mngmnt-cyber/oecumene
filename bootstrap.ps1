[CmdletBinding()]
param(
  [switch]$OpenChromeExtensions,
  [switch]$OpenObsidian,
  [switch]$JsonOnly,
  [string]$CloudRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SchemaVersion = 1
$VaultRelative = 'OECUMENE_HUB\10_VAULTS\OECUMENE_Corpus'
$VaultName = 'OECUMENE_Corpus'
$ExportRoot = 'AI-Export'
$StateRoot = Join-Path $env:LOCALAPPDATA 'OECUMENE'
$EnvironmentFile = Join-Path $StateRoot 'environment.json'

function Out-Info([string]$Text) {
  if (-not $JsonOnly) { Write-Host $Text }
}

function Get-VolumeIdentity([string]$DriveLetter) {
  $result = [ordered]@{
    drive_letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    label = $null
    unique_id = $null
  }
  try {
    $v = Get-Volume -DriveLetter $result.drive_letter -ErrorAction Stop
    $result.label = $v.FileSystemLabel
    $result.unique_id = $v.UniqueId
  } catch {}
  [pscustomobject]$result
}

function Read-PreviousEnvironment {
  if (-not (Test-Path -LiteralPath $EnvironmentFile)) { return $null }
  try { Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Json }
  catch { $null }
}

function Get-CloudRoots {
  $roots = @()

  if ($CloudRoot) { $roots += $CloudRoot }

  foreach ($name in 'OneDrive','OneDriveConsumer','OneDriveCommercial') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) { $roots += $value }
  }

  foreach ($name in 'Proton Drive','ProtonDrive','Dropbox','Google Drive','iCloudDrive') {
    $candidate = Join-Path $env:USERPROFILE $name
    if (Test-Path -LiteralPath $candidate -PathType Container) { $roots += $candidate }
  }

  $roots | Where-Object { $_ } | Select-Object -Unique
}

function Find-OecumeneEnvironment {
  $previous = Read-PreviousEnvironment
  $candidates = @()

  # 1. Local carriers: SIM-2 or another removable/fixed OECUMENE carrier.
  foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
    if (-not $drive.Root) { continue }

    $vault = Join-Path $drive.Root $VaultRelative
    if (-not (Test-Path -LiteralPath $vault -PathType Container)) { continue }

    $obsidian = Join-Path $vault '.obsidian'
    $identity = Get-VolumeIdentity $drive.Name
    $score = 1000

    if (Test-Path -LiteralPath $obsidian -PathType Container) { $score += 100 }
    if (Test-Path -LiteralPath (Join-Path $vault $ExportRoot) -PathType Container) { $score += 20 }

    if ($previous -and $previous.volume -and $previous.volume.unique_id -and
        $identity.unique_id -and
        $identity.unique_id -eq $previous.volume.unique_id) {
      $score += 1000
    }

    $candidates += [pscustomobject]@{
      score = $score
      mode = 'local-carrier'
      provider = 'filesystem'
      drive = $drive.Name
      root = $drive.Root
      vault_path = $vault
      obsidian_found = Test-Path -LiteralPath $obsidian -PathType Container
      label = $identity.label
      unique_id = $identity.unique_id
    }
  }

  # 2. Cloud-mounted/synced clones. No recursive scan of the whole machine.
  foreach ($root in Get-CloudRoots) {
    foreach ($candidateBase in @($root, (Join-Path $root 'OECUMENE'))) {
      $vault = Join-Path $candidateBase $VaultRelative
      if (-not (Test-Path -LiteralPath $vault -PathType Container)) { continue }

      $obsidian = Join-Path $vault '.obsidian'
      $provider = Split-Path $root -Leaf
      $score = 500

      if (Test-Path -LiteralPath $obsidian -PathType Container) { $score += 100 }
      if (Test-Path -LiteralPath (Join-Path $vault $ExportRoot) -PathType Container) { $score += 20 }

      $candidates += [pscustomobject]@{
        score = $score
        mode = 'cloud-mounted'
        provider = $provider
        drive = $null
        root = $root
        vault_path = $vault
        obsidian_found = Test-Path -LiteralPath $obsidian -PathType Container
        label = $provider
        unique_id = $null
      }
    }
  }

  if (-not $candidates.Count) {
    throw "OECUMENE environment not found. Local carrier and known cloud-mounted roots were checked. Connect SIM-2 or mount/sync an OECUMENE cloud clone, then retry."
  }

  $best = $candidates |
    Sort-Object -Property @{Expression='score'; Descending=$true}, @{Expression='vault_path'; Descending=$false} |
    Select-Object -First 1

  if (-not $best.obsidian_found) {
    throw "OECUMENE_Corpus found at '$($best.vault_path)', but '.obsidian' is missing. Open this folder once as an Obsidian vault, then rerun."
  }

  $best
}

function Find-Chrome {
  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "$programFilesX86\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

function Find-Obsidian {
  $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
  @(
    "$env:LOCALAPPDATA\Obsidian\Obsidian.exe",
    "$env:ProgramFiles\Obsidian\Obsidian.exe",
    "$programFilesX86\Obsidian\Obsidian.exe"
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

$vault = Find-OecumeneEnvironment
$volume = if ($vault.drive) { Get-VolumeIdentity $vault.drive } else { $null }
$chrome = Find-Chrome
$obsidian = Find-Obsidian
$exportPath = Join-Path $vault.vault_path $ExportRoot

New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

$environment = [ordered]@{
  schema_version = $SchemaVersion
  resolved_at = (Get-Date).ToString('o')
  machine = $env:COMPUTERNAME
  mode = $vault.mode
  source = 'https://oecumene.space/bootstrap.ps1'
  provider = $vault.provider
  volume = if ($volume) {
    [ordered]@{
      drive_letter = $volume.drive_letter
      label = $volume.label
      unique_id = $volume.unique_id
    }
  } else { $null }
  cloud = if ($vault.mode -eq 'cloud-mounted') {
    [ordered]@{
      provider = $vault.provider
      root = $vault.root
    }
  } else { $null }
  vault = [ordered]@{
    name = $VaultName
    relative_path = $VaultRelative
    path = $vault.vault_path
    obsidian_marker = (Join-Path $vault.vault_path '.obsidian')
  }
  export = [ordered]@{
    root = $ExportRoot
    physical_path = $exportPath
  }
  applications = [ordered]@{
    chrome = $chrome
    obsidian = $obsidian
  }
}

$environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EnvironmentFile -Encoding UTF8
$environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $vault.vault_path '.oecumene-environment.json') -Encoding UTF8

try { Set-Clipboard -Value $vault.vault_path } catch {}

if (-not $JsonOnly) {
  Write-Host ''
  Write-Host 'OECUMENE ENVIRONMENT: READY'
  Write-Host "Mode    : $($vault.mode)"
  if ($volume) { Write-Host "Carrier : $($volume.drive_letter):  $($volume.label)" }
  else { Write-Host "Cloud   : $($vault.provider)  $($vault.root)" }
  Write-Host "Vault   : $($vault.vault_path)"
  Write-Host "Export  : $exportPath"
  Write-Host "Manifest: $EnvironmentFile"
  Write-Host 'Vault path copied to clipboard.'
}

if ($OpenChromeExtensions) {
  if ($chrome) { Start-Process -FilePath $chrome -ArgumentList 'chrome://extensions' }
  else { Out-Info 'Chrome executable not found automatically.' }
}

if ($OpenObsidian) {
  if ($obsidian) {
    $vaultUri = [uri]::EscapeDataString($vault.vault_path)
    Start-Process -FilePath $obsidian -ArgumentList "obsidian://open?path=$vaultUri"
  } else {
    Out-Info 'Obsidian is not installed. Install Obsidian and rerun with -OpenObsidian.'
  }
}

if ($JsonOnly) {
  $environment | ConvertTo-Json -Depth 8
}
