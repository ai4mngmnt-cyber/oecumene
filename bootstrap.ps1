[CmdletBinding()]
param(
  [switch]$OpenChromeExtensions,
  [switch]$OpenObsidian,
  [switch]$JsonOnly,
  [string]$CloudRoot,
  [ValidateSet('auto','local','cloud')]
  [string]$Source = 'auto',
  [ValidateSet('trusted','ephemeral')]
  [string]$SessionMode = 'trusted',
  [switch]$Admin,
  [switch]$LoginAdmin
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$SchemaVersion = 1
$VaultRelative = 'OECUMENE_HUB\10_VAULTS\OECUMENE_Corpus'
$VaultName = 'OECUMENE_Corpus'
$ExportRoot = 'AI-Export'
$SessionId = [guid]::NewGuid().ToString('N')
$StateRoot = if ($SessionMode -eq 'ephemeral') {
  Join-Path $env:TEMP ("OECUMENE-EPHEMERAL-" + $SessionId)
} else {
  Join-Path $env:LOCALAPPDATA 'OECUMENE'
}
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
  if ($Source -ne 'cloud') {
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
  }

  # 2. Cloud-mounted/synced clones. No recursive scan of the whole machine.
  if ($Source -ne 'local') {
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
  }

  if (-not $candidates.Count) {
    throw "OECUMENE environment not found for source mode '$Source'. Connect SIM-2 or mount/sync an OECUMENE cloud clone, then retry."
  }

  $best = $candidates |
    Sort-Object -Property @{Expression='score'; Descending=$true}, @{Expression='vault_path'; Descending=$false} |
    Select-Object -First 1

  if (-not $best.obsidian_found) {
    throw "OECUMENE_Corpus found at '$($best.vault_path)', but '.obsidian' is missing. Open this folder once as an Obsidian vault, then rerun."
  }

  $best
}


function Get-PortableGh {
  $existing = Get-Command gh -ErrorAction SilentlyContinue
  if ($existing) {
    return [pscustomobject]@{
      path = $existing.Source
      portable = $false
      version = $null
    }
  }

  $toolsRoot = Join-Path $StateRoot 'tools'
  $ghRoot = Join-Path $toolsRoot 'gh'
  $ghExe = Join-Path $ghRoot 'bin\gh.exe'

  if (Test-Path -LiteralPath $ghExe -PathType Leaf) {
    return [pscustomobject]@{
      path = $ghExe
      portable = $true
      version = $null
    }
  }

  New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null

  $headers = @{
    'User-Agent' = 'OECUMENE-Bootstrap'
    'Accept' = 'application/vnd.github+json'
  }

  $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/cli/cli/releases/latest' -Headers $headers -UseBasicParsing
  $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  $assetPattern = if ($arch -eq 'arm64') { 'windows_arm64\.zip$' } else { 'windows_amd64\.zip$' }

  $asset = $release.assets | Where-Object { $_.name -match $assetPattern } | Select-Object -First 1
  if (-not $asset) {
    throw "Portable GitHub CLI asset not found for architecture '$arch'."
  }

  $zip = Join-Path $toolsRoot $asset.name
  $extract = Join-Path $toolsRoot 'gh-extract'

  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
  Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
  Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

  $found = Get-ChildItem -LiteralPath $extract -Filter gh.exe -File -Recurse | Select-Object -First 1
  if (-not $found) {
    throw 'Downloaded GitHub CLI archive does not contain gh.exe.'
  }

  New-Item -ItemType Directory -Path (Split-Path $ghExe -Parent) -Force | Out-Null
  Copy-Item -LiteralPath $found.FullName -Destination $ghExe -Force
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue

  [pscustomobject]@{
    path = $ghExe
    portable = $true
    version = $release.tag_name
  }
}

