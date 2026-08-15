param(
    [string]$ConfigName = "",
    [ValidateSet("Never", "OnChange", "Always")]
    [string]$RebuildDisplay = "Never"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { Add-Type -AssemblyName System.Drawing } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CachePath = Join-Path $Root "Cache"
$DataCachePath = Join-Path $CachePath "Data"
$SteamAccountSettingsPath = Join-Path $Root "SteamAccountInfo.inc"
$AdvancedSettingsPath = Join-Path $Root "AdvancedSettings.inc"
$PlayedPath = Join-Path $DataCachePath "PlayedGames.json"
$PlaytimePath = Join-Path $DataCachePath "playtime_2weeks.json"
$AchievementsPath = Join-Path $DataCachePath "RecentAchievements.json"
$AchievementStatePath = Join-Path $DataCachePath "RecentAchievementsState.json"
$LockPath = Join-Path $DataCachePath "RecentAchievements.lock"
$BuildDisplayScriptPath = Join-Path $Root "BuildDisplay.ps1"
$LogPath = Join-Path $CachePath "Update.log"
$ImageAssetPath = Join-Path $Root "Images"
$AchievementAssetCachePath = Join-Path $CachePath "Achievements"
$SchemaCachePath = $AchievementAssetCachePath
$IconCachePath = $AchievementAssetCachePath
$FallbackAchievementIconPath = Join-Path $ImageAssetPath "404-ERROR.jpg"
$GoldAchievementOverlayPath = Join-Path $ImageAssetPath "Gold.png"
$SilverAchievementOverlayPath = Join-Path $ImageAssetPath "Silver.png"
$BronzeAchievementOverlayPath = Join-Path $ImageAssetPath "Bronze.png"
$HeaderImagePath = Join-Path $AchievementAssetCachePath "RecentAchievementsHeader.png"
$SkinPath = if ([string]::IsNullOrWhiteSpace($ConfigName)) { "" } else { Join-Path (Split-Path -Parent $Root) ("{0}.ini" -f $ConfigName) }
$LockStream = $null
$SchemaCacheMaxAgeMinutes = 1440
$GlobalAchievementPercentCacheMaxAgeMinutes = 1440
$EmbeddedGlobalAchievementPercentPropertyName = "__MiniSteamGlobalAchievementPercentages"

$DefaultGoldAchievementOverlayThresholdPercent = 10.0
$DefaultSilverAchievementOverlayThresholdPercent = 20.0
$DefaultBronzeAchievementOverlayThresholdPercent = 30.0
$RecentAchievementIconCacheCount = 10
$AchievementIconCacheSize = 72

function Ensure-ParentDirectory([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
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

function Test-SteamCredentialsConfigured([string]$ApiKey, [string]$SteamId) {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { return $false }
    if ([string]::IsNullOrWhiteSpace($SteamId)) { return $false }
    if ($ApiKey -eq "YOUR_STEAM_WEB_API_KEY") { return $false }
    if ($SteamId -eq "YOUR_STEAMID64") { return $false }
    return $true
}

function Load-JsonArray([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @($raw | ConvertFrom-Json)
}

function Get-PropertyString([AllowNull()][object]$InputObject, [string]$Name) {
    if ($null -eq $InputObject) { return "" }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return "" }
    if ($null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Get-PropertyBoolean([AllowNull()][object]$InputObject, [string]$Name, [bool]$DefaultValue = $false) {
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }

    try {
        return [bool]$property.Value
    }
    catch {
        return $DefaultValue
    }
}

function Get-PropertyInt([AllowNull()][object]$InputObject, [string]$Name, [int]$DefaultValue = 0) {
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }

    try {
        return [int]$property.Value
    }
    catch {
        return $DefaultValue
    }
}

function Get-PropertyDouble([AllowNull()][object]$InputObject, [string]$Name, [double]$DefaultValue = 0.0) {
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }

    try {
        return [double]$property.Value
    }
    catch {
        return $DefaultValue
    }
}

$script:ConfiguredGoldAchievementOverlayThresholdPercent = $null
$script:ConfiguredSilverAchievementOverlayThresholdPercent = $null
$script:ConfiguredBronzeAchievementOverlayThresholdPercent = $null

function Get-ConfiguredAchievementOverlayThresholdPercent([string]$SettingName, [double]$DefaultValue, [string]$CacheVariableName) {
    $cachedValue = Get-Variable -Scope Script -Name $CacheVariableName -ErrorAction SilentlyContinue
    if ($null -ne $cachedValue -and $null -ne $cachedValue.Value) {
        return [double]$cachedValue.Value
    }

    $value = $DefaultValue
    try {
        $rawValue = Read-IniValue $AdvancedSettingsPath $SettingName
        $value = [double]::Parse($rawValue, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        $value = $DefaultValue
    }

    if ($value -lt 0.0) { $value = 0.0 }
    if ($value -gt 100.0) { $value = 100.0 }

    Set-Variable -Scope Script -Name $CacheVariableName -Value $value
    return [double]$value
}

function Get-GoldAchievementOverlayThresholdPercent {
    return (Get-ConfiguredAchievementOverlayThresholdPercent "GoldAchievementOverlayThresholdPercent" $DefaultGoldAchievementOverlayThresholdPercent "ConfiguredGoldAchievementOverlayThresholdPercent")
}

function Get-SilverAchievementOverlayThresholdPercent {
    return (Get-ConfiguredAchievementOverlayThresholdPercent "SilverAchievementOverlayThresholdPercent" $DefaultSilverAchievementOverlayThresholdPercent "ConfiguredSilverAchievementOverlayThresholdPercent")
}

function Get-BronzeAchievementOverlayThresholdPercent {
    return (Get-ConfiguredAchievementOverlayThresholdPercent "BronzeAchievementOverlayThresholdPercent" $DefaultBronzeAchievementOverlayThresholdPercent "ConfiguredBronzeAchievementOverlayThresholdPercent")
}

function Get-AchievementOverlayTier([double]$RarityPercent) {
    if ($RarityPercent -lt 0.0) { return "" }

    $goldThreshold = [Math]::Max(0.0, (Get-GoldAchievementOverlayThresholdPercent))
    $silverThreshold = [Math]::Max($goldThreshold, (Get-SilverAchievementOverlayThresholdPercent))
    $bronzeThreshold = [Math]::Max($silverThreshold, (Get-BronzeAchievementOverlayThresholdPercent))

    if ($RarityPercent -le $goldThreshold) { return "Gold" }
    if ($RarityPercent -le $silverThreshold) { return "Silver" }
    if ($RarityPercent -le $bronzeThreshold) { return "Bronze" }
    return ""
}

function Get-AchievementOverlayThresholdSignature() {
    return ("Show={0}|Gold<= {1}|Silver<= {2}|Bronze<= {3}" -f
        $(if (Get-ConfiguredShowAchievementRarity) { "1" } else { "0" }),
        (Get-GoldAchievementOverlayThresholdPercent).ToString([Globalization.CultureInfo]::InvariantCulture),
        (Get-SilverAchievementOverlayThresholdPercent).ToString([Globalization.CultureInfo]::InvariantCulture),
        (Get-BronzeAchievementOverlayThresholdPercent).ToString([Globalization.CultureInfo]::InvariantCulture)
    )
}

function Get-AchievementOverlayImagePath([string]$OverlayTier) {
    switch -Regex (([string]$OverlayTier).Trim()) {
        '^Gold$' { return $GoldAchievementOverlayPath }
        '^Silver$' { return $SilverAchievementOverlayPath }
        '^Bronze$' { return $BronzeAchievementOverlayPath }
        default { return "" }
    }
}

function Resolve-AchievementOverlayTierFromObject([AllowNull()][object]$Achievement) {
    $existingTier = (Get-PropertyString $Achievement "OverlayTier").Trim()
    if (-not [string]::IsNullOrWhiteSpace($existingTier)) {
        return $existingTier
    }

    return (Get-AchievementOverlayTier (Get-PropertyDouble $Achievement "RarityPercent" -1.0))
}

function Assert-Configured([string]$ApiKey, [string]$SteamId) {
    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey -eq "YOUR_STEAM_WEB_API_KEY") {
        throw "SteamAPIKey is not configured in SteamAccountInfo.inc."
    }
    if ([string]::IsNullOrWhiteSpace($SteamId) -or $SteamId -eq "YOUR_STEAMID64") {
        throw "SteamID64 is not configured in SteamAccountInfo.inc."
    }
}

function Normalize-UtcString([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }

    try {
        $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        return $parsed.UtcDateTime.ToString("o")
    }
    catch {
        return ""
    }
}

function Convert-UnixSecondsToUtcString([long]$UnixSeconds) {
    if ($UnixSeconds -le 0) { return "" }

    try {
        return ([DateTimeOffset]::FromUnixTimeSeconds($UnixSeconds)).UtcDateTime.ToString("o")
    }
    catch {
        return ""
    }
}

function Get-UtcSortTicks([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return [long]::MinValue }

    try {
        return ([DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).UtcTicks
    }
    catch {
        return [long]::MinValue
    }
}

$script:ConfiguredRecentAchievementDisplayCount = $null
$script:ConfiguredRecentAchievementExpirationMinutes = $null
$script:ConfiguredShowAchievementRarity = $null

function Get-ConfiguredRecentAchievementDisplayCount {
    if ($null -ne $script:ConfiguredRecentAchievementDisplayCount) {
        return [int]$script:ConfiguredRecentAchievementDisplayCount
    }

    try {
        $rawValue = Read-IniValue $AdvancedSettingsPath "RecentAchievementDisplayCount"
        $value = [int]$rawValue
    }
    catch {
        $value = 10
    }

    if ($value -lt 0) { $value = 0 }
    if ($value -gt 10) { $value = 10 }
    $script:ConfiguredRecentAchievementDisplayCount = $value
    return $value
}

function Get-ConfiguredRecentAchievementExpirationMinutes {
    if ($null -ne $script:ConfiguredRecentAchievementExpirationMinutes) {
        return [int]$script:ConfiguredRecentAchievementExpirationMinutes
    }

    $defaultMinutes = 10080
    try {
        $rawValue = Read-IniValue $AdvancedSettingsPath "RecentAchievementExpirationMinutes"
        $value = [int]$rawValue
    }
    catch {
        $value = $defaultMinutes
    }

    $resolved = $value
    if ($resolved -lt 0) { $resolved = 0 }
    if ($resolved -gt 525600) { $resolved = 525600 }

    $script:ConfiguredRecentAchievementExpirationMinutes = $resolved
    return $resolved
}

function Get-ConfiguredShowAchievementRarity {
    if ($null -ne $script:ConfiguredShowAchievementRarity) {
        return [bool]$script:ConfiguredShowAchievementRarity
    }

    try {
        $rawValue = (Read-IniValue $AdvancedSettingsPath "ShowAchievementRarity").Trim()
    }
    catch {
        $rawValue = "1"
    }

    $enabled = $true
    switch -Regex ($rawValue) {
        '^(0|false|off|no)$' { $enabled = $false }
        default { $enabled = $true }
    }

    $script:ConfiguredShowAchievementRarity = $enabled
    return $enabled
}

function Get-RecentAchievementExpirationDisplayState([int]$Minutes) {
    if ($Minutes -ge 1440 -and ($Minutes % 1440) -eq 0 -and ($Minutes / 1440) -le 365) {
        $value = [int]($Minutes / 1440)
        return [pscustomobject]@{
            Value = $value
            Unit = $(if ($value -eq 1) { "Day" } else { "Days" })
        }
    }

    if ($Minutes -ge 60 -and ($Minutes % 60) -eq 0 -and ($Minutes / 60) -le 365) {
        $value = [int]($Minutes / 60)
        return [pscustomobject]@{
            Value = $value
            Unit = $(if ($value -eq 1) { "Hour" } else { "Hours" })
        }
    }

    $value = [Math]::Min([Math]::Max($Minutes, 0), 365)
    return [pscustomobject]@{
        Value = $value
        Unit = $(if ($value -eq 1) { "Minute" } else { "Minutes" })
    }
}

function Get-RecentAchievementExpirationLabel([int]$Minutes) {
    $displayState = Get-RecentAchievementExpirationDisplayState $Minutes
    return ("{0} {1}" -f $displayState.Value, $displayState.Unit)
}

function Test-IsAchievementWithinWindow([string]$UnlockTimeUtc) {
    if ([string]::IsNullOrWhiteSpace($UnlockTimeUtc)) { return $false }

    try {
        $unlockTime = [DateTimeOffset]::Parse($UnlockTimeUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $expirationMinutes = Get-ConfiguredRecentAchievementExpirationMinutes
        return ($unlockTime.ToUniversalTime() -ge [DateTimeOffset]::UtcNow.AddMinutes(-1 * $expirationMinutes))
    }
    catch {
        return $false
    }
}

function Normalize-RecentAchievements([object[]]$Items) {
    $groups = New-Object System.Collections.Generic.List[object]
    $seenGroups = @{}

    foreach ($item in @($Items)) {
        $appId = (Get-PropertyString $item "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId)) { continue }
        if ($seenGroups.ContainsKey($appId)) { continue }
        $seenGroups[$appId] = $true

        $gameName = (Get-PropertyString $item "GameName").Trim()
        if ([string]::IsNullOrWhiteSpace($gameName)) {
            $gameName = "Steam App $appId"
        }

        $achievements = New-Object System.Collections.Generic.List[object]
        $seenAchievements = @{}

        foreach ($achievement in @($item.Achievements)) {
            $apiName = (Get-PropertyString $achievement "ApiName").Trim()
            if ([string]::IsNullOrWhiteSpace($apiName)) { continue }
            if ($seenAchievements.ContainsKey($apiName)) { continue }

            $unlockTimeUtc = Normalize-UtcString (Get-PropertyString $achievement "UnlockTimeUtc")
            if ([string]::IsNullOrWhiteSpace($unlockTimeUtc)) { continue }

            $seenAchievements[$apiName] = $true
            $displayName = (Get-PropertyString $achievement "Name").Trim()
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = $apiName
            }

            $achievements.Add([pscustomobject][ordered]@{
                ApiName = $apiName
                Name = $displayName
                IconPath = (Get-PropertyString $achievement "IconPath").Trim()
                IconUrl = (Get-PropertyString $achievement "IconUrl").Trim()
                RarityPercent = (Get-PropertyDouble $achievement "RarityPercent" -1.0)
                OverlayTier = (Resolve-AchievementOverlayTierFromObject $achievement)
                UnlockTimeUtc = $unlockTimeUtc
            })
        }

        $sortedAchievements = @(
            $achievements |
            Sort-Object @{ Expression = { Get-UtcSortTicks ([string]$_.UnlockTimeUtc) }; Descending = $true }, @{ Expression = { [string]$_.Name }; Descending = $false }
        )

        if ($sortedAchievements.Count -eq 0) { continue }

        $groups.Add([pscustomobject][ordered]@{
            AppId = $appId
            GameName = $gameName
            AchievementsUrl = (Get-PropertyString $item "AchievementsUrl").Trim()
            LatestUnlockUtc = [string]$sortedAchievements[0].UnlockTimeUtc
            Achievements = @($sortedAchievements)
        })
    }

    $normalized = @(
        $groups |
        Sort-Object @{ Expression = { Get-UtcSortTicks ([string]$_.LatestUnlockUtc) }; Descending = $true }, @{ Expression = { [string]$_.GameName }; Descending = $false }
    )

    return @($normalized)
}

function Convert-RecentAchievementsToJson([object[]]$Items) {
    $normalized = @(Normalize-RecentAchievements $Items)

    if ($normalized.Count -eq 0) {
        return "[]"
    }
    elseif ($normalized.Count -eq 1) {
        return "[" + [Environment]::NewLine + (ConvertTo-Json $normalized[0] -Depth 6) + [Environment]::NewLine + "]"
    }
    else {
        return (ConvertTo-Json $normalized -Depth 6)
    }
}

function Load-RecentAchievementsCache {
    if (-not (Test-Path -LiteralPath $AchievementsPath)) { return @() }
    $raw = [IO.File]::ReadAllText($AchievementsPath)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    try {
        $data = $raw | ConvertFrom-Json
    }
    catch {
        Log ("RecentAchievements.json was invalid and has been reset: {0}" -f $_.Exception.Message)
        Save-RecentAchievementsCache @()
        return @()
    }

    $normalized = @(Normalize-RecentAchievements @($data))
    $canonicalJson = Convert-RecentAchievementsToJson $normalized
    if ($raw.Trim() -ne $canonicalJson.Trim()) {
        [IO.File]::WriteAllText($AchievementsPath, $canonicalJson, (New-Object Text.UTF8Encoding($false)))
        Log ("RecentAchievements.json normalized on load; groups={0}" -f $normalized.Count)
    }

    return @($normalized)
}

function Save-RecentAchievementsCache([object[]]$Items) {
    Ensure-ParentDirectory $AchievementsPath
    $json = Convert-RecentAchievementsToJson $Items
    $tmp = "$AchievementsPath.new"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    $null = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    Move-Item -LiteralPath $tmp -Destination $AchievementsPath -Force
}

function Get-DefaultAchievementState {
    return [pscustomobject][ordered]@{
        HasPanel = $false
        HeaderImagePath = ""
        HeaderHeight = 0
        HeaderWidth = 0
        TotalHeight = 0
        Signature = ""
        GroupPanels = @()
    }
}

function Load-AchievementState {
    if (-not (Test-Path -LiteralPath $AchievementStatePath)) {
        return Get-DefaultAchievementState
    }

    try {
        $raw = [IO.File]::ReadAllText($AchievementStatePath)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Get-DefaultAchievementState
        }

        $data = $raw | ConvertFrom-Json
        $groupPanels = @()
        if ($null -ne $data.PSObject.Properties["GroupPanels"] -and $null -ne $data.GroupPanels) {
            $groupPanels = @($data.GroupPanels)
        }
        return [pscustomobject][ordered]@{
            HasPanel = Get-PropertyBoolean $data "HasPanel" $false
            HeaderImagePath = Get-PropertyString $data "HeaderImagePath"
            HeaderHeight = Get-PropertyInt $data "HeaderHeight" 0
            HeaderWidth = Get-PropertyInt $data "HeaderWidth" 0
            TotalHeight = Get-PropertyInt $data "TotalHeight" 0
            Signature = Get-PropertyString $data "Signature"
            GroupPanels = $groupPanels
        }
    }
    catch {
        Log ("RecentAchievementsState.json was invalid and has been reset: {0}" -f $_.Exception.Message)
        return Get-DefaultAchievementState
    }
}

function Save-AchievementState([object]$State) {
    Ensure-ParentDirectory $AchievementStatePath
    $tmp = "$AchievementStatePath.new"
    [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $AchievementStatePath -Force
}

function Remove-FileIfExists([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Get-AchievementGroupImagePath([string]$AppId) {
    $safeAppId = Get-SafeFileNameComponent $AppId
    return (Join-Path $AchievementAssetCachePath ("RecentAchievements{0}.png" -f $safeAppId))
}

function Remove-StaleAchievementIconAssets([object[]]$Items) {
    $keepSet = @{}

    foreach ($group in @($Items)) {
        foreach ($achievement in @($group.Achievements)) {
            $iconPath = Resolve-ExistingAchievementAssetPath ((Get-PropertyString $achievement "IconPath").Trim())
            if ([string]::IsNullOrWhiteSpace($iconPath)) { continue }

            try {
                $keepSet[[IO.Path]::GetFullPath($iconPath)] = $true
            }
            catch {
                $keepSet[$iconPath] = $true
            }
        }
    }

    foreach ($basePath in @($IconCachePath)) {
        if ([string]::IsNullOrWhiteSpace($basePath) -or -not (Test-Path -LiteralPath $basePath)) { continue }

        foreach ($file in @(Get-ChildItem -LiteralPath $basePath -File -ErrorAction SilentlyContinue)) {
            if ($file.Name -match '^(RecentAchievements|Schema_)') { continue }
            if ($file.Extension -notin @('.png', '.jpg', '.jpeg', '.webp')) { continue }
            if ($keepSet.ContainsKey($file.FullName)) { continue }

            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-StaleAchievementRenderAssets([AllowNull()][object]$PreviousState, [string[]]$KeepPaths = @()) {
    $keepSet = @{}
    foreach ($path in @($KeepPaths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $keepSet[[IO.Path]::GetFullPath($path)] = $true
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($null -ne $PreviousState) {
        $candidates.Add((Get-PropertyString $PreviousState "HeaderImagePath").Trim())
        if ($null -ne $PreviousState.PSObject.Properties["GroupPanels"] -and $null -ne $PreviousState.GroupPanels) {
            foreach ($groupPanel in @($PreviousState.GroupPanels)) {
                $candidates.Add((Get-PropertyString $groupPanel "ImagePath").Trim())
            }
        }
    }

    foreach ($candidate in @($candidates.ToArray())) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $fullPath = ""
        try { $fullPath = [IO.Path]::GetFullPath($candidate) } catch { $fullPath = $candidate }
        if ($keepSet.ContainsKey($fullPath)) { continue }
        Remove-FileIfExists $candidate
    }
}

function Get-RecentAchievementFlatEntries([object[]]$Items) {
    $flat = New-Object System.Collections.Generic.List[object]

    foreach ($group in @(Normalize-RecentAchievements $Items)) {
        foreach ($achievement in @($group.Achievements)) {
            $unlockTimeUtc = (Get-PropertyString $achievement "UnlockTimeUtc").Trim()
            if (-not (Test-IsAchievementWithinWindow $unlockTimeUtc)) { continue }

            $flat.Add([pscustomobject][ordered]@{
                AppId = [string]$group.AppId
                GameName = [string]$group.GameName
                AchievementsUrl = (Get-PropertyString $group "AchievementsUrl").Trim()
                ApiName = (Get-PropertyString $achievement "ApiName").Trim()
                Name = (Get-PropertyString $achievement "Name").Trim()
                IconPath = (Get-PropertyString $achievement "IconPath").Trim()
                IconUrl = (Get-PropertyString $achievement "IconUrl").Trim()
                RarityPercent = (Get-PropertyDouble $achievement "RarityPercent" -1.0)
                OverlayTier = (Resolve-AchievementOverlayTierFromObject $achievement)
                UnlockTimeUtc = $unlockTimeUtc
            })
        }
    }

    return @(
        $flat |
        Sort-Object @{ Expression = { Get-UtcSortTicks ([string]$_.UnlockTimeUtc) }; Descending = $true }, @{ Expression = { [string]$_.GameName }; Descending = $false }, @{ Expression = { [string]$_.Name }; Descending = $false }
    )
}

function Get-ResolvedRecentAchievementGroups([object[]]$Entries) {
    if (@($Entries).Count -eq 0) { return @() }

    $groupMap = @{}
    foreach ($entry in @($Entries)) {
        $appId = [string]$entry.AppId
        if (-not $groupMap.ContainsKey($appId)) {
            $groupMap[$appId] = [pscustomobject][ordered]@{
                AppId = $appId
                GameName = [string]$entry.GameName
                AchievementsUrl = [string]$entry.AchievementsUrl
                LatestUnlockUtc = [string]$entry.UnlockTimeUtc
                Achievements = New-Object System.Collections.Generic.List[object]
            }
        }

        $group = $groupMap[$appId]
        $entryApiName = (Get-PropertyString $entry "ApiName").Trim()
        $entryName = (Get-PropertyString $entry "Name").Trim()
        $entryIconUrl = (Get-PropertyString $entry "IconUrl").Trim()
        $resolvedIconPath = Resolve-ExistingAchievementAssetPath ((Get-PropertyString $entry "IconPath").Trim())
        if ([string]::IsNullOrWhiteSpace($resolvedIconPath)) {
            $resolvedIconPath = Get-AchievementIconPath $appId $entryApiName $entryIconUrl
        }

        $group.Achievements.Add([pscustomobject][ordered]@{
            ApiName = $entryApiName
            Name = $entryName
            IconPath = [string]$resolvedIconPath
            IconUrl = $entryIconUrl
            RarityPercent = (Get-PropertyDouble $entry "RarityPercent" -1.0)
            OverlayTier = (Resolve-AchievementOverlayTierFromObject $entry)
            UnlockTimeUtc = [string]$entry.UnlockTimeUtc
        })

        if ((Get-UtcSortTicks ([string]$entry.UnlockTimeUtc)) -gt (Get-UtcSortTicks ([string]$group.LatestUnlockUtc))) {
            $group.LatestUnlockUtc = [string]$entry.UnlockTimeUtc
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($group in @(
        $groupMap.Values |
        Sort-Object @{ Expression = { Get-UtcSortTicks ([string]$_.LatestUnlockUtc) }; Descending = $true }, @{ Expression = { [string]$_.GameName }; Descending = $false }
    )) {
        $sortedAchievements = @(
            $group.Achievements.ToArray() |
            Sort-Object @{ Expression = { Get-UtcSortTicks ([string]$_.UnlockTimeUtc) }; Descending = $true }, @{ Expression = { [string]$_.Name }; Descending = $false }
        )

        if ($sortedAchievements.Count -eq 0) { continue }

        $result.Add([pscustomobject][ordered]@{
            AppId = [string]$group.AppId
            GameName = [string]$group.GameName
            AchievementsUrl = [string]$group.AchievementsUrl
            LatestUnlockUtc = [string]$group.LatestUnlockUtc
            Achievements = @($sortedAchievements)
        })
    }

    return @($result.ToArray())
}

function Get-RecentAchievementsByCount([object[]]$Items, [int]$MaxAchievements) {
    if ($MaxAchievements -le 0) { return @() }

    $selected = @(
        Get-RecentAchievementFlatEntries $Items |
        Select-Object -First $MaxAchievements
    )

    if ($selected.Count -eq 0) { return @() }
    return @(Get-ResolvedRecentAchievementGroups $selected)
}

function Get-EligibleRecentAchievements([object[]]$Items) {
    return @(Get-RecentAchievementsByCount $Items (Get-ConfiguredRecentAchievementDisplayCount))
}

function Get-CachedRecentAchievements([object[]]$Items) {
    return @(Get-RecentAchievementsByCount $Items $RecentAchievementIconCacheCount)
}

function Get-RecentAchievementsSignature([object[]]$Items) {
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add(("__header__|{0}|{1}" -f
        (Get-RecentAchievementExpirationLabel (Get-ConfiguredRecentAchievementExpirationMinutes)),
        (Get-AchievementOverlayThresholdSignature)
    ))
    $parts.Add("__layout__|GroupBottomPadding=4|TitleLeftInset=6|AchievementRowGap=2|AchievementBackground=0,0,0,255")

    foreach ($group in @($Items)) {
        foreach ($achievement in @($group.Achievements)) {
            $parts.Add(("{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}" -f
                [string]$group.AppId,
                [string]$group.GameName,
                [string]$group.AchievementsUrl,
                [string]$achievement.ApiName,
                [string]$achievement.Name,
                [string]$achievement.UnlockTimeUtc,
                [string]$achievement.IconPath,
                ((Get-PropertyDouble $achievement "RarityPercent" -1.0).ToString([Globalization.CultureInfo]::InvariantCulture)),
                (Get-PropertyString $achievement "OverlayTier").Trim()
            ))
        }
    }

    return [string]::Join("||", $parts.ToArray())
}

function Test-CanReuseRecentAchievementsRender([AllowNull()][object]$PreviousState, [int]$Width, [string]$Signature) {
    if ($null -eq $PreviousState) { return $false }
    if (-not (Get-PropertyBoolean $PreviousState "HasPanel" $false)) { return $false }
    if ((Get-PropertyInt $PreviousState "HeaderWidth" 0) -ne $Width) { return $false }
    if ((Get-PropertyString $PreviousState "Signature") -ne $Signature) { return $false }

    $groupPanels = @()
    if ($null -ne $PreviousState.PSObject.Properties["GroupPanels"] -and $null -ne $PreviousState.GroupPanels) {
        $groupPanels = @($PreviousState.GroupPanels)
    }
    if ($groupPanels.Count -eq 0) { return $false }

    foreach ($groupPanel in $groupPanels) {
        if ((Get-PropertyInt $groupPanel "Width" 0) -ne $Width) { return $false }
        $appId = (Get-PropertyString $groupPanel "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId)) { return $false }
        $expectedGroupPath = Get-AchievementGroupImagePath $appId
        $currentGroupPath = (Get-PropertyString $groupPanel "ImagePath").Trim()
        if ([string]::IsNullOrWhiteSpace($currentGroupPath)) { return $false }
        try {
            if ([IO.Path]::GetFullPath($currentGroupPath) -ne [IO.Path]::GetFullPath($expectedGroupPath)) {
                return $false
            }
        }
        catch {
            return $false
        }
        $groupPath = Resolve-ExistingAchievementAssetPath ((Get-PropertyString $groupPanel "ImagePath").Trim())
        if ([string]::IsNullOrWhiteSpace($groupPath)) { return $false }
    }

    return $true
}

function Get-WebStatusCode([System.Management.Automation.ErrorRecord]$ErrorRecord) {
    try {
        if ($null -ne $ErrorRecord.Exception.Response -and $null -ne $ErrorRecord.Exception.Response.StatusCode) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    }
    catch {}

    return 0
}

function Invoke-WebJson([string]$Uri) {
    return Invoke-RestMethod -Uri $Uri -Headers @{ "User-Agent" = "Mozilla/5.0 Mini-Steam-Launcher" }
}

function Get-SafeFileNameComponent([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "item" }
    $safe = $Value -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) { return "item" }
    return $safe
}

function Get-ConfiguredLayoutWidth([string]$SkinFilePath) {
    $defaultWidth = 231
    if ([string]::IsNullOrWhiteSpace($SkinFilePath) -or -not (Test-Path -LiteralPath $SkinFilePath)) {
        return $defaultWidth
    }

    try {
        return [int](Read-IniValue $SkinFilePath "GameArtWidth")
    }
    catch {
        return $defaultWidth
    }
}

$script:ConfiguredCommunityProfileBaseUrl = $null

function Get-CommunityProfileBaseUrl([string]$ProfileUrl, [string]$SteamId) {
    $candidate = ([string]$ProfileUrl).Trim()
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        try {
            $uri = [Uri]$candidate
            $path = $uri.AbsolutePath.Trim('/')
            if ($path -match '^(id|profiles)/([^/]+)$') {
                return ("https://steamcommunity.com/{0}/{1}/" -f $matches[1], $matches[2])
            }
        }
        catch {}
    }

    $safeSteamId = ([string]$SteamId).Trim()
    if (-not [string]::IsNullOrWhiteSpace($safeSteamId)) {
        return ("https://steamcommunity.com/profiles/{0}/" -f $safeSteamId)
    }

    return ""
}

function Get-ConfiguredCommunityProfileBaseUrl {
    if ($null -ne $script:ConfiguredCommunityProfileBaseUrl) {
        return [string]$script:ConfiguredCommunityProfileBaseUrl
    }

    $steamId = ""
    try { $steamId = (Read-IniValue $SteamAccountSettingsPath "SteamID64").Trim() } catch {}
    $resolvedUrl = Get-CommunityProfileBaseUrl "" $steamId

    $apiKey = ""
    try { $apiKey = (Read-IniValue $SteamAccountSettingsPath "SteamAPIKey").Trim() } catch {}
    if (
        -not [string]::IsNullOrWhiteSpace($apiKey) -and
        -not [string]::IsNullOrWhiteSpace($steamId) -and
        $apiKey -ne "YOUR_STEAM_WEB_API_KEY" -and
        $steamId -ne "YOUR_STEAMID64"
    ) {
        try {
            $response = Invoke-WebJson ("https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=$apiKey&steamids=$steamId&format=json")
            $player = @($response.response.players) | Select-Object -First 1
            $resolvedFromSummary = Get-CommunityProfileBaseUrl (Get-PropertyString $player "profileurl") $steamId
            if (-not [string]::IsNullOrWhiteSpace($resolvedFromSummary)) {
                $resolvedUrl = $resolvedFromSummary
            }
        }
        catch {
            Log ("Profile URL lookup fallback used: {0}" -f $_.Exception.Message)
        }
    }

    $script:ConfiguredCommunityProfileBaseUrl = $resolvedUrl
    return [string]$resolvedUrl
}

function Get-ConfiguredAchievementsPageUrl([string]$AppId) {
    if ([string]::IsNullOrWhiteSpace($AppId)) { return "" }

    $profileBaseUrl = Get-ConfiguredCommunityProfileBaseUrl
    if ([string]::IsNullOrWhiteSpace($profileBaseUrl)) { return "" }

    $webUrl = ("{0}stats/{1}/achievements/" -f $profileBaseUrl, $AppId)
    if ([string]::IsNullOrWhiteSpace($webUrl)) { return "" }
    return ("steam://openurl/{0}" -f $webUrl)
}

function Acquire-Lock {
    Ensure-ParentDirectory $LockPath
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        try {
            $script:LockStream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            return
        }
        catch [IO.IOException] {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Timed out waiting for RecentAchievements lock."
}

function Release-Lock {
    if ($null -ne $script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
    }
}

function Get-CandidateGames {
    $result = @()
    $seen = @{}
    $playedItems = Load-JsonArray $PlayedPath
    $playtimeItems = Load-JsonArray $PlaytimePath

    foreach ($item in @($playedItems)) {
        $appId = (Get-PropertyString $item "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId) -or $seen.ContainsKey($appId)) { continue }
        $seen[$appId] = $true
        $name = (Get-PropertyString $item "Name").Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Steam App $appId" }
        $result += [pscustomobject][ordered]@{ AppId = $appId; Name = $name }
        if ($result.Count -ge 10) { return @($result) }
    }

    foreach ($item in @($playtimeItems)) {
        $appId = (Get-PropertyString $item "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId) -or $seen.ContainsKey($appId)) { continue }
        $seen[$appId] = $true
        $name = (Get-PropertyString $item "Name").Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Steam App $appId" }
        $result += [pscustomobject][ordered]@{ AppId = $appId; Name = $name }
        if ($result.Count -ge 10) { break }
    }

    return @($result)
}

function Get-SchemaCachePath([string]$AppId) {
    return (Join-Path $SchemaCachePath ("Schema_{0}.json" -f $AppId))
}

function Save-GameSchema([string]$AppId, [object]$Schema) {
    if ([string]::IsNullOrWhiteSpace($AppId) -or $null -eq $Schema) { return }

    $cacheFile = Get-SchemaCachePath $AppId
    Ensure-ParentDirectory $cacheFile
    $tmp = "$cacheFile.new"
    [IO.File]::WriteAllText($tmp, ($Schema | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding($false)))
    $null = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    Move-Item -LiteralPath $tmp -Destination $cacheFile -Force
}

function Get-GameSchema([string]$ApiKey, [string]$AppId) {
    $cacheFile = Get-SchemaCachePath $AppId
    $cachedSchema = $null
    $isCacheFresh = $false

    if (Test-Path -LiteralPath $cacheFile) {
        try {
            $raw = [IO.File]::ReadAllText($cacheFile)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $cachedSchema = ($raw | ConvertFrom-Json)
                try {
                    $ageMinutes = (([DateTime]::UtcNow) - ((Get-Item -LiteralPath $cacheFile).LastWriteTimeUtc)).TotalMinutes
                    $isCacheFresh = ($ageMinutes -ge 0 -and $ageMinutes -le $SchemaCacheMaxAgeMinutes)
                }
                catch {
                    $isCacheFresh = $false
                }

                if ($isCacheFresh) {
                    return $cachedSchema
                }
            }
        }
        catch {
            Log ("Schema cache invalid for {0}; refetching. {1}" -f $AppId, $_.Exception.Message)
            $cachedSchema = $null
        }
    }

    $url = "https://api.steampowered.com/ISteamUserStats/GetSchemaForGame/v2/?key=$ApiKey&appid=$AppId"

    try {
        $schema = Invoke-WebJson $url
        if ($null -ne $cachedSchema) {
            $embeddedProperty = $cachedSchema.PSObject.Properties[$EmbeddedGlobalAchievementPercentPropertyName]
            if ($null -ne $embeddedProperty -and $null -ne $embeddedProperty.Value) {
                Add-Member -InputObject $schema -NotePropertyName $EmbeddedGlobalAchievementPercentPropertyName -NotePropertyValue $embeddedProperty.Value -Force
            }
        }
        Save-GameSchema $AppId $schema
        return $schema
    }
    catch {
        $statusCode = Get-WebStatusCode $_
        if ($statusCode -eq 0 -and $null -eq $cachedSchema) { throw }
        Log ("Schema fetch skipped for app {0}: {1}" -f $AppId, $_.Exception.Message)
        if ($null -ne $cachedSchema) {
            return $cachedSchema
        }
        return $null
    }
}

function Get-SchemaAchievementMap([AllowNull()][object]$Schema) {
    $map = @{}
    if ($null -eq $Schema) { return $map }

    foreach ($achievement in @($Schema.game.availableGameStats.achievements)) {
        $apiName = (Get-PropertyString $achievement "name").Trim()
        if ([string]::IsNullOrWhiteSpace($apiName)) { continue }
        $map[$apiName] = $achievement
    }

    return $map
}

function Normalize-GlobalAchievementPercentages([object[]]$Items) {
    $normalized = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($item in @($Items)) {
        $name = (Get-PropertyString $item "name").Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = (Get-PropertyString $item "Name").Trim()
        }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($seen.ContainsKey($name)) { continue }

        $percent = Get-PropertyDouble $item "percent" -1.0
        if ($percent -lt 0.0) {
            $percent = Get-PropertyDouble $item "Percent" -1.0
        }
        if ($percent -lt 0.0) { continue }

        $seen[$name] = $true
        $normalized.Add([pscustomobject][ordered]@{
            Name = $name
            Percent = [double]$percent
        })
    }

    return @(
        $normalized |
        Sort-Object @{ Expression = { [string]$_.Name }; Descending = $false }
    )
}

function Get-EmbeddedGlobalAchievementPercentState([AllowNull()][object]$Schema) {
    if ($null -eq $Schema) {
        return [pscustomobject]@{
            IsFresh = $false
            Percentages = @()
        }
    }

    $embedded = $Schema.PSObject.Properties[$EmbeddedGlobalAchievementPercentPropertyName]
    if ($null -eq $embedded -or $null -eq $embedded.Value) {
        return [pscustomobject]@{
            IsFresh = $false
            Percentages = @()
        }
    }

    $embeddedValue = $embedded.Value
    $percentages = @()
    try {
        $sourceItems = @()
        if ($null -ne $embeddedValue.PSObject.Properties["Achievements"] -and $null -ne $embeddedValue.Achievements) {
            $sourceItems = @($embeddedValue.Achievements)
        }
        else {
            $sourceItems = @($embeddedValue)
        }
        $percentages = @(Normalize-GlobalAchievementPercentages $sourceItems)
    }
    catch {
        $percentages = @()
    }

    $lastUpdatedUtc = Normalize-UtcString (Get-PropertyString $embeddedValue "LastUpdatedUtc")
    $isFresh = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($lastUpdatedUtc)) {
            $lastUpdated = [DateTimeOffset]::Parse($lastUpdatedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
            $ageMinutes = ([DateTimeOffset]::UtcNow - $lastUpdated.ToUniversalTime()).TotalMinutes
            $isFresh = ($ageMinutes -ge 0 -and $ageMinutes -le $GlobalAchievementPercentCacheMaxAgeMinutes)
        }
    }
    catch {
        $isFresh = $false
    }

    return [pscustomobject]@{
        IsFresh = $isFresh
        Percentages = @($percentages)
    }
}

function Set-EmbeddedGlobalAchievementPercentages([string]$AppId, [AllowNull()][object]$Schema, [object[]]$Percentages) {
    if ([string]::IsNullOrWhiteSpace($AppId) -or $null -eq $Schema) { return $Schema }

    $payload = [pscustomobject][ordered]@{
        LastUpdatedUtc = [DateTime]::UtcNow.ToString("o")
        Achievements = @(Normalize-GlobalAchievementPercentages $Percentages)
    }

    $existingProperty = $Schema.PSObject.Properties[$EmbeddedGlobalAchievementPercentPropertyName]
    if ($null -ne $existingProperty) {
        $existingProperty.Value = $payload
    }
    else {
        Add-Member -InputObject $Schema -NotePropertyName $EmbeddedGlobalAchievementPercentPropertyName -NotePropertyValue $payload
    }

    Save-GameSchema $AppId $Schema
    return $Schema
}

function Get-GlobalAchievementPercentages([string]$AppId, [AllowNull()][object]$Schema = $null) {
    if ([string]::IsNullOrWhiteSpace($AppId)) { return @() }

    $cached = Get-EmbeddedGlobalAchievementPercentState $Schema
    if ($cached.IsFresh) {
        return @($cached.Percentages)
    }

    $downloadUris = @(
        ("https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v0002/?gameid={0}&format=json" -f $AppId),
        ("https://partner.steam-api.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/?gameid={0}" -f $AppId)
    )

    foreach ($downloadUri in $downloadUris) {
        try {
            $response = Invoke-WebJson $downloadUri
            $responseItems = @()

            if ($null -ne $response -and $null -ne $response.PSObject.Properties["achievementpercentages"] -and $null -ne $response.achievementpercentages) {
                $achievementPercentages = $response.achievementpercentages
                if ($null -ne $achievementPercentages.PSObject.Properties["achievements"] -and $null -ne $achievementPercentages.achievements) {
                    $responseItems = @($achievementPercentages.achievements)
                }
                else {
                    $responseItems = @($achievementPercentages)
                }
            }
            else {
                $responseItems = @($response)
            }

            $normalized = @(Normalize-GlobalAchievementPercentages $responseItems)
            if ($normalized.Count -gt 0) {
                if ($null -ne $Schema) {
                    $null = Set-EmbeddedGlobalAchievementPercentages $AppId $Schema $normalized
                }
                return @($normalized)
            }
        }
        catch {
            Log ("Global achievement percentages fetch skipped for app {0}: {1}" -f $AppId, $_.Exception.Message)
        }
    }

    return @($cached.Percentages)
}

function Get-GlobalAchievementPercentMap([string]$AppId, [AllowNull()][object]$Schema = $null) {
    $map = @{}
    foreach ($entry in @(Get-GlobalAchievementPercentages $AppId $Schema)) {
        $name = (Get-PropertyString $entry "Name").Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $map[$name] = (Get-PropertyDouble $entry "Percent" -1.0)
    }

    return $map
}

function Resolve-FirstExistingPath([string[]]$Candidates) {
    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return ""
}

function Get-AchievementAssetCandidatePaths([string]$Path) {
    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $candidates.Add($Path)

        $fileName = ""
        try { $fileName = [IO.Path]::GetFileName($Path) } catch {}

        if (-not [string]::IsNullOrWhiteSpace($fileName)) {
            foreach ($basePath in @($ImageAssetPath, $AchievementAssetCachePath)) {
                $candidates.Add((Join-Path $basePath $fileName))
            }
        }
    }

    return @($candidates.ToArray())
}

function Test-LoadableImageFile([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($Path)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
    }
}

function Get-ImagePixelSize([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($Path)
        return [pscustomobject][ordered]@{
            Width = [int]$image.Width
            Height = [int]$image.Height
        }
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
    }
}

function Save-ResizedAchievementIconCache([string]$SourcePath, [string]$Destination) {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return $false }
    if (-not (Test-Path -LiteralPath $SourcePath)) { return $false }

    Ensure-ParentDirectory $Destination

    $sourceImage = $null
    $bitmap = $null
    $graphics = $null

    try {
        $sourceImage = [System.Drawing.Image]::FromFile($SourcePath)
        $bitmap = New-Object System.Drawing.Bitmap($AchievementIconCacheSize, $AchievementIconCacheSize, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.DrawImage($sourceImage, 0, 0, $AchievementIconCacheSize, $AchievementIconCacheSize)

        $tmp = "$Destination.render"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $bitmap.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)

        $graphics.Dispose()
        $graphics = $null
        $bitmap.Dispose()
        $bitmap = $null
        $sourceImage.Dispose()
        $sourceImage = $null

        Move-Item -LiteralPath $tmp -Destination $Destination -Force
        return $true
    }
    catch {
        Log ("Achievement icon resize skipped for {0}: {1}" -f $Destination, $_.Exception.Message)
        return $false
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $sourceImage) { $sourceImage.Dispose() }
    }
}

function Ensure-AchievementIconCacheSize([string]$Path) {
    $resolved = Resolve-ExistingAchievementAssetPath $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) { return "" }

    $size = Get-ImagePixelSize $resolved
    if (
        $null -ne $size -and
        [int]$size.Width -eq $AchievementIconCacheSize -and
        [int]$size.Height -eq $AchievementIconCacheSize
    ) {
        return $resolved
    }

    if (Save-ResizedAchievementIconCache $resolved $resolved) {
        return (Resolve-ExistingAchievementAssetPath $resolved)
    }

    return $resolved
}

function Resolve-ExistingAchievementAssetPath([string]$Path) {
    foreach ($candidate in @(Get-AchievementAssetCandidatePaths $Path)) {
        if (Test-LoadableImageFile $candidate) {
            return $candidate
        }
    }

    return ""
}

function Resolve-AchievementIconPath([string]$Path) {
    $resolved = Resolve-ExistingAchievementAssetPath $Path
    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
        return $resolved
    }

    $fallback = Resolve-ExistingAchievementAssetPath $FallbackAchievementIconPath
    if (-not [string]::IsNullOrWhiteSpace($fallback)) {
        return $fallback
    }

    return ""
}

function Get-AchievementIconFastlyUrl([string]$AppId, [string]$IconUrl) {
    if ([string]::IsNullOrWhiteSpace($IconUrl)) { return "" }

    try {
        $uri = [Uri]$IconUrl
        $fileName = [IO.Path]::GetFileName($uri.AbsolutePath)
        if ([string]::IsNullOrWhiteSpace($fileName)) { return "" }

        $resolvedAppId = $AppId
        $match = [regex]::Match($uri.AbsolutePath, "/images/apps/(?<appId>\d+)/(?<file>[^/?#]+)$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $matchedAppId = $match.Groups["appId"].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($matchedAppId)) {
                $resolvedAppId = $matchedAppId
            }
        }

        if ([string]::IsNullOrWhiteSpace($resolvedAppId)) { return "" }
        return ("https://shared.fastly.steamstatic.com/community_assets/images/apps/{0}/{1}" -f $resolvedAppId, $fileName)
    }
    catch {
        return ""
    }
}

function Get-AchievementIconDownloadUris([string]$AppId, [string]$IconUrl) {
    $uris = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($candidate in @(
        (Get-AchievementIconFastlyUrl $AppId $IconUrl),
        $IconUrl
    )) {
        $uri = ([string]$candidate).Trim()
        if ([string]::IsNullOrWhiteSpace($uri)) { continue }
        if ($seen.ContainsKey($uri)) { continue }
        $seen[$uri] = $true
        $uris.Add($uri)
    }

    return @($uris.ToArray())
}

function Get-AchievementIconCacheDestination([string]$AppId, [string]$ApiName, [string]$IconUrl) {
    $safeApiName = Get-SafeFileNameComponent $ApiName
    return (Join-Path $IconCachePath ("{0}_{1}.png" -f $AppId, $safeApiName))
}

function Get-CachedAchievementIconPath([string]$AppId, [string]$ApiName, [string]$IconUrl) {
    $destination = Get-AchievementIconCacheDestination $AppId $ApiName $IconUrl
    $existingPath = Ensure-AchievementIconCacheSize $destination
    if (-not [string]::IsNullOrWhiteSpace($existingPath)) {
        return $existingPath
    }

    return ""
}

function Get-AchievementIconPath([string]$AppId, [string]$ApiName, [string]$IconUrl) {
    $destination = Get-AchievementIconCacheDestination $AppId $ApiName $IconUrl

    $existingPath = Ensure-AchievementIconCacheSize $destination
    if (-not [string]::IsNullOrWhiteSpace($existingPath)) {
        return $existingPath
    }

    if ([string]::IsNullOrWhiteSpace($IconUrl)) {
        return (Resolve-AchievementIconPath "")
    }

    Ensure-ParentDirectory $destination
    $tmp = "$destination.download"
    $downloadErrorMessage = ""

    foreach ($downloadUri in @(Get-AchievementIconDownloadUris $AppId $IconUrl)) {
        try {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            Invoke-WebRequest -Uri $downloadUri -OutFile $tmp -UseBasicParsing -Headers @{ "User-Agent" = "Mozilla/5.0 Mini-Steam-Launcher" }
            if (Save-ResizedAchievementIconCache $tmp $destination) {
                if (Test-Path -LiteralPath $tmp) {
                    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                }
                return (Resolve-AchievementIconPath $destination)
            }
            Move-Item -LiteralPath $tmp -Destination $destination -Force
            return (Ensure-AchievementIconCacheSize $destination)
        }
        catch {
            $downloadErrorMessage = $_.Exception.Message

            if (Test-Path -LiteralPath $destination) {
                return (Resolve-AchievementIconPath $destination)
            }

            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Log ("Achievement icon download skipped for {0} ({1}): {2}" -f $AppId, $ApiName, $downloadErrorMessage)
    return (Resolve-AchievementIconPath "")
}

function Get-RecentAchievementsFromSteam([string]$ApiKey, [string]$SteamId, [object[]]$Candidates) {
    $groups = New-Object System.Collections.Generic.List[object]

    foreach ($candidate in @($Candidates)) {
        $appId = (Get-PropertyString $candidate "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId)) { continue }

        $url = "https://api.steampowered.com/ISteamUserStats/GetPlayerAchievements/v0001/?appid=$appId&key=$ApiKey&steamid=$SteamId"

        try {
            $response = Invoke-WebJson $url
        }
        catch {
            $statusCode = Get-WebStatusCode $_
            if ($statusCode -eq 0) { throw }
            Log ("Achievement state skipped for app {0}: {1}" -f $appId, $_.Exception.Message)
            continue
        }

        $playerStats = $response.playerstats
        if ($null -eq $playerStats) { continue }

        $successValue = $true
        if ($null -ne $playerStats.PSObject.Properties["success"]) {
            try { $successValue = [bool]$playerStats.success } catch { $successValue = $true }
        }
        if (-not $successValue) { continue }

        $recentAchievements = New-Object System.Collections.Generic.List[object]
        foreach ($achievement in @($playerStats.achievements)) {
            $achieved = $false
            if ($null -ne $achievement.PSObject.Properties["achieved"]) {
                try { $achieved = ([int]$achievement.achieved -eq 1) } catch { $achieved = $false }
            }
            if (-not $achieved) { continue }

            $unlockTimeUtc = ""
            try {
                $unlockTimeUtc = Convert-UnixSecondsToUtcString ([long]$achievement.unlocktime)
            }
            catch {
                $unlockTimeUtc = ""
            }

            if (-not (Test-IsAchievementWithinWindow $unlockTimeUtc)) { continue }

            $recentAchievements.Add([pscustomobject][ordered]@{
                ApiName = (Get-PropertyString $achievement "apiname").Trim()
                UnlockTimeUtc = $unlockTimeUtc
            })
        }

        if ($recentAchievements.Count -eq 0) { continue }

        $schema = Get-GameSchema $ApiKey $appId
        $schemaMap = Get-SchemaAchievementMap $schema
        $rarityMap = Get-GlobalAchievementPercentMap $appId $schema

        $gameName = (Get-PropertyString $schema.game "gameName").Trim()
        if ([string]::IsNullOrWhiteSpace($gameName)) {
            $gameName = (Get-PropertyString $playerStats "gameName").Trim()
        }
        if ([string]::IsNullOrWhiteSpace($gameName)) {
            $gameName = (Get-PropertyString $candidate "Name").Trim()
        }
        if ([string]::IsNullOrWhiteSpace($gameName)) {
            $gameName = "Steam App $appId"
        }

        $resolvedAchievements = New-Object System.Collections.Generic.List[object]
        foreach ($achievement in @(
            $recentAchievements |
            Sort-Object @{ Expression = { Get-UtcSortTicks ([string]$_.UnlockTimeUtc) }; Descending = $true }, @{ Expression = { [string]$_.ApiName }; Descending = $false }
        )) {
            $apiName = (Get-PropertyString $achievement "ApiName").Trim()
            if ([string]::IsNullOrWhiteSpace($apiName)) { continue }

            $schemaAchievement = $null
            if ($schemaMap.ContainsKey($apiName)) {
                $schemaAchievement = $schemaMap[$apiName]
            }

            $displayName = (Get-PropertyString $schemaAchievement "displayName").Trim()
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = $apiName
            }

            $iconUrl = (Get-PropertyString $schemaAchievement "icon").Trim()
            $iconPath = Get-CachedAchievementIconPath $appId $apiName $iconUrl
            $rarityPercent = -1.0
            if ($rarityMap.ContainsKey($apiName)) {
                try { $rarityPercent = [double]$rarityMap[$apiName] } catch { $rarityPercent = -1.0 }
            }
            $overlayTier = Get-AchievementOverlayTier $rarityPercent

            $resolvedAchievements.Add([pscustomobject][ordered]@{
                ApiName = $apiName
                Name = $displayName
                IconPath = $iconPath
                IconUrl = $iconUrl
                RarityPercent = [double]$rarityPercent
                OverlayTier = $overlayTier
                UnlockTimeUtc = [string]$achievement.UnlockTimeUtc
            })
        }

        if ($resolvedAchievements.Count -eq 0) { continue }

        $groups.Add([pscustomobject][ordered]@{
            AppId = $appId
            GameName = $gameName
            AchievementsUrl = (Get-ConfiguredAchievementsPageUrl $appId)
            LatestUnlockUtc = [string]$resolvedAchievements[0].UnlockTimeUtc
            Achievements = @($resolvedAchievements.ToArray())
        })
    }

    return @(Normalize-RecentAchievements ($groups.ToArray()))
}

function Get-StringFormat([bool]$CenterVertically) {
    $format = New-Object System.Drawing.StringFormat
    $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    if ($CenterVertically) {
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    }
    return $format
}

function Get-EllipsizedSingleLineText(
    [System.Drawing.Graphics]$Graphics,
    [System.Drawing.Font]$Font,
    [string]$Text,
    [float]$MaxWidth
) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    if ($MaxWidth -le 0) { return "..." }

    $plainSize = $Graphics.MeasureString($Text, $Font, 4096, [System.Drawing.StringFormat]::GenericTypographic)
    if ($plainSize.Width -le $MaxWidth) {
        return $Text
    }

    $ellipsis = "..."
    $ellipsisSize = $Graphics.MeasureString($ellipsis, $Font, 4096, [System.Drawing.StringFormat]::GenericTypographic)
    if ($ellipsisSize.Width -ge $MaxWidth) {
        return $ellipsis
    }

    $low = 0
    $high = $Text.Length
    $best = ""

    while ($low -le $high) {
        $mid = [int][Math]::Floor(($low + $high) / 2)
        $candidate = $Text.Substring(0, $mid) + $ellipsis
        $candidateSize = $Graphics.MeasureString($candidate, $Font, 4096, [System.Drawing.StringFormat]::GenericTypographic)

        if ($candidateSize.Width -le $MaxWidth) {
            $best = $candidate
            $low = $mid + 1
        }
        else {
            $high = $mid - 1
        }
    }

    if ([string]::IsNullOrWhiteSpace($best)) {
        return $ellipsis
    }

    return $best
}

function Save-RecentAchievementsHeaderImage([string]$Destination, [int]$Width, [string]$HeaderText) {
    Ensure-ParentDirectory $Destination

    $paddingX = 8
    $paddingTop = 0
    $paddingBottom = 0
    $headerFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $headerBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $backgroundBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 0, 0))
    $stringFormat = Get-StringFormat $true
    $headerHeight = [int][Math]::Max(1, [Math]::Ceiling($headerFont.GetHeight()))
    $height = [int]($paddingTop + $headerHeight + $paddingBottom)
    if ($height -lt 1) { $height = 1 }

    $bitmap = $null
    $graphics = $null

    try {
        $bitmap = New-Object System.Drawing.Bitmap($Width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.FillRectangle($backgroundBrush, 0, 0, $Width, $height)
        $graphics.DrawString(
            $HeaderText,
            $headerFont,
            $headerBrush,
            (New-Object System.Drawing.RectangleF($paddingX, $paddingTop, ($Width - ($paddingX * 2)), $headerHeight)),
            $stringFormat
        )

        $tmp = "$Destination.render"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $bitmap.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $backgroundBrush) { $backgroundBrush.Dispose() }
        if ($null -ne $headerBrush) { $headerBrush.Dispose() }
        if ($null -ne $headerFont) { $headerFont.Dispose() }
        if ($null -ne $stringFormat) { $stringFormat.Dispose() }
    }

    return [pscustomobject][ordered]@{
        ImagePath = $Destination
        Height = $height
        Width = $Width
    }
}

function Save-RecentAchievementGroupImage([object]$Group, [string]$Destination, [int]$Width) {
    Ensure-ParentDirectory $Destination

    $paddingX = 8
    $paddingTop = 0
    $paddingBottom = 4
    $iconSize = 36
    $iconGap = 6
    $titleLeftX = 6
    $achievementRowGap = 2

    $gameFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $achievementFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    $gameBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
    $achievementBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 255, 255, 255))
    $backgroundBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0, 0, 0))
    $stringFormat = Get-StringFormat $true
    $showAchievementRarity = Get-ConfiguredShowAchievementRarity

    $gameHeight = [int][Math]::Max(1, [Math]::Ceiling($gameFont.GetHeight()))
    $achievementHeight = [int][Math]::Max($iconSize, [Math]::Ceiling($achievementFont.GetHeight()))
    $achievementItems = @($Group.Achievements)
    $achievementCount = $achievementItems.Count
    $achievementGapTotal = 0
    if ($achievementCount -gt 1) {
        $achievementGapTotal = (($achievementCount - 1) * $achievementRowGap)
    }
    $height = [int]($paddingTop + $gameHeight + ($achievementCount * $achievementHeight) + $achievementGapTotal + $paddingBottom)
    if ($height -lt 1) { $height = 1 }

    $bitmap = $null
    $graphics = $null
    $overlayImageCache = @{}

    try {
        $bitmap = New-Object System.Drawing.Bitmap($Width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.FillRectangle($backgroundBrush, 0, 0, $Width, $height)

        $y = $paddingTop
        $graphics.DrawString(
            [string]$Group.GameName,
            $gameFont,
            $gameBrush,
            (New-Object System.Drawing.RectangleF($titleLeftX, $y, ($Width - $titleLeftX - $paddingX), $gameHeight)),
            $stringFormat
        )
        $y += $gameHeight

        for ($achievementIndex = 0; $achievementIndex -lt $achievementItems.Count; $achievementIndex++) {
            $achievement = $achievementItems[$achievementIndex]
            $iconX = $paddingX
            $textX = $paddingX
            $iconTopY = $y + [int][Math]::Floor(($achievementHeight - $iconSize) / 2)
            $iconPath = Resolve-AchievementIconPath ([string]$achievement.IconPath)
            $iconDrawn = $false

            if (-not [string]::IsNullOrWhiteSpace($iconPath) -and (Test-Path -LiteralPath $iconPath)) {
                $iconImage = $null
                try {
                    $iconImage = [System.Drawing.Image]::FromFile($iconPath)
                    $graphics.DrawImage($iconImage, $iconX, $iconTopY, $iconSize, $iconSize)
                    $textX = $iconX + $iconSize + $iconGap
                    $iconDrawn = $true
                }
                catch {
                    Log ("Achievement group icon skipped for {0}: {1}" -f [string]$achievement.ApiName, $_.Exception.Message)
                }
                finally {
                    if ($null -ne $iconImage) { $iconImage.Dispose() }
                }
            }

            $overlayTier = (Get-PropertyString $achievement "OverlayTier").Trim()
            if ([string]::IsNullOrWhiteSpace($overlayTier)) {
                $overlayTier = Get-AchievementOverlayTier (Get-PropertyDouble $achievement "RarityPercent" -1.0)
            }

            if ($showAchievementRarity -and $iconDrawn -and -not [string]::IsNullOrWhiteSpace($overlayTier)) {
                $overlayCacheKey = $overlayTier.ToLowerInvariant()
                $overlayImage = $null

                if ($overlayImageCache.ContainsKey($overlayCacheKey)) {
                    $overlayImage = $overlayImageCache[$overlayCacheKey]
                }
                else {
                    $overlayPath = Resolve-ExistingAchievementAssetPath (Get-AchievementOverlayImagePath $overlayTier)
                    if (-not [string]::IsNullOrWhiteSpace($overlayPath) -and (Test-Path -LiteralPath $overlayPath)) {
                        try {
                            $overlayImage = [System.Drawing.Image]::FromFile($overlayPath)
                        }
                        catch {
                            $overlayImage = $null
                            Log ("{0} achievement overlay skipped: {1}" -f $overlayTier, $_.Exception.Message)
                        }
                    }
                    $overlayImageCache[$overlayCacheKey] = $overlayImage
                }

                if ($null -ne $overlayImage) {
                    $graphics.DrawImage($overlayImage, $iconX, $iconTopY, $iconSize, $iconSize)
                }
            }

            $textWidth = [float]($Width - $textX - $paddingX)
            $achievementText = Get-EllipsizedSingleLineText $graphics $achievementFont ([string]$achievement.Name) $textWidth
            $graphics.DrawString(
                $achievementText,
                $achievementFont,
                $achievementBrush,
                (New-Object System.Drawing.RectangleF($textX, $y, $textWidth, $achievementHeight)),
                $stringFormat
            )
            $y += $achievementHeight
            if ($achievementIndex -lt ($achievementItems.Count - 1)) {
                $y += $achievementRowGap
            }
        }

        $tmp = "$Destination.render"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $bitmap.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        foreach ($overlayImage in @($overlayImageCache.Values)) {
            if ($null -ne $overlayImage) { $overlayImage.Dispose() }
        }
        if ($null -ne $backgroundBrush) { $backgroundBrush.Dispose() }
        if ($null -ne $gameBrush) { $gameBrush.Dispose() }
        if ($null -ne $achievementBrush) { $achievementBrush.Dispose() }
        if ($null -ne $gameFont) { $gameFont.Dispose() }
        if ($null -ne $achievementFont) { $achievementFont.Dispose() }
        if ($null -ne $stringFormat) { $stringFormat.Dispose() }
    }

    return [pscustomobject][ordered]@{
        AppId = [string]$Group.AppId
        Url = (Get-PropertyString $Group "AchievementsUrl").Trim()
        ImagePath = $Destination
        Height = $height
        Width = $Width
    }
}

function Save-RecentAchievementsRender([object[]]$Items, [int]$Width, [AllowNull()][object]$PreviousState) {
    $cachedEligible = @(Get-CachedRecentAchievements $Items)
    $eligible = @(Get-EligibleRecentAchievements $Items)
    $signature = Get-RecentAchievementsSignature $eligible

    if ($eligible.Count -eq 0) {
        Remove-StaleAchievementIconAssets $cachedEligible
        Remove-StaleAchievementRenderAssets $PreviousState @()
        return (Get-DefaultAchievementState)
    }

    if (Test-CanReuseRecentAchievementsRender $PreviousState $Width $signature) {
        $reusedGroups = New-Object System.Collections.Generic.List[object]
        $keepPaths = New-Object System.Collections.Generic.List[string]
        $totalHeight = 0

        foreach ($groupPanel in @($PreviousState.GroupPanels)) {
            $groupPath = Resolve-ExistingAchievementAssetPath ((Get-PropertyString $groupPanel "ImagePath").Trim())
            $groupHeight = Get-PropertyInt $groupPanel "Height" 0
            $reusedGroups.Add([pscustomobject][ordered]@{
                AppId = (Get-PropertyString $groupPanel "AppId").Trim()
                Url = (Get-PropertyString $groupPanel "Url").Trim()
                ImagePath = $groupPath
                Height = $groupHeight
                Width = $Width
            })
            $keepPaths.Add($groupPath)
            $totalHeight += $groupHeight
        }

        Remove-StaleAchievementIconAssets $cachedEligible
        Remove-StaleAchievementRenderAssets $PreviousState @($keepPaths.ToArray())
        Log ("Recent achievements render reused; signature unchanged.")
        return [pscustomobject][ordered]@{
            HasPanel = $true
            HeaderImagePath = ""
            HeaderHeight = 0
            HeaderWidth = $Width
            TotalHeight = $totalHeight
            Signature = $signature
            GroupPanels = @($reusedGroups.ToArray())
        }
    }

    $groupPanels = New-Object System.Collections.Generic.List[object]
    $keepPaths = New-Object System.Collections.Generic.List[string]
    $totalHeight = 0

    foreach ($group in $eligible) {
        $groupImagePath = Get-AchievementGroupImagePath ([string]$group.AppId)
        $groupState = Save-RecentAchievementGroupImage $group $groupImagePath $Width
        $groupPanels.Add($groupState)
        $keepPaths.Add($groupState.ImagePath)
        $totalHeight += [int]$groupState.Height
    }

    Remove-StaleAchievementIconAssets $cachedEligible
    Remove-StaleAchievementRenderAssets $PreviousState @($keepPaths.ToArray())

    return [pscustomobject][ordered]@{
        HasPanel = $true
        HeaderImagePath = ""
        HeaderHeight = 0
        HeaderWidth = [int]$Width
        TotalHeight = [int]$totalHeight
        Signature = $signature
        GroupPanels = @($groupPanels.ToArray())
    }
}

function Invoke-DisplayBuild([switch]$AchievementsOnly) {
    if (-not (Test-Path -LiteralPath $BuildDisplayScriptPath)) {
        throw "Missing BuildDisplay.ps1."
    }
    $buildArguments = @{
        ConfigName = $ConfigName
        NoExit = $true
    }
    if ($AchievementsOnly) {
        $buildArguments.AchievementsOnly = $true
    }
    & $BuildDisplayScriptPath @buildArguments
}

$shouldBuildDisplay = $false

try {
    New-Item -ItemType Directory -Path $CachePath -Force | Out-Null
    New-Item -ItemType Directory -Path $DataCachePath -Force | Out-Null

    Acquire-Lock

    $apiKey = Read-IniValue $SteamAccountSettingsPath "SteamAPIKey"
    $steamId = Read-IniValue $SteamAccountSettingsPath "SteamID64"
    if (-not (Test-SteamCredentialsConfigured $apiKey $steamId)) {
        exit 0
    }
    Assert-Configured $apiKey $steamId

    $previousState = Load-AchievementState
    $cachedItems = @(Load-RecentAchievementsCache)
    $effectiveItems = @($cachedItems)

    $candidates = @(Get-CandidateGames)
    if ($candidates.Count -gt 0) {
        try {
            $refreshedItems = @(Get-RecentAchievementsFromSteam $apiKey $steamId $candidates)
            Save-RecentAchievementsCache $refreshedItems
            $effectiveItems = @($refreshedItems)
            Log ("Recent achievements refreshed for {0} candidate games; groups={1}." -f $candidates.Count, $effectiveItems.Count)
        }
        catch {
            if ((Get-WebStatusCode $_) -eq 0) {
                Log ("Recent achievements refresh skipped; using cached data: {0}" -f $_.Exception.Message)
            }
            else {
                Log ("Recent achievements refresh error; using cached data: {0}" -f $_.Exception.Message)
            }
        }
    }

    $layoutWidth = Get-ConfiguredLayoutWidth $SkinPath
    $nextState = Save-RecentAchievementsRender $effectiveItems $layoutWidth $previousState
    Save-AchievementState $nextState

    $stateChanged = (
        ([bool]$previousState.HasPanel -ne [bool]$nextState.HasPanel) -or
        ([int]$previousState.HeaderHeight -ne [int]$nextState.HeaderHeight) -or
        ([int]$previousState.HeaderWidth -ne [int]$nextState.HeaderWidth) -or
        ([int]$previousState.TotalHeight -ne [int]$nextState.TotalHeight) -or
        ([string]$previousState.Signature -ne [string]$nextState.Signature) -or
        ([string]$previousState.HeaderImagePath -ne [string]$nextState.HeaderImagePath) -or
        (@($previousState.GroupPanels).Count -ne @($nextState.GroupPanels).Count)
    )

    if ($RebuildDisplay -eq "Always") {
        $shouldBuildDisplay = $true
    }
    elseif ($RebuildDisplay -eq "OnChange") {
        $shouldBuildDisplay = $stateChanged
    }
}
catch {
    $position = ""
    try { $position = [string]$_.InvocationInfo.PositionMessage } catch {}
    $exceptionType = ""
    try { $exceptionType = $_.Exception.GetType().FullName } catch {}
    if (-not [string]::IsNullOrWhiteSpace($position)) {
        Log ("UpdateRecentAchievements ERROR: {0} [{1}] at {2}" -f $_.Exception.Message, $exceptionType, $position.Trim())
    }
    else {
        Log ("UpdateRecentAchievements ERROR: {0} [{1}]" -f $_.Exception.Message, $exceptionType)
    }
    exit 1
}
finally {
    Release-Lock
}

if ($shouldBuildDisplay) {
    try {
        Invoke-DisplayBuild -AchievementsOnly
    }
    catch {
        Log ("UpdateRecentAchievements partial display apply failed; falling back to full rebuild: {0}" -f $_.Exception.Message)
        try {
            Invoke-DisplayBuild
        }
        catch {
            Log ("UpdateRecentAchievements build trigger ERROR: {0}" -f $_.Exception.Message)
            exit 1
        }
    }
}
