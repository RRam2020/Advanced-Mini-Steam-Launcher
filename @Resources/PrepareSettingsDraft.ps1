param(
    [string]$ParentConfigName = "",
    [string]$RootConfig = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CachePath = Join-Path $Root "Cache"
$DataCachePath = Join-Path $CachePath "Data"
$AdvancedSettingsPath = Join-Path $Root "AdvancedSettings.inc"
$DraftPath = Join-Path $DataCachePath "SettingsDraft.inc"
$LogPath = Join-Path $CachePath "Update.log"

function Ensure-ParentDirectory([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Get-TemporaryWritePath([string]$Path) {
    return ("{0}.{1}.tmp" -f $Path, ([guid]::NewGuid().ToString("N")))
}

function Log([string]$Message) {
    Ensure-ParentDirectory $LogPath
    Add-Content -LiteralPath $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8
}

function Read-IniValue([string]$Path, [string]$Name) {
    $pattern = "^\s*" + [regex]::Escape($Name) + "\s*=\s*(.*?)\s*$"
    $match = Get-Content -LiteralPath $Path | Select-String -Pattern $pattern | Select-Object -First 1
    if (-not $match) { throw "Missing $Name in $Path" }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-DisplayCountValue {
    try { $value = [int](Read-IniValue $AdvancedSettingsPath "DisplayGameCount") } catch { $value = 10 }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 10) { $value = 10 }
    return $value
}

function Get-RecentlyPlayedExpirationValue {
    try { $value = [int](Read-IniValue $AdvancedSettingsPath "RecentlyPlayedExpirationMinutes") } catch { $value = 20160 }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 1438560) { $value = 1438560 }
    return $value
}

function Get-RecentAchievementDisplayCountValue {
    try { $value = [int](Read-IniValue $AdvancedSettingsPath "RecentAchievementDisplayCount") } catch { $value = 10 }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 10) { $value = 10 }
    return $value
}

function Get-RecentAchievementExpirationValue {
    try { $value = [int](Read-IniValue $AdvancedSettingsPath "RecentAchievementExpirationMinutes") } catch { $value = 10080 }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 1438560) { $value = 1438560 }
    return $value
}

function Get-ShowAchievementRarityValue {
    try { $rawValue = (Read-IniValue $AdvancedSettingsPath "ShowAchievementRarity").Trim() } catch { $rawValue = "1" }

    switch -Regex ($rawValue) {
        '^(0|false|off|no)$' { return 0 }
        default { return 1 }
    }
}

function Get-RecentlyPlayedDraftInputState([int]$Minutes) {
    if ($Minutes -ge 1440 -and ($Minutes % 1440) -eq 0 -and ($Minutes / 1440) -le 999) {
        return [pscustomobject]@{
            InputValue = [int]($Minutes / 1440)
            Unit = "Days"
        }
    }

    if ($Minutes -ge 60 -and ($Minutes % 60) -eq 0 -and ($Minutes / 60) -le 999) {
        return [pscustomobject]@{
            InputValue = [int]($Minutes / 60)
            Unit = "Hours"
        }
    }

    return [pscustomobject]@{
        InputValue = [Math]::Min($Minutes, 999)
        Unit = "Minutes"
    }
}

function Get-RecentAchievementDraftInputState([int]$Minutes) {
    if ($Minutes -ge 1440 -and ($Minutes % 1440) -eq 0 -and ($Minutes / 1440) -le 999) {
        return [pscustomobject]@{
            InputValue = [int]($Minutes / 1440)
            Unit = "Days"
        }
    }

    if ($Minutes -ge 60 -and ($Minutes % 60) -eq 0 -and ($Minutes / 60) -le 999) {
        return [pscustomobject]@{
            InputValue = [int]($Minutes / 60)
            Unit = "Hours"
        }
    }

    return [pscustomobject]@{
        InputValue = [Math]::Min($Minutes, 999)
        Unit = "Minutes"
    }
}

try {
    $displayGameCount = Get-DisplayCountValue
    $recentlyPlayedExpirationMinutes = Get-RecentlyPlayedExpirationValue
    $recentAchievementDisplayCount = Get-RecentAchievementDisplayCountValue
    $recentAchievementExpirationMinutes = Get-RecentAchievementExpirationValue
    $showAchievementRarity = Get-ShowAchievementRarityValue
    $recentlyPlayedDraft = Get-RecentlyPlayedDraftInputState $recentlyPlayedExpirationMinutes
    $recentAchievementDraft = Get-RecentAchievementDraftInputState $recentAchievementExpirationMinutes

    $lines = @(
        "[Variables]",
        ("DraftDisplayGameCount={0}" -f $displayGameCount),
        ("DraftRecentlyPlayedExpirationMinutes={0}" -f $recentlyPlayedExpirationMinutes),
        ("DraftRecentlyPlayedExpirationInputValue={0}" -f $recentlyPlayedDraft.InputValue),
        ("DraftRecentAchievementDisplayCount={0}" -f $recentAchievementDisplayCount),
        ("DraftRecentAchievementExpirationMinutes={0}" -f $recentAchievementExpirationMinutes),
        ("DraftRecentAchievementExpirationInputValue={0}" -f $recentAchievementDraft.InputValue),
        ("DraftRecentlyPlayedExpirationUnit={0}" -f $recentlyPlayedDraft.Unit),
        ("DraftRecentAchievementExpirationUnit={0}" -f $recentAchievementDraft.Unit),
        ("DraftShowAchievementRarity={0}" -f $showAchievementRarity),
        ("DraftShowAchievementRarityLabel={0}" -f $(if ($showAchievementRarity -eq 1) { "On" } else { "Off" })),
        ("DraftIsSaving=0"),
        ("DraftSaveButtonText=Save"),
        ("DraftSaveButtonFontColor=255,255,255,255"),
        ("DraftCloseButtonFontColor=255,255,255,255")
    ) + @(
        ("DraftParentConfigName={0}" -f $ParentConfigName),
        ("DraftRootConfig={0}" -f $RootConfig)
    )

    Ensure-ParentDirectory $DraftPath
    $tmp = Get-TemporaryWritePath $DraftPath
    [IO.File]::WriteAllLines($tmp, $lines, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $DraftPath -Force
    Log ("Settings draft prepared for {0}." -f $ParentConfigName)
}
catch {
    Log ("PrepareSettingsDraft ERROR: {0}" -f $_.Exception.Message)
    exit 1
}