function Get-GitHubAdminStatus {
  $ghInfo = if ($Admin -or $LoginAdmin) {
    Get-PortableGh
  } else {
    $existing = Get-Command gh -ErrorAction SilentlyContinue
    if ($existing) {
      [pscustomobject]@{ path = $existing.Source; portable = $false; version = $null }
    } else {
      $null
    }
  }

  if (-not $ghInfo) {
    return [pscustomobject]@{
      available = $false
      authenticated = $false
      status = 'CLI_MISSING'
      config_dir = $null
      executable = $null
      portable = $false
      version = $null
    }
  }

  if ($SessionMode -eq 'ephemeral') {
    $ghConfig = Join-Path $StateRoot 'gh'
    New-Item -ItemType Directory -Path $ghConfig -Force | Out-Null
    $env:GH_CONFIG_DIR = $ghConfig
  }

  $previousErrorAction = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $ghInfo.path auth status --hostname github.com 1>$null 2>$null
    $ok = ($LASTEXITCODE -eq 0)

    if (-not $ok -and $LoginAdmin) {
      if (-not $JsonOnly) {
        Write-Host 'Admin login: opening GitHub browser/device authentication...'
      }
      & $ghInfo.path auth login --hostname github.com --git-protocol https --web --clipboard
      & $ghInfo.path auth status --hostname github.com 1>$null 2>$null
      $ok = ($LASTEXITCODE -eq 0)
    }
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }

  [pscustomobject]@{
    available = $true
    authenticated = $ok
    status = if ($ok) { 'AUTHENTICATED' } else { 'AUTH_REQUIRED' }
    config_dir = if ($SessionMode -eq 'ephemeral') { $env:GH_CONFIG_DIR } else { $null }
    executable = $ghInfo.path
    portable = $ghInfo.portable
    version = $ghInfo.version
  }
}
function Get-SessionCleanupInfo {
  if ($SessionMode -ne 'ephemeral') { return $null }

  [ordered]@{
    state_root = $StateRoot
    cleanup_command = "Remove-Item -LiteralPath '$StateRoot' -Recurse -Force -ErrorAction SilentlyContinue"
  }
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
$adminStatus = Get-GitHubAdminStatus
$exportPath = Join-Path $vault.vault_path $ExportRoot

New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null

$environment = [ordered]@{
  schema_version = $SchemaVersion
  resolved_at = (Get-Date).ToString('o')
  machine = $env:COMPUTERNAME
  session = [ordered]@{
    id = $SessionId
    mode = $SessionMode
    ephemeral = ($SessionMode -eq 'ephemeral')
    state_root = $StateRoot
  }
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
    github_cli = $adminStatus.available
  }
  admin = [ordered]@{
    requested = [bool]$Admin
    github = [ordered]@{
      available = $adminStatus.available
      authenticated = $adminStatus.authenticated
      status = $adminStatus.status
      config_dir = $adminStatus.config_dir
      executable = $adminStatus.executable
      portable = $adminStatus.portable
      version = $adminStatus.version
    }
  }
  cleanup = Get-SessionCleanupInfo
}

$environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $EnvironmentFile -Encoding UTF8

if ($SessionMode -eq 'trusted') {
  $environment | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $vault.vault_path '.oecumene-environment.json') -Encoding UTF8
  try { Set-Clipboard -Value $vault.vault_path } catch {}
}

if (-not $JsonOnly) {
  Write-Host ''
  Write-Host 'OECUMENE ENVIRONMENT: READY'
  Write-Host "Mode    : $($vault.mode)"
  Write-Host "Session : $SessionMode"
  if ($Admin) {
    Write-Host "Admin   : $($adminStatus.status)"
    if ($adminStatus.executable) { Write-Host "gh      : $($adminStatus.executable)" }
  }
  if ($volume) { Write-Host "Carrier : $($volume.drive_letter):  $($volume.label)" }
  else { Write-Host "Cloud   : $($vault.provider)  $($vault.root)" }
  Write-Host "Vault   : $($vault.vault_path)"
  Write-Host "Export  : $exportPath"
  Write-Host "Manifest: $EnvironmentFile"
  if ($SessionMode -eq 'trusted') {
    Write-Host 'Vault path copied to clipboard.'
  } else {
    Write-Host 'Ephemeral mode: no vault mirror and no clipboard write.'
  }
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

if ($Admin -and -not $adminStatus.authenticated -and -not $JsonOnly) {
  if (-not $adminStatus.available) {
    Write-Host 'Admin gate: GitHub CLI could not be prepared.'
  } else {
    Write-Host 'Admin gate: GitHub authentication is required.'
    Write-Host 'Rerun with -Admin -LoginAdmin to open browser/device authentication.'
  }
}

if ($SessionMode -eq 'ephemeral' -and -not $JsonOnly) {
  Write-Host "Ephemeral state: $StateRoot"
  Write-Host 'No OECUMENE secrets are stored by bootstrap. Remove the ephemeral state after the session.'
}

if ($JsonOnly) {
  $environment | ConvertTo-Json -Depth 8
}
