param(
    [string]$ConfigName = "",
    [switch]$AchievementsOnly,
    [switch]$NoExit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { Add-Type -AssemblyName System.Drawing } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CachePath = Join-Path $Root "Cache"
$DataCachePath = Join-Path $CachePath "Data"
$PlayedPath = Join-Path $DataCachePath "PlayedGames.json"
$PlaytimePath = Join-Path $DataCachePath "playtime_2weeks.json"
$GamesPath = Join-Path $DataCachePath "Games.inc"
$ConnectionStatePath = Join-Path $DataCachePath "ConnectionState.json"
$RecentAchievementsStatePath = Join-Path $DataCachePath "RecentAchievementsState.json"
$DisplayCacheStatePath = Join-Path $CachePath "DisplayCacheState.json"
$GameImageCachePath = Join-Path $CachePath "GameImages"
$AchievementAssetCachePath = Join-Path $CachePath "Achievements"
$SteamAccountSettingsPath = Join-Path $Root "SteamAccountInfo.inc"
$AdvancedSettingsPath = Join-Path $Root "AdvancedSettings.inc"
$LogPath = Join-Path $CachePath "Update.log"
$SkinPath = if ([string]::IsNullOrWhiteSpace($ConfigName)) { "" } else { Join-Path (Split-Path -Parent $Root) ("{0}.ini" -f $ConfigName) }

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

function Load-JsonArray([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $raw = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return ($raw | ConvertFrom-Json)
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

function Save-GamesInclude([string[]]$Lines) {
    Ensure-ParentDirectory $GamesPath
    $tmp = "$GamesPath.new"
    Set-Content -LiteralPath $tmp -Value $Lines -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $GamesPath -Force
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

function Get-ConfiguredDisplayGameCount([string]$Path) {
    try {
        $rawValue = Read-IniValue $Path "DisplayGameCount"
        $value = [int]$rawValue
    }
    catch {
        return 10
    }

    if ($value -lt 0) { return 0 }
    if ($value -gt 10) { return 10 }
    return $value
}

function Get-ConfiguredRecentlyPlayedExpirationMinutes([string]$Path) {
    $defaultMinutes = 20160

    try {
        $rawValue = Read-IniValue $Path "RecentlyPlayedExpirationMinutes"
        $value = [int]$rawValue
    }
    catch {
        return $defaultMinutes
    }

    if ($value -lt 0) { return 0 }
    if ($value -gt 525600) { return 525600 }
    return $value
}

function Get-DefaultConnectionState {
    return [pscustomobject][ordered]@{
        IsOffline = $false
        LastCheckedUtc = ""
        LastChangedUtc = ""
        LastError = ""
        LastSource = ""
    }
}

function Load-ConnectionState {
    if (-not (Test-Path -LiteralPath $ConnectionStatePath)) {
        return Get-DefaultConnectionState
    }

    try {
        $raw = [IO.File]::ReadAllText($ConnectionStatePath)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Get-DefaultConnectionState
        }

        $data = $raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            IsOffline = Get-PropertyBoolean $data "IsOffline" $false
            LastCheckedUtc = Get-PropertyString $data "LastCheckedUtc"
            LastChangedUtc = Get-PropertyString $data "LastChangedUtc"
            LastError = Get-PropertyString $data "LastError"
            LastSource = Get-PropertyString $data "LastSource"
        }
    }
    catch {
        Log ("ConnectionState.json was invalid and has been ignored: {0}" -f $_.Exception.Message)
        return Get-DefaultConnectionState
    }
}

function Get-DefaultRecentAchievementsState {
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

function Load-RecentAchievementsState {
    if (-not (Test-Path -LiteralPath $RecentAchievementsStatePath)) {
        return Get-DefaultRecentAchievementsState
    }

    try {
        $raw = [IO.File]::ReadAllText($RecentAchievementsStatePath)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Get-DefaultRecentAchievementsState
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
        Log ("RecentAchievementsState.json was invalid and has been ignored: {0}" -f $_.Exception.Message)
        return Get-DefaultRecentAchievementsState
    }
}

function Load-GamesIncludeVariableMap {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $GamesPath)) { return $map }

    $inVariablesSection = $false
    foreach ($line in @(Get-Content -LiteralPath $GamesPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*\[Variables\]\s*$') {
            $inVariablesSection = $true
            continue
        }

        if (-not $inVariablesSection) { continue }
        if ($line -match '^\s*\[') { break }
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*;') { continue }

        $match = [regex]::Match($line, '^\s*([^=]+?)\s*=\s*(.*)$')
        if (-not $match.Success) { continue }
        $map[$match.Groups[1].Value.Trim()] = $match.Groups[2].Value
    }

    return $map
}

function Save-GamesIncludeVariableMap([AllowNull()][object]$VariableMap) {
    $lines = @("; Generated by BuildDisplay.ps1", "", "[Variables]", "")
    if ($null -ne $VariableMap) {
        foreach ($entry in $VariableMap.GetEnumerator()) {
            $lines += ("{0}={1}" -f [string]$entry.Key, [string]$entry.Value)
        }
    }
    Save-GamesInclude $lines
}

function Get-VariableMapString([AllowNull()][object]$VariableMap, [string]$Name, [string]$DefaultValue = "") {
    if ($null -eq $VariableMap) { return $DefaultValue }
    if (-not $VariableMap.Contains($Name)) { return $DefaultValue }
    return [string]$VariableMap[$Name]
}

function Get-VariableMapDouble([AllowNull()][object]$VariableMap, [string]$Name, [double]$DefaultValue = 0.0) {
    $rawValue = (Get-VariableMapString $VariableMap $Name "")
    if ([string]::IsNullOrWhiteSpace($rawValue)) { return $DefaultValue }

    try {
        return [double]::Parse($rawValue, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        try {
            return [double]$rawValue
        }
        catch {
            return $DefaultValue
        }
    }
}

function Get-VariableMapInt([AllowNull()][object]$VariableMap, [string]$Name, [int]$DefaultValue = 0) {
    return [int][Math]::Floor((Get-VariableMapDouble $VariableMap $Name $DefaultValue))
}

function Get-AchievementSectionState([int]$BottomRowY, [double]$BottomRowHeight, [AllowNull()][object]$RecentAchievementsState = $null) {
    if ($null -eq $RecentAchievementsState) {
        $RecentAchievementsState = Load-RecentAchievementsState
    }

    $hasRecentAchievements = [bool](Get-PropertyBoolean $RecentAchievementsState "HasPanel" $false)
    $recentAchievementsHeaderImage = ""
    $resolvedRecentAchievementsHeaderImagePath = ""
    $recentAchievementsHeaderHeight = 0
    $recentAchievementsHeaderY = [int][Math]::Floor($BottomRowY + $BottomRowHeight)
    $recentAchievementsTotalHeight = 0
    $recentAchievementsBottomY = $recentAchievementsHeaderY
    $recentAchievementsTopPadY = $recentAchievementsHeaderY
    $recentAchievementsTopPadHeight = 0
    $recentAchievementsBottomPadY = $recentAchievementsHeaderY
    $recentAchievementsBottomPadHeight = 0
    $achievementGroupPanels = @()
    $achievementSectionTopPadding = 5
    $achievementSectionBottomPadding = 3

    $resolvedRecentAchievementsHeaderImagePath = Resolve-AchievementAssetPath ([string](Get-PropertyString $RecentAchievementsState "HeaderImagePath"))
    if ($hasRecentAchievements) {
        if (-not [string]::IsNullOrWhiteSpace($resolvedRecentAchievementsHeaderImagePath)) {
            $recentAchievementsHeaderImage = Convert-ToRainmeterResourcePath $resolvedRecentAchievementsHeaderImagePath
            $recentAchievementsHeaderHeight = [int](Get-PropertyInt $RecentAchievementsState "HeaderHeight" 0)
        }
        $recentAchievementsTotalHeight = $recentAchievementsHeaderHeight
        $recentAchievementsTopPadY = $recentAchievementsHeaderY + $recentAchievementsHeaderHeight
        $groupY = $recentAchievementsTopPadY

        foreach ($groupPanel in @($RecentAchievementsState.GroupPanels)) {
            if ($achievementGroupPanels.Count -ge 10) { break }

            $imagePath = Resolve-AchievementAssetPath ((Get-PropertyString $groupPanel "ImagePath").Trim())
            $height = Get-PropertyInt $groupPanel "Height" 0
            $url = (Get-PropertyString $groupPanel "Url").Trim()
            $appId = (Get-PropertyString $groupPanel "AppId").Trim()

            if ([string]::IsNullOrWhiteSpace($imagePath)) { continue }
            if (-not (Test-Path -LiteralPath $imagePath)) { continue }
            if ($height -le 0) { continue }

            $achievementGroupPanels += [pscustomobject][ordered]@{
                AppId = $appId
                Image = Convert-ToRainmeterResourcePath $imagePath
                ResolvedImagePath = $imagePath
                Y = $groupY
                Height = $height
                Url = $url
            }
            $groupY += $height
            $recentAchievementsTotalHeight += $height
        }

        if ($achievementGroupPanels.Count -gt 0) {
            $recentAchievementsTopPadHeight = $achievementSectionTopPadding
            $recentAchievementsTotalHeight += $achievementSectionTopPadding
            foreach ($groupPanel in $achievementGroupPanels) {
                $groupPanel.Y += $achievementSectionTopPadding
            }
            $recentAchievementsTotalHeight += $achievementSectionBottomPadding
            $recentAchievementsBottomPadHeight = $achievementSectionBottomPadding
        }

        $recentAchievementsBottomY = $recentAchievementsHeaderY + $recentAchievementsTotalHeight
        $recentAchievementsBottomPadY = $recentAchievementsBottomY - $recentAchievementsBottomPadHeight

        if ($achievementGroupPanels.Count -eq 0) {
            $hasRecentAchievements = $false
            $recentAchievementsHeaderImage = ""
            $resolvedRecentAchievementsHeaderImagePath = ""
            $recentAchievementsHeaderHeight = 0
            $recentAchievementsTotalHeight = 0
            $recentAchievementsBottomY = $recentAchievementsHeaderY
            $recentAchievementsTopPadY = $recentAchievementsHeaderY
            $recentAchievementsTopPadHeight = 0
            $recentAchievementsBottomPadY = $recentAchievementsHeaderY
            $recentAchievementsBottomPadHeight = 0
            $achievementGroupPanels = @()
        }
    }

    return [pscustomobject][ordered]@{
        HasRecentAchievements = $hasRecentAchievements
        RecentAchievementsHeaderImage = $recentAchievementsHeaderImage
        ResolvedRecentAchievementsHeaderImagePath = $resolvedRecentAchievementsHeaderImagePath
        RecentAchievementsHeaderHeight = $recentAchievementsHeaderHeight
        RecentAchievementsHeaderY = $recentAchievementsHeaderY
        RecentAchievementsTotalHeight = $recentAchievementsTotalHeight
        RecentAchievementsBottomY = $recentAchievementsBottomY
        RecentAchievementsTopPadY = $recentAchievementsTopPadY
        RecentAchievementsTopPadHeight = $recentAchievementsTopPadHeight
        RecentAchievementsBottomPadY = $recentAchievementsBottomPadY
        RecentAchievementsBottomPadHeight = $recentAchievementsBottomPadHeight
        AchievementGroupPanels = @($achievementGroupPanels)
    }
}

function Update-GamesIncludeAchievementVariables([AllowNull()][object]$VariableMap, [AllowNull()][object]$AchievementSection) {
    if ($null -eq $VariableMap) {
        throw "Games.inc variables are unavailable."
    }
    if ($null -eq $AchievementSection) {
        throw "Achievement section state is unavailable."
    }

    $VariableMap["HasRecentAchievements"] = $(if ($AchievementSection.HasRecentAchievements) { "1" } else { "0" })
    $VariableMap["RecentAchievementsHeaderImage"] = [string]$AchievementSection.RecentAchievementsHeaderImage
    $VariableMap["RecentAchievementsHeaderY"] = [string]$AchievementSection.RecentAchievementsHeaderY
    $VariableMap["RecentAchievementsHeaderHeight"] = [string]$AchievementSection.RecentAchievementsHeaderHeight
    $VariableMap["RecentAchievementsTopPadY"] = [string]$AchievementSection.RecentAchievementsTopPadY
    $VariableMap["RecentAchievementsTopPadHeight"] = [string]$AchievementSection.RecentAchievementsTopPadHeight
    $VariableMap["RecentAchievementsTotalHeight"] = [string]$AchievementSection.RecentAchievementsTotalHeight
    $VariableMap["RecentAchievementsBottomY"] = [string]$AchievementSection.RecentAchievementsBottomY
    $VariableMap["RecentAchievementsBottomPadY"] = [string]$AchievementSection.RecentAchievementsBottomPadY
    $VariableMap["RecentAchievementsBottomPadHeight"] = [string]$AchievementSection.RecentAchievementsBottomPadHeight
    $VariableMap["AchievementGroupCount"] = [string](@($AchievementSection.AchievementGroupPanels).Count)

    for ($i = 0; $i -lt 10; $i++) {
        if ($i -lt @($AchievementSection.AchievementGroupPanels).Count) {
            $groupPanel = $AchievementSection.AchievementGroupPanels[$i]
            $VariableMap["AchievementGroup$($i + 1)Y"] = [string]$groupPanel.Y
            $VariableMap["AchievementGroup$($i + 1)Height"] = [string]$groupPanel.Height
            $VariableMap["AchievementGroup$($i + 1)Image"] = Clean ([string]$groupPanel.Image)
            $VariableMap["AchievementGroup$($i + 1)URL"] = Clean ([string]$groupPanel.Url)
            $VariableMap["AchievementGroup$($i + 1)AppId"] = Clean ([string]$groupPanel.AppId)
        }
        else {
            $VariableMap["AchievementGroup$($i + 1)Y"] = "0"
            $VariableMap["AchievementGroup$($i + 1)Height"] = "0"
            $VariableMap["AchievementGroup$($i + 1)Image"] = ""
            $VariableMap["AchievementGroup$($i + 1)URL"] = ""
            $VariableMap["AchievementGroup$($i + 1)AppId"] = ""
        }
    }
}

function Apply-AchievementSectionToRainmeter([string]$TargetConfigName, [AllowNull()][object]$AchievementSection) {
    if ([string]::IsNullOrWhiteSpace($TargetConfigName)) { return }

    $rainmeter = Find-RainmeterExe
    if (-not $rainmeter) { return }
    if ($null -eq $AchievementSection) { return }

    & $rainmeter "!SetVariable" "HasRecentAchievements" $(if ($AchievementSection.HasRecentAchievements) { 1 } else { 0 }) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsHeaderImage" ([string]$AchievementSection.RecentAchievementsHeaderImage) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsHeaderY" ([string]$AchievementSection.RecentAchievementsHeaderY) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsHeaderHeight" ([string]$AchievementSection.RecentAchievementsHeaderHeight) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsTopPadY" ([string]$AchievementSection.RecentAchievementsTopPadY) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsTopPadHeight" ([string]$AchievementSection.RecentAchievementsTopPadHeight) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsTotalHeight" ([string]$AchievementSection.RecentAchievementsTotalHeight) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsBottomY" ([string]$AchievementSection.RecentAchievementsBottomY) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsBottomPadY" ([string]$AchievementSection.RecentAchievementsBottomPadY) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "RecentAchievementsBottomPadHeight" ([string]$AchievementSection.RecentAchievementsBottomPadHeight) $TargetConfigName | Out-Null
    & $rainmeter "!SetVariable" "AchievementGroupCount" (@($AchievementSection.AchievementGroupPanels).Count) $TargetConfigName | Out-Null

    for ($i = 0; $i -lt 10; $i++) {
        if ($i -lt @($AchievementSection.AchievementGroupPanels).Count) {
            $groupPanel = $AchievementSection.AchievementGroupPanels[$i]
            & $rainmeter "!SetVariable" ("AchievementGroup{0}Y" -f ($i + 1)) ([string]$groupPanel.Y) $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}Height" -f ($i + 1)) ([string]$groupPanel.Height) $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}Image" -f ($i + 1)) ([string]$groupPanel.Image) $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}URL" -f ($i + 1)) ([string]$groupPanel.Url) $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}AppId" -f ($i + 1)) ([string]$groupPanel.AppId) $TargetConfigName | Out-Null
        }
        else {
            & $rainmeter "!SetVariable" ("AchievementGroup{0}Y" -f ($i + 1)) 0 $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}Height" -f ($i + 1)) 0 $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}Image" -f ($i + 1)) "" $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}URL" -f ($i + 1)) "" $TargetConfigName | Out-Null
            & $rainmeter "!SetVariable" ("AchievementGroup{0}AppId" -f ($i + 1)) "" $TargetConfigName | Out-Null
        }
    }

    if ($AchievementSection.HasRecentAchievements) {
        if (-not [string]::IsNullOrWhiteSpace([string]$AchievementSection.ResolvedRecentAchievementsHeaderImagePath) -and [int]$AchievementSection.RecentAchievementsHeaderHeight -gt 0) {
            & $rainmeter "!SetOption" "MeterRecentAchievementsHeader" "ImageName" ([string]$AchievementSection.ResolvedRecentAchievementsHeaderImagePath) $TargetConfigName | Out-Null
            & $rainmeter "!ShowMeter" "MeterRecentAchievementsHeader" $TargetConfigName | Out-Null
        }
        else {
            & $rainmeter "!SetOption" "MeterRecentAchievementsHeader" "ImageName" "" $TargetConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterRecentAchievementsHeader" $TargetConfigName | Out-Null
        }

        if ([int]$AchievementSection.RecentAchievementsTopPadHeight -gt 0) {
            & $rainmeter "!ShowMeter" "MeterRecentAchievementsTopPad" $TargetConfigName | Out-Null
        }
        else {
            & $rainmeter "!HideMeter" "MeterRecentAchievementsTopPad" $TargetConfigName | Out-Null
        }

        if ([int]$AchievementSection.RecentAchievementsBottomPadHeight -gt 0) {
            & $rainmeter "!ShowMeter" "MeterRecentAchievementsBottomPad" $TargetConfigName | Out-Null
        }
        else {
            & $rainmeter "!HideMeter" "MeterRecentAchievementsBottomPad" $TargetConfigName | Out-Null
        }
    }
    else {
        & $rainmeter "!SetOption" "MeterRecentAchievementsHeader" "ImageName" "" $TargetConfigName | Out-Null
        & $rainmeter "!HideMeter" "MeterRecentAchievementsHeader" $TargetConfigName | Out-Null
        & $rainmeter "!HideMeter" "MeterRecentAchievementsTopPad" $TargetConfigName | Out-Null
        & $rainmeter "!HideMeter" "MeterRecentAchievementsBottomPad" $TargetConfigName | Out-Null
    }

    for ($i = 1; $i -le 10; $i++) {
        $groupMeter = "MeterAchievementGroup{0}" -f $i
        if ($i -le @($AchievementSection.AchievementGroupPanels).Count) {
            $groupPanel = $AchievementSection.AchievementGroupPanels[$i - 1]
            if (-not [string]::IsNullOrWhiteSpace([string]$groupPanel.ResolvedImagePath)) {
                & $rainmeter "!SetOption" $groupMeter "ImageName" ([string]$groupPanel.ResolvedImagePath) $TargetConfigName | Out-Null
            }
            else {
                & $rainmeter "!SetOption" $groupMeter "ImageName" "" $TargetConfigName | Out-Null
            }
            & $rainmeter "!ShowMeter" $groupMeter $TargetConfigName | Out-Null
        }
        else {
            & $rainmeter "!SetOption" $groupMeter "ImageName" "" $TargetConfigName | Out-Null
            & $rainmeter "!HideMeter" $groupMeter $TargetConfigName | Out-Null
        }
    }

    & $rainmeter "!ShowMeter" "MeterRecentAchievementsBounds" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "*" $TargetConfigName | Out-Null
    & $rainmeter "!Update" $TargetConfigName | Out-Null
    & $rainmeter "!Redraw" $TargetConfigName | Out-Null
}

function Invoke-AchievementsOnlyDisplayApply([string]$TargetConfigName) {
    $variables = Load-GamesIncludeVariableMap
    if (@($variables.Keys).Count -eq 0) {
        throw "Games.inc is missing; a full rebuild is required."
    }

    $bottomRowYRaw = (Get-VariableMapString $variables "BottomRowY" "")
    $bottomRowHeightRaw = (Get-VariableMapString $variables "BottomRowHeight" "")
    if ([string]::IsNullOrWhiteSpace($bottomRowYRaw) -or [string]::IsNullOrWhiteSpace($bottomRowHeightRaw)) {
        throw "Games.inc does not contain the current bottom-row layout."
    }

    $bottomRowY = Get-VariableMapInt $variables "BottomRowY" 0
    $bottomRowHeight = Get-VariableMapDouble $variables "BottomRowHeight" 0.0
    $achievementSection = Get-AchievementSectionState $bottomRowY $bottomRowHeight (Load-RecentAchievementsState)

    Update-GamesIncludeAchievementVariables $variables $achievementSection
    Save-GamesIncludeVariableMap $variables
    Apply-AchievementSectionToRainmeter $TargetConfigName $achievementSection
}

function Get-DefaultDisplayCacheState {
    return [pscustomobject][ordered]@{
        ProfileAvatarUrl = ""
    }
}

function Load-DisplayCacheState {
    if (-not (Test-Path -LiteralPath $DisplayCacheStatePath)) {
        return Get-DefaultDisplayCacheState
    }

    try {
        $raw = [IO.File]::ReadAllText($DisplayCacheStatePath)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return Get-DefaultDisplayCacheState
        }

        $data = $raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            ProfileAvatarUrl = Get-PropertyString $data "ProfileAvatarUrl"
        }
    }
    catch {
        Log ("DisplayCacheState.json was invalid and has been ignored: {0}" -f $_.Exception.Message)
        return Get-DefaultDisplayCacheState
    }
}

function Save-DisplayCacheState([object]$State) {
    Ensure-ParentDirectory $DisplayCacheStatePath
    $tmp = "$DisplayCacheStatePath.new"
    [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $DisplayCacheStatePath -Force
}

function Clean([AllowNull()][string]$Value) {
    if ($null -eq $Value) { return "" }
    return ($Value -replace "`r", " " -replace "`n", " ")
}

function Get-ExpirationDisplayLabel([int]$Minutes) {
    if ($Minutes -ge 1440 -and ($Minutes % 1440) -eq 0 -and ($Minutes / 1440) -le 365) {
        $value = [int]($Minutes / 1440)
        return ("{0} day{1}" -f $value, $(if ($value -eq 1) { "" } else { "s" }))
    }

    if ($Minutes -ge 60 -and ($Minutes % 60) -eq 0 -and ($Minutes / 60) -le 365) {
        $value = [int]($Minutes / 60)
        return ("{0} hour{1}" -f $value, $(if ($value -eq 1) { "" } else { "s" }))
    }

    $value = [Math]::Min([Math]::Max($Minutes, 0), 365)
    return ("{0} minute{1}" -f $value, $(if ($value -eq 1) { "" } else { "s" }))
}

function Test-IsRecentlyPlayedWithinWindow([string]$LastPlayedUtc, [int]$ExpirationMinutes) {
    if ([string]::IsNullOrWhiteSpace($LastPlayedUtc)) { return $false }

    try {
        $lastPlayed = [DateTimeOffset]::Parse($LastPlayedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        $cutoff = [DateTimeOffset]::UtcNow.AddMinutes(-1 * $ExpirationMinutes)
        return ($lastPlayed.ToUniversalTime() -ge $cutoff)
    }
    catch {
        return $false
    }
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

function Resolve-GameImagePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    $fileName = ""
    try { $fileName = [IO.Path]::GetFileName($Path) } catch {}

    return (Resolve-FirstExistingPath @(
        $Path,
        $(if (-not [string]::IsNullOrWhiteSpace($fileName)) { Join-Path $GameImageCachePath $fileName } else { "" })
    ))
}

function Resolve-AchievementAssetPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }

    $fileName = ""
    try { $fileName = [IO.Path]::GetFileName($Path) } catch {}

    return (Resolve-FirstExistingPath @(
        $Path,
        $(if (-not [string]::IsNullOrWhiteSpace($fileName)) { Join-Path $AchievementAssetCachePath $fileName } else { "" })
    ))
}

function Convert-ToRainmeterResourcePath([string]$AbsolutePath) {
    if ([string]::IsNullOrWhiteSpace($AbsolutePath)) { return "" }

    try {
        $fullRoot = [IO.Path]::GetFullPath($Root)
        $fullPath = [IO.Path]::GetFullPath($AbsolutePath)
        $prefix = $fullRoot.TrimEnd('\') + '\'
        if ($fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $fullPath.Substring($prefix.Length).Replace('/', '\')
            return ("#@#{0}" -f $relativePath)
        }
    }
    catch {
        Log ("Resource path conversion fallback used for {0}: {1}" -f $AbsolutePath, $_.Exception.Message)
    }

    return $AbsolutePath
}

function Test-CachedImageAvailable([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $image = $null
    $isUsable = $false
    $removePath = $false
    $failureReason = ""

    try {
        $image = [System.Drawing.Image]::FromFile($Path)
        $isUsable = $true
    }
    catch {
        $removePath = $true
        $failureReason = $_.Exception.Message
    }
    finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
    }

    if ($removePath -and (Test-Path -LiteralPath $Path)) {
        try {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        catch {}
        Log ("Removed invalid cached image for {0}: {1} ({2})" -f $Label, $Path, $failureReason)
    }

    return $isUsable
}

function Invoke-Download([string]$Uri, [string]$Destination, [string]$Label) {
    Ensure-ParentDirectory $Destination
    $tmp = "$Destination.download"
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        Invoke-WebRequest -Uri $Uri -OutFile $tmp -UseBasicParsing -Headers @{ "User-Agent" = "Mozilla/5.0 Mini-Steam-Launcher" }
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
        return [pscustomobject]@{
            Success = $true
            NotFound = $false
            StatusCode = 200
            Error = ""
        }
    }
    catch {
        $statusCode = 0
        try {
            if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        catch {}

        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        Log ("Download skipped for {0}: {1}" -f $Label, $_.Exception.Message)
        return [pscustomobject]@{
            Success = $false
            NotFound = ($statusCode -eq 404)
            StatusCode = $statusCode
            Error = $_.Exception.Message
        }
    }
}

function Try-Download([string]$Uri, [string]$Destination, [string]$Label) {
    return (Invoke-Download $Uri $Destination $Label).Success
}

function Get-VisibleImageBounds([System.Drawing.Bitmap]$Bitmap) {
    if ($null -eq $Bitmap) {
        return (New-Object System.Drawing.Rectangle 0, 0, 1, 1)
    }

    $left = $Bitmap.Width
    $top = $Bitmap.Height
    $right = -1
    $bottom = -1

    for ($y = 0; $y -lt $Bitmap.Height; $y++) {
        for ($x = 0; $x -lt $Bitmap.Width; $x++) {
            $pixel = $Bitmap.GetPixel($x, $y)
            if ($pixel.A -gt 8) {
                if ($x -lt $left) { $left = $x }
                if ($y -lt $top) { $top = $y }
                if ($x -gt $right) { $right = $x }
                if ($y -gt $bottom) { $bottom = $y }
            }
        }
    }

    if ($right -lt $left -or $bottom -lt $top) {
        return (New-Object System.Drawing.Rectangle 0, 0, $Bitmap.Width, $Bitmap.Height)
    }

    return (New-Object System.Drawing.Rectangle $left, $top, ($right - $left + 1), ($bottom - $top + 1))
}

function Save-CoverImage([string]$SourcePath, [string]$Destination, [int]$TargetWidth, [int]$TargetHeight, [bool]$TrimTransparentBounds) {
    if ($TargetWidth -le 0 -or $TargetHeight -le 0) {
        throw "Invalid target size: ${TargetWidth}x${TargetHeight}"
    }

    Ensure-ParentDirectory $Destination

    $sourceImage = $null
    $sourceBitmap = $null
    $targetBitmap = $null
    $graphics = $null

    try {
        $sourceImage = [System.Drawing.Image]::FromFile($SourcePath)
        $sourceBitmap = New-Object System.Drawing.Bitmap($sourceImage)
        $sourceRect = New-Object System.Drawing.Rectangle 0, 0, $sourceBitmap.Width, $sourceBitmap.Height

        if ($TrimTransparentBounds) {
            $sourceRect = Get-VisibleImageBounds $sourceBitmap
        }

        if ($sourceRect.Width -le 0 -or $sourceRect.Height -le 0) {
            throw "Image has no visible area: $SourcePath"
        }

        $scale = [Math]::Max(
            $TargetWidth / [double]$sourceRect.Width,
            $TargetHeight / [double]$sourceRect.Height
        )
        $scaledWidth = $sourceRect.Width * $scale
        $scaledHeight = $sourceRect.Height * $scale
        $offsetX = ($TargetWidth - $scaledWidth) / 2.0
        $offsetY = ($TargetHeight - $scaledHeight) / 2.0

        $targetBitmap = New-Object System.Drawing.Bitmap($TargetWidth, $TargetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($targetBitmap)
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality

        $destinationRect = New-Object System.Drawing.RectangleF $offsetX, $offsetY, $scaledWidth, $scaledHeight
        $graphics.DrawImage($sourceBitmap, $destinationRect, $sourceRect, [System.Drawing.GraphicsUnit]::Pixel)

        $tmp = "$Destination.render"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $targetBitmap.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
        Move-Item -LiteralPath $tmp -Destination $Destination -Force
    }
    finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $targetBitmap) { $targetBitmap.Dispose() }
        if ($null -ne $sourceBitmap) { $sourceBitmap.Dispose() }
        if ($null -ne $sourceImage) { $sourceImage.Dispose() }
    }
}

function Get-GameArt([string]$AppId, [string]$Destination, [int]$TargetWidth, [int]$TargetHeight, [string]$Label, [bool]$AllowDownload) {
    if (Test-CachedImageAvailable $Destination $Label) {
        return $true
    }

    if (-not $AllowDownload) {
        return $false
    }

    $candidates = @(
        [pscustomobject]@{
            Name = "capsule_231x87"
            Uri = "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/capsule_231x87.jpg"
            TrimTransparentBounds = $false
            TempExtension = ".jpg"
        },
        [pscustomobject]@{
            Name = "header"
            Uri = "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/header.jpg"
            TrimTransparentBounds = $false
            TempExtension = ".jpg"
        },
        [pscustomobject]@{
            Name = "logo_2x"
            Uri = "https://cdn.cloudflare.steamstatic.com/steam/apps/$AppId/logo_2x.png"
            TrimTransparentBounds = $true
            TempExtension = ".png"
        }
    )

    $hadRecoverableFailure = $false

    foreach ($candidate in $candidates) {
        $tempSourcePath = "{0}.{1}{2}" -f $Destination, $candidate.Name, $candidate.TempExtension
        $download = Invoke-Download $candidate.Uri $tempSourcePath ("$Label $($candidate.Name)")

        if ($download.Success) {
            try {
                Save-CoverImage $tempSourcePath $Destination $TargetWidth $TargetHeight $candidate.TrimTransparentBounds
                Log ("Using {0} art for {1} ({2})" -f $candidate.Name, $Label, $AppId)
                return $true
            }
            catch {
                $hadRecoverableFailure = $true
                Log ("Art processing failed for {0} using {1}: {2}" -f $Label, $candidate.Name, $_.Exception.Message)
            }
            finally {
                if (Test-Path -LiteralPath $tempSourcePath) {
                    Remove-Item -LiteralPath $tempSourcePath -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            if (-not $download.NotFound) {
                $hadRecoverableFailure = $true
            }

            if (Test-Path -LiteralPath $tempSourcePath) {
                Remove-Item -LiteralPath $tempSourcePath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($hadRecoverableFailure -and (Test-CachedImageAvailable $Destination $Label)) {
        Log ("Retaining cached art for {0} ({1}) because refresh failed without a confirmed 404-only fallback path." -f $Label, $AppId)
        return $true
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }

    Log ("No usable art found for {0} ({1}); falling back to text only." -f $Label, $AppId)
    return $false
}

function Get-ImageAspectRatio([string]$ImagePath, [double]$FallbackRatio) {
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path -LiteralPath $ImagePath)) {
        return $FallbackRatio
    }

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($ImagePath)
        if ($null -eq $image -or $image.Height -le 0) {
            return $FallbackRatio
        }
        return ($image.Width / [double]$image.Height)
    }
    catch {
        Log ("Image size probe failed for {0}: {1}" -f $ImagePath, $_.Exception.Message)
        return $FallbackRatio
    }
    finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
    }
}

function Get-ImagePixelSize([string]$ImagePath) {
    if ([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path -LiteralPath $ImagePath)) {
        return $null
    }

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($ImagePath)
        return [pscustomobject]@{
            Width = [int]$image.Width
            Height = [int]$image.Height
        }
    }
    catch {
        Log ("Image size read failed for {0}: {1}" -f $ImagePath, $_.Exception.Message)
        return $null
    }
    finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
    }
}

function Ensure-CachedImageAtDisplaySize(
    [string]$Path,
    [int]$TargetWidth,
    [int]$TargetHeight,
    [string]$Label,
    [bool]$TrimTransparentBounds = $false
) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    if ($TargetWidth -le 0 -or $TargetHeight -le 0) {
        return $false
    }

    $currentSize = Get-ImagePixelSize $Path
    if ($null -ne $currentSize -and $currentSize.Width -eq $TargetWidth -and $currentSize.Height -eq $TargetHeight) {
        return $true
    }

    try {
        Save-CoverImage $Path $Path $TargetWidth $TargetHeight $TrimTransparentBounds
        Log ("Resized cached {0} to display size {1}x{2}." -f $Label, $TargetWidth, $TargetHeight)
        return $true
    }
    catch {
        Log ("Display-size cache resize skipped for {0}: {1}" -f $Label, $_.Exception.Message)
        return $false
    }
}

function Get-BottomRowLayout([double]$BannerAspectRatio, [double]$ProfileAspectRatio, [int]$TotalWidth, [int]$FallbackHeight) {
    if ($BannerAspectRatio -le 0) { $BannerAspectRatio = 1.0 }
    if ($ProfileAspectRatio -le 0) { $ProfileAspectRatio = 1.0 }
    if ($TotalWidth -le 0) { $TotalWidth = 231 }
    $height = $TotalWidth / ($BannerAspectRatio + $ProfileAspectRatio)
    if ($height -le 0) {
        $height = [Math]::Max(1, $FallbackHeight)
    }
    $bannerWidth = $BannerAspectRatio * $height
    $profileWidth = $TotalWidth - $bannerWidth
    return [pscustomobject]@{
        Height = $height
        BannerWidth = $bannerWidth
        ProfileWidth = $profileWidth
    }
}

function Format-LayoutNumber([double]$Value) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $Value)
}

function Find-RainmeterExe {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "Rainmeter\Rainmeter.exe") }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} "Rainmeter\Rainmeter.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Rainmeter\Rainmeter.exe") }
    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Show-RebuildOverlay([string]$TargetConfigName) {
    if ([string]::IsNullOrWhiteSpace($TargetConfigName)) { return }

    $rainmeter = Find-RainmeterExe
    if (-not $rainmeter) { return }

    & $rainmeter "!UpdateMeasure" "MeasureRebuildOverlayHeight" $TargetConfigName | Out-Null
    & $rainmeter "!ShowMeter" "MeterRebuildOverlayBox" $TargetConfigName | Out-Null
    & $rainmeter "!ShowMeter" "MeterRebuildOverlayText" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "MeterRebuildOverlayBox" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "MeterRebuildOverlayText" $TargetConfigName | Out-Null
    & $rainmeter "!Redraw" $TargetConfigName | Out-Null
}

function Hide-RebuildOverlay([string]$TargetConfigName) {
    if ([string]::IsNullOrWhiteSpace($TargetConfigName)) { return }

    $rainmeter = Find-RainmeterExe
    if (-not $rainmeter) { return }

    & $rainmeter "!HideMeter" "MeterRebuildOverlayBox" $TargetConfigName | Out-Null
    & $rainmeter "!HideMeter" "MeterRebuildOverlayText" $TargetConfigName | Out-Null
    & $rainmeter "!Redraw" $TargetConfigName | Out-Null
}

try {
    Ensure-ParentDirectory $GamesPath
    New-Item -ItemType Directory -Path $CachePath -Force | Out-Null
    New-Item -ItemType Directory -Path $DataCachePath -Force | Out-Null
    New-Item -ItemType Directory -Path $GameImageCachePath -Force | Out-Null
    New-Item -ItemType Directory -Path $AchievementAssetCachePath -Force | Out-Null

    if ($AchievementsOnly) {
        Invoke-AchievementsOnlyDisplayApply $ConfigName
        Log "Achievement display updated without a full launcher rebuild."
        return
    }

    Show-RebuildOverlay $ConfigName

    $layoutWidth = 231
    $layoutHeight = 87
    if (-not [string]::IsNullOrWhiteSpace($SkinPath) -and (Test-Path -LiteralPath $SkinPath)) {
        try {
            $layoutWidth = [int](Read-IniValue $SkinPath "GameArtWidth")
        }
        catch {
            Log ("Layout width fallback used: {0}" -f $_.Exception.Message)
        }
        try {
            $layoutHeight = [int](Read-IniValue $SkinPath "GameArtHeight")
        }
        catch {
            Log ("Layout height fallback used: {0}" -f $_.Exception.Message)
        }
    }
    $displayGameCount = Get-ConfiguredDisplayGameCount $AdvancedSettingsPath
    $recentlyPlayedExpirationMinutes = Get-ConfiguredRecentlyPlayedExpirationMinutes $AdvancedSettingsPath
    $apiKey = ""
    $steamId = ""
    try { $apiKey = Read-IniValue $SteamAccountSettingsPath "SteamAPIKey" } catch {}
    try { $steamId = Read-IniValue $SteamAccountSettingsPath "SteamID64" } catch {}
    $credentialsConfigured = Test-SteamCredentialsConfigured $apiKey $steamId

    if (-not $credentialsConfigured) {
        $credentialsMissingText = "Steam account not set click here to add credentials"
        $inc = @(
            "; Generated by BuildDisplay.ps1",
            "",
            "[Variables]",
            "",
            "CredentialsMissing=1",
            ("CredentialsMissingText={0}" -f $credentialsMissingText),
            "DisplayGameCount=0",
            ("RecentlyPlayedExpirationMinutes={0}" -f $recentlyPlayedExpirationMinutes),
            "RecentEligibleSignature=",
            "IsOffline=0",
            "VisibleGamesCount=0",
            "LaunchedGamesCount=0",
            "OfflineBarText=",
            "OfflineBarY=0",
            "OfflineBarTextY=0",
            "RecordBarText=",
            "RecordBarY=0",
            "RecordBarTextY=0",
            "BottomRowY=0",
            "",
            "ProfileURL=",
            "ProfileImage=",
            "BannerImage=",
            "BannerWidth=0",
            "ProfileWidth=0",
            "BottomRowHeight=0",
            "HasRecentAchievements=0",
            "RecentAchievementsHeaderImage=",
            "RecentAchievementsHeaderY=0",
            "RecentAchievementsHeaderHeight=0",
            "RecentAchievementsTopPadY=0",
            "RecentAchievementsTopPadHeight=0",
            "RecentAchievementsTotalHeight=0",
            "RecentAchievementsBottomY=0",
            "RecentAchievementsBottomPadY=0",
            "RecentAchievementsBottomPadHeight=0",
            "AchievementGroupCount=0",
            ""
        )

        for ($i = 1; $i -le 10; $i++) {
            $inc += ("Game{0}Name=" -f $i)
            $inc += ("Game{0}ID=" -f $i)
            $inc += ("Game{0}Image=" -f $i)
            $inc += ("Game{0}LastPlayed=" -f $i)
            $inc += ""
        }

        for ($i = 1; $i -le 10; $i++) {
            $inc += ("AchievementGroup{0}Y=0" -f $i)
            $inc += ("AchievementGroup{0}Height=0" -f $i)
            $inc += ("AchievementGroup{0}Image=" -f $i)
            $inc += ("AchievementGroup{0}URL=" -f $i)
            $inc += ("AchievementGroup{0}AppId=" -f $i)
        }
        $inc += ""

        Save-GamesInclude $inc

        $rainmeter = Find-RainmeterExe
        if ($rainmeter -and -not [string]::IsNullOrWhiteSpace($ConfigName)) {
            & $rainmeter "!SetVariable" "CredentialsMissing" 1 $ConfigName | Out-Null
            & $rainmeter "!SetVariable" "CredentialsMissingText" $credentialsMissingText $ConfigName | Out-Null
            & $rainmeter "!SetVariable" "DisplayGameCount" 0 $ConfigName | Out-Null
            & $rainmeter "!SetVariable" "VisibleGamesCount" 0 $ConfigName | Out-Null
            & $rainmeter "!SetVariable" "LaunchedGamesCount" 0 $ConfigName | Out-Null
            & $rainmeter "!SetVariable" "HasRecentAchievements" 0 $ConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterGame1InGameIcon" $ConfigName | Out-Null

            for ($i = 1; $i -le 10; $i++) {
                & $rainmeter "!SetVariable" ("Game{0}Name" -f $i) "" $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("Game{0}ID" -f $i) "" $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("Game{0}Image" -f $i) "" $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("Game{0}LastPlayed" -f $i) "" $ConfigName | Out-Null
                & $rainmeter "!HideMeter" ("MeterGame{0}Image" -f $i) $ConfigName | Out-Null
                & $rainmeter "!HideMeter" ("MeterGame{0}Fallback" -f $i) $ConfigName | Out-Null
                & $rainmeter "!HideMeter" ("MeterGame{0}FallbackText" -f $i) $ConfigName | Out-Null
                & $rainmeter "!HideMeter" ("MeterAchievementGroup{0}" -f $i) $ConfigName | Out-Null
            }

            foreach ($meterName in @(
                "MeterRecordBar",
                "MeterRecordBarText",
                "MeterOfflineBar",
                "MeterOfflineBarText",
                "MeterSteam",
                "MeterProfile",
                "MeterRecentAchievementsHeader",
                "MeterRecentAchievementsTopPad",
                "MeterRecentAchievementsBottomPad",
                "MeterRecentAchievementsBounds"
            )) {
                & $rainmeter "!HideMeter" $meterName $ConfigName | Out-Null
            }

            & $rainmeter "!ShowMeter" "MeterCredentialsMissingBox" $ConfigName | Out-Null
            & $rainmeter "!ShowMeter" "MeterCredentialsMissingText" $ConfigName | Out-Null
            & $rainmeter "!UpdateMeter" "*" $ConfigName | Out-Null
            & $rainmeter "!Update" $ConfigName | Out-Null
            & $rainmeter "!Redraw" $ConfigName | Out-Null
        }

        Log "Display rebuilt with credentials-missing fallback."
        return
    }

    $connectionState = Load-ConnectionState
    $displayCacheState = Load-DisplayCacheState
    $isOffline = [bool]$connectionState.IsOffline

    $played = @(Load-JsonArray $PlayedPath)
    $playtime = @(Load-JsonArray $PlaytimePath)

    $display = New-Object System.Collections.Generic.List[object]
    $used = @{}
    $recentEligibleAppIds = New-Object System.Collections.Generic.List[string]

    foreach ($g in $played) {
        if ($display.Count -ge 10) { break }
        $id = [string]$g.AppId
        $lastPlayedUtc = if ($null -ne $g.PSObject.Properties["LastPlayedUtc"]) { [string]$g.LastPlayedUtc } else { "" }
        if ([string]::IsNullOrWhiteSpace($id) -or $used.ContainsKey($id)) { continue }
        if (-not (Test-IsRecentlyPlayedWithinWindow $lastPlayedUtc $recentlyPlayedExpirationMinutes)) { continue }
        $display.Add([pscustomobject][ordered]@{
            AppId = $id
            Name = [string]$g.Name
            LastPlayedUtc = $lastPlayedUtc
        })
        $used[$id] = $true
        $recentEligibleAppIds.Add($id)
    }

    foreach ($g in $playtime) {
        if ($display.Count -ge 10) { break }
        $id = [string]$g.AppId
        if ([string]::IsNullOrWhiteSpace($id) -or $used.ContainsKey($id)) { continue }
        $display.Add([pscustomobject][ordered]@{
            AppId = $id
            Name = [string]$g.Name
            LastPlayedUtc = ""
        })
        $used[$id] = $true
    }

    $launchedGamesCount = $display.Count
    $recentEligibleSignature = [string]::Join("|", @($recentEligibleAppIds))
    $visibleGameCount = [Math]::Min($launchedGamesCount, $displayGameCount)
    $slots = @()
    for ($i = 0; $i -lt 10; $i++) {
        $slot = $i + 1
        if ($i -lt $visibleGameCount) {
            $game = $display[$i]
            $id = [string]$game.AppId
            $imageVar = ""
            $resolvedImagePath = ""
            $imagePath = Join-Path $GameImageCachePath ("GameArt_{0}.png" -f $id)
            $existingGameImagePath = Resolve-GameImagePath $imagePath
            if (
                -not [string]::IsNullOrWhiteSpace($existingGameImagePath) -and
                $existingGameImagePath -ne $imagePath -and
                -not (Test-Path -LiteralPath $imagePath)
            ) {
                Copy-Item -LiteralPath $existingGameImagePath -Destination $imagePath -Force
            }
            if (Get-GameArt $id $imagePath $layoutWidth $layoutHeight ("game slot $slot") (-not $isOffline)) {
                $imageVar = Convert-ToRainmeterResourcePath $imagePath
                $resolvedImagePath = $imagePath
            }

            $slots += [pscustomobject][ordered]@{
                Name = Clean ([string]$game.Name)
                AppId = $id
                Image = $imageVar
                ResolvedImagePath = $resolvedImagePath
                LastPlayedUtc = [string]$game.LastPlayedUtc
            }
        }
        else {
            $slots += [pscustomobject][ordered]@{
                Name = ""
                AppId = ""
                Image = ""
                ResolvedImagePath = ""
                LastPlayedUtc = ""
            }
        }
    }

    $recordBarHeight = 24
    $showOfflineBar = $isOffline
    $showRecordBar = $displayGameCount -gt $launchedGamesCount
    $offlineBarY = $visibleGameCount * $layoutHeight
    $offlineBarTextY = $offlineBarY + [int][Math]::Floor($recordBarHeight / 2)
    $recordBarY = $offlineBarY + $(if ($showOfflineBar) { $recordBarHeight } else { 0 })
    $recordBarTextY = $recordBarY + [int][Math]::Floor($recordBarHeight / 2)
    $bottomRowY = $recordBarY + $(if ($showRecordBar) { $recordBarHeight } else { 0 })
    $offlineBarText = "No internet conection"
    $recordBarText = "{0} launched games on record." -f $launchedGamesCount

    $defaultBannerPath = Join-Path $Root "Steam.jpg"
    $bannerImage = if (Test-Path -LiteralPath $defaultBannerPath) { Convert-ToRainmeterResourcePath $defaultBannerPath } else { "" }
    $resolvedBannerImagePath = if (Test-Path -LiteralPath $defaultBannerPath) { $defaultBannerPath } else { "" }
    $bannerAppId = ""

    if ($display.Count -gt 0) {
        $bannerAppId = [string]$display[0].AppId
        if (-not [string]::IsNullOrWhiteSpace($bannerAppId)) {
            $bannerImagePath = Join-Path $GameImageCachePath ("Banner_{0}.jpg" -f $bannerAppId)
            $existingBannerImagePath = Resolve-GameImagePath $bannerImagePath
            if (
                -not [string]::IsNullOrWhiteSpace($existingBannerImagePath) -and
                $existingBannerImagePath -ne $bannerImagePath -and
                -not (Test-Path -LiteralPath $bannerImagePath)
            ) {
                Copy-Item -LiteralPath $existingBannerImagePath -Destination $bannerImagePath -Force
            }
            if (Test-CachedImageAvailable $bannerImagePath ("library hero banner for $bannerAppId")) {
                $bannerImage = Convert-ToRainmeterResourcePath $bannerImagePath
                $resolvedBannerImagePath = $bannerImagePath
            }
            elseif (
                -not $isOffline -and
                (Try-Download "https://cdn.cloudflare.steamstatic.com/steam/apps/$bannerAppId/library_hero.jpg" $bannerImagePath ("library hero banner for $bannerAppId"))
            ) {
                $bannerImage = Convert-ToRainmeterResourcePath $bannerImagePath
                $resolvedBannerImagePath = $bannerImagePath
            }
            elseif (Test-CachedImageAvailable $bannerImagePath ("library hero banner for $bannerAppId")) {
                $bannerImage = Convert-ToRainmeterResourcePath $bannerImagePath
                $resolvedBannerImagePath = $bannerImagePath
            }
        }
    }

    $profileUrl = ""
    $profileImagePath = Join-Path $CachePath "Profile.jpg"
    $profileImage = if (Test-CachedImageAvailable $profileImagePath "profile image") { Convert-ToRainmeterResourcePath $profileImagePath } else { "" }
    $resolvedProfileImagePath = if (Test-CachedImageAvailable $profileImagePath "profile image") { $profileImagePath } else { "" }
    $activeGameId = ""

    try {
        $apiKey = Read-IniValue $SteamAccountSettingsPath "SteamAPIKey"
        $steamId = Read-IniValue $SteamAccountSettingsPath "SteamID64"
        $profileUrl = Get-CommunityProfileBaseUrl "" $steamId

        if (
            -not $isOffline -and
            -not [string]::IsNullOrWhiteSpace($apiKey) -and
            -not [string]::IsNullOrWhiteSpace($steamId) -and
            $apiKey -ne "YOUR_STEAM_WEB_API_KEY" -and
            $steamId -ne "YOUR_STEAMID64"
        ) {
            $profileResp = Invoke-RestMethod -Uri ("https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=$apiKey&steamids=$steamId&format=json") -Headers @{ "User-Agent" = "Mozilla/5.0 Mini-Steam-Launcher" }
            $profile = @($profileResp.response.players) | Select-Object -First 1

            if ($profile) {
                $resolvedProfileUrl = Get-CommunityProfileBaseUrl (Get-PropertyString $profile "profileurl") $steamId
                if (-not [string]::IsNullOrWhiteSpace($resolvedProfileUrl)) {
                    $profileUrl = $resolvedProfileUrl
                }
                $activeGameId = (Get-PropertyString $profile "gameid").Trim()

                if ($null -ne $profile.PSObject.Properties["avatarfull"]) {
                    $avatar = [string]$profile.avatarfull
                    if (-not [string]::IsNullOrWhiteSpace($avatar)) {
                        $cachedAvatarUrl = (Get-PropertyString $displayCacheState "ProfileAvatarUrl").Trim()
                        $needsProfileRefresh = (
                            -not (Test-CachedImageAvailable $profileImagePath "profile image") -or
                            ($avatar -ne $cachedAvatarUrl)
                        )

                        if ($needsProfileRefresh) {
                            [void](Try-Download $avatar $profileImagePath "profile image")
                        }

                        if (Test-CachedImageAvailable $profileImagePath "profile image") {
                            $profileImage = Convert-ToRainmeterResourcePath $profileImagePath
                            $resolvedProfileImagePath = $profileImagePath
                            if ($cachedAvatarUrl -ne $avatar) {
                                $displayCacheState.ProfileAvatarUrl = $avatar
                            }
                        }
                    }
                }
            }
        }
    }
    catch {
        Log ("Profile refresh skipped: {0}" -f $_.Exception.Message)
    }

    $showTopGameInGameIcon = (
        $visibleGameCount -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($activeGameId) -and
        ([string]$slots[0].AppId -eq $activeGameId)
    )

    try {
        Save-DisplayCacheState $displayCacheState
    }
    catch {
        Log ("Display cache state save skipped: {0}" -f $_.Exception.Message)
    }

    $bannerAspectRatio = Get-ImageAspectRatio $resolvedBannerImagePath 3.0
    $profileAspectRatio = Get-ImageAspectRatio $resolvedProfileImagePath 1.0
    $bottomRowLayout = Get-BottomRowLayout $bannerAspectRatio $profileAspectRatio $layoutWidth 40
    $bannerWidth = [double]$bottomRowLayout.BannerWidth
    $profileWidth = [double]$bottomRowLayout.ProfileWidth
    $bottomRowHeight = [double]$bottomRowLayout.Height
    $bannerTargetWidth = [Math]::Max(1, [int][Math]::Round($bannerWidth))
    $profileTargetWidth = [Math]::Max(1, [int][Math]::Round($profileWidth))
    $bottomRowTargetHeight = [Math]::Max(1, [int][Math]::Round($bottomRowHeight))

    if (
        -not [string]::IsNullOrWhiteSpace($resolvedBannerImagePath) -and
        (Test-Path -LiteralPath $resolvedBannerImagePath) -and
        $resolvedBannerImagePath -ne $defaultBannerPath
    ) {
        [void](Ensure-CachedImageAtDisplaySize $resolvedBannerImagePath $bannerTargetWidth $bottomRowTargetHeight "banner")
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedProfileImagePath) -and (Test-Path -LiteralPath $resolvedProfileImagePath)) {
        [void](Ensure-CachedImageAtDisplaySize $resolvedProfileImagePath $profileTargetWidth $bottomRowTargetHeight "profile image")
    }

    $achievementSection = Get-AchievementSectionState $bottomRowY $bottomRowHeight (Load-RecentAchievementsState)
    $hasRecentAchievements = [bool]$achievementSection.HasRecentAchievements
    $recentAchievementsHeaderImage = [string]$achievementSection.RecentAchievementsHeaderImage
    $resolvedRecentAchievementsHeaderImagePath = [string]$achievementSection.ResolvedRecentAchievementsHeaderImagePath
    $recentAchievementsHeaderHeight = [int]$achievementSection.RecentAchievementsHeaderHeight
    $recentAchievementsHeaderY = [int]$achievementSection.RecentAchievementsHeaderY
    $recentAchievementsTotalHeight = [int]$achievementSection.RecentAchievementsTotalHeight
    $recentAchievementsBottomY = [int]$achievementSection.RecentAchievementsBottomY
    $recentAchievementsTopPadY = [int]$achievementSection.RecentAchievementsTopPadY
    $recentAchievementsTopPadHeight = [int]$achievementSection.RecentAchievementsTopPadHeight
    $recentAchievementsBottomPadY = [int]$achievementSection.RecentAchievementsBottomPadY
    $recentAchievementsBottomPadHeight = [int]$achievementSection.RecentAchievementsBottomPadHeight
    $achievementGroupPanels = @($achievementSection.AchievementGroupPanels)

    $inc = @("; Generated by BuildDisplay.ps1", "", "[Variables]", "")
    $inc += "CredentialsMissing=0"
    $inc += "CredentialsMissingText="
    $inc += ""
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $slot = $i + 1
        $item = $slots[$i]
        $inc += ("Game{0}Name={1}" -f $slot, $item.Name)
        $inc += ("Game{0}ID={1}" -f $slot, $item.AppId)
        $inc += ("Game{0}Image={1}" -f $slot, $item.Image)
        $inc += ("Game{0}LastPlayed={1}" -f $slot, $item.LastPlayedUtc)
        $inc += ""
    }
    $inc += ("DisplayGameCount={0}" -f $displayGameCount)
    $inc += ("RecentlyPlayedExpirationMinutes={0}" -f $recentlyPlayedExpirationMinutes)
    $inc += ("RecentEligibleSignature={0}" -f $recentEligibleSignature)
    $inc += ("IsOffline={0}" -f $(if ($showOfflineBar) { 1 } else { 0 }))
    $inc += ("VisibleGamesCount={0}" -f $visibleGameCount)
    $inc += ("LaunchedGamesCount={0}" -f $launchedGamesCount)
    $inc += ("OfflineBarText={0}" -f (Clean $offlineBarText))
    $inc += ("OfflineBarY={0}" -f $offlineBarY)
    $inc += ("OfflineBarTextY={0}" -f $offlineBarTextY)
    $inc += ("RecordBarText={0}" -f (Clean $recordBarText))
    $inc += ("RecordBarY={0}" -f $recordBarY)
    $inc += ("RecordBarTextY={0}" -f $recordBarTextY)
    $inc += ("BottomRowY={0}" -f $bottomRowY)
    $inc += ""
    $inc += ("ProfileURL={0}" -f $profileUrl)
    $inc += ("ProfileImage={0}" -f $profileImage)
    $inc += ("BannerImage={0}" -f $bannerImage)
    $inc += ("BannerWidth={0}" -f (Format-LayoutNumber $bannerWidth))
    $inc += ("ProfileWidth={0}" -f (Format-LayoutNumber $profileWidth))
    $inc += ("BottomRowHeight={0}" -f (Format-LayoutNumber $bottomRowHeight))
    $inc += ("HasRecentAchievements={0}" -f $(if ($hasRecentAchievements) { 1 } else { 0 }))
    $inc += ("RecentAchievementsHeaderImage={0}" -f $recentAchievementsHeaderImage)
    $inc += ("RecentAchievementsHeaderY={0}" -f $recentAchievementsHeaderY)
    $inc += ("RecentAchievementsHeaderHeight={0}" -f $recentAchievementsHeaderHeight)
    $inc += ("RecentAchievementsTopPadY={0}" -f $recentAchievementsTopPadY)
    $inc += ("RecentAchievementsTopPadHeight={0}" -f $recentAchievementsTopPadHeight)
    $inc += ("RecentAchievementsTotalHeight={0}" -f $recentAchievementsTotalHeight)
    $inc += ("RecentAchievementsBottomY={0}" -f $recentAchievementsBottomY)
    $inc += ("RecentAchievementsBottomPadY={0}" -f $recentAchievementsBottomPadY)
    $inc += ("RecentAchievementsBottomPadHeight={0}" -f $recentAchievementsBottomPadHeight)
    $inc += ("AchievementGroupCount={0}" -f $achievementGroupPanels.Count)
    for ($i = 0; $i -lt 10; $i++) {
        if ($i -lt $achievementGroupPanels.Count) {
            $groupPanel = $achievementGroupPanels[$i]
            $inc += ("AchievementGroup{0}Y={1}" -f ($i + 1), $groupPanel.Y)
            $inc += ("AchievementGroup{0}Height={1}" -f ($i + 1), $groupPanel.Height)
            $inc += ("AchievementGroup{0}Image={1}" -f ($i + 1), (Clean $groupPanel.Image))
            $inc += ("AchievementGroup{0}URL={1}" -f ($i + 1), (Clean $groupPanel.Url))
            $inc += ("AchievementGroup{0}AppId={1}" -f ($i + 1), (Clean $groupPanel.AppId))
        }
        else {
            $inc += ("AchievementGroup{0}Y=0" -f ($i + 1))
            $inc += ("AchievementGroup{0}Height=0" -f ($i + 1))
            $inc += ("AchievementGroup{0}Image=" -f ($i + 1))
            $inc += ("AchievementGroup{0}URL=" -f ($i + 1))
            $inc += ("AchievementGroup{0}AppId=" -f ($i + 1))
        }
    }
    $inc += ""

    Save-GamesInclude $inc

    $rainmeter = Find-RainmeterExe
    if ($rainmeter -and -not [string]::IsNullOrWhiteSpace($ConfigName)) {
        & $rainmeter "!SetVariable" "CredentialsMissing" 0 $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "CredentialsMissingText" "" $ConfigName | Out-Null
        for ($i = 0; $i -lt $slots.Count; $i++) {
            $slot = $i + 1
            $item = $slots[$i]
            & $rainmeter "!SetVariable" ("Game{0}Name" -f $slot) $item.Name $ConfigName | Out-Null
            & $rainmeter "!SetVariable" ("Game{0}ID" -f $slot) $item.AppId $ConfigName | Out-Null
            & $rainmeter "!SetVariable" ("Game{0}Image" -f $slot) $item.Image $ConfigName | Out-Null
            & $rainmeter "!SetVariable" ("Game{0}LastPlayed" -f $slot) $item.LastPlayedUtc $ConfigName | Out-Null

            $imageMeter = "MeterGame{0}Image" -f $slot
            $fallbackMeter = "MeterGame{0}Fallback" -f $slot
            $fallbackTextMeter = "MeterGame{0}FallbackText" -f $slot
            $leftClickAction = ""
            $rightClickAction = ""

            if (-not [string]::IsNullOrWhiteSpace($item.AppId)) {
                $leftClickAction = ("[""steam://rungameid/{0}""]" -f $item.AppId)
                $rightClickAction = ("[""steam://nav/games/details/{0}""]" -f $item.AppId)
            }

            & $rainmeter "!SetOption" $imageMeter "LeftMouseUpAction" $leftClickAction $ConfigName | Out-Null
            & $rainmeter "!SetOption" $imageMeter "RightMouseUpAction" $rightClickAction $ConfigName | Out-Null
            & $rainmeter "!SetOption" $fallbackMeter "LeftMouseUpAction" $leftClickAction $ConfigName | Out-Null
            & $rainmeter "!SetOption" $fallbackMeter "RightMouseUpAction" $rightClickAction $ConfigName | Out-Null
            & $rainmeter "!SetOption" $fallbackTextMeter "LeftMouseUpAction" $leftClickAction $ConfigName | Out-Null
            & $rainmeter "!SetOption" $fallbackTextMeter "RightMouseUpAction" $rightClickAction $ConfigName | Out-Null

            if ([string]::IsNullOrWhiteSpace($item.AppId)) {
                & $rainmeter "!SetOption" $imageMeter "ImageName" "" $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $imageMeter $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $fallbackMeter $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $fallbackTextMeter $ConfigName | Out-Null
            }
            elseif (-not [string]::IsNullOrWhiteSpace($item.ResolvedImagePath)) {
                & $rainmeter "!SetOption" $imageMeter "ImageName" $item.ResolvedImagePath $ConfigName | Out-Null
                & $rainmeter "!ShowMeter" $imageMeter $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $fallbackMeter $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $fallbackTextMeter $ConfigName | Out-Null
            }
            else {
                & $rainmeter "!SetOption" $imageMeter "ImageName" "" $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $imageMeter $ConfigName | Out-Null
                & $rainmeter "!ShowMeter" $fallbackMeter $ConfigName | Out-Null
                & $rainmeter "!ShowMeter" $fallbackTextMeter $ConfigName | Out-Null
            }
        }
        & $rainmeter "!SetVariable" "DisplayGameCount" $displayGameCount $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentlyPlayedExpirationMinutes" $recentlyPlayedExpirationMinutes $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentEligibleSignature" $recentEligibleSignature $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "IsOffline" $(if ($showOfflineBar) { 1 } else { 0 }) $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "VisibleGamesCount" $visibleGameCount $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "LaunchedGamesCount" $launchedGamesCount $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "OfflineBarText" $offlineBarText $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "OfflineBarY" $offlineBarY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "OfflineBarTextY" $offlineBarTextY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecordBarText" $recordBarText $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecordBarY" $recordBarY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecordBarTextY" $recordBarTextY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "BottomRowY" $bottomRowY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "ProfileURL" $profileUrl $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "ProfileImage" $profileImage $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "BannerImage" $bannerImage $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "BannerWidth" (Format-LayoutNumber $bannerWidth) $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "ProfileWidth" (Format-LayoutNumber $profileWidth) $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "BottomRowHeight" (Format-LayoutNumber $bottomRowHeight) $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "HasRecentAchievements" $(if ($hasRecentAchievements) { 1 } else { 0 }) $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsHeaderImage" $recentAchievementsHeaderImage $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsHeaderY" $recentAchievementsHeaderY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsHeaderHeight" $recentAchievementsHeaderHeight $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsTopPadY" $recentAchievementsTopPadY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsTopPadHeight" $recentAchievementsTopPadHeight $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsTotalHeight" $recentAchievementsTotalHeight $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsBottomY" $recentAchievementsBottomY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsBottomPadY" $recentAchievementsBottomPadY $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "RecentAchievementsBottomPadHeight" $recentAchievementsBottomPadHeight $ConfigName | Out-Null
        & $rainmeter "!SetVariable" "AchievementGroupCount" $achievementGroupPanels.Count $ConfigName | Out-Null
        for ($i = 0; $i -lt 10; $i++) {
            if ($i -lt $achievementGroupPanels.Count) {
                $groupPanel = $achievementGroupPanels[$i]
                & $rainmeter "!SetVariable" ("AchievementGroup{0}Y" -f ($i + 1)) $groupPanel.Y $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}Height" -f ($i + 1)) $groupPanel.Height $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}Image" -f ($i + 1)) $groupPanel.Image $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}URL" -f ($i + 1)) $groupPanel.Url $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}AppId" -f ($i + 1)) $groupPanel.AppId $ConfigName | Out-Null
            }
            else {
                & $rainmeter "!SetVariable" ("AchievementGroup{0}Y" -f ($i + 1)) 0 $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}Height" -f ($i + 1)) 0 $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}Image" -f ($i + 1)) "" $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}URL" -f ($i + 1)) "" $ConfigName | Out-Null
                & $rainmeter "!SetVariable" ("AchievementGroup{0}AppId" -f ($i + 1)) "" $ConfigName | Out-Null
            }
        }
        if ($showRecordBar) {
            & $rainmeter "!ShowMeter" "MeterRecordBar" $ConfigName | Out-Null
            & $rainmeter "!ShowMeter" "MeterRecordBarText" $ConfigName | Out-Null
        }
        else {
            & $rainmeter "!HideMeter" "MeterRecordBar" $ConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterRecordBarText" $ConfigName | Out-Null
        }
        if ($showOfflineBar) {
            & $rainmeter "!ShowMeter" "MeterOfflineBar" $ConfigName | Out-Null
            & $rainmeter "!ShowMeter" "MeterOfflineBarText" $ConfigName | Out-Null
        }
        else {
            & $rainmeter "!HideMeter" "MeterOfflineBar" $ConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterOfflineBarText" $ConfigName | Out-Null
        }
        if ($hasRecentAchievements) {
            if (-not [string]::IsNullOrWhiteSpace($resolvedRecentAchievementsHeaderImagePath) -and $recentAchievementsHeaderHeight -gt 0) {
                & $rainmeter "!SetOption" "MeterRecentAchievementsHeader" "ImageName" $resolvedRecentAchievementsHeaderImagePath $ConfigName | Out-Null
                & $rainmeter "!ShowMeter" "MeterRecentAchievementsHeader" $ConfigName | Out-Null
            }
            else {
                & $rainmeter "!SetOption" "MeterRecentAchievementsHeader" "ImageName" "" $ConfigName | Out-Null
                & $rainmeter "!HideMeter" "MeterRecentAchievementsHeader" $ConfigName | Out-Null
            }
            if ($recentAchievementsTopPadHeight -gt 0) {
                & $rainmeter "!ShowMeter" "MeterRecentAchievementsTopPad" $ConfigName | Out-Null
            }
            else {
                & $rainmeter "!HideMeter" "MeterRecentAchievementsTopPad" $ConfigName | Out-Null
            }
            if ($recentAchievementsBottomPadHeight -gt 0) {
                & $rainmeter "!ShowMeter" "MeterRecentAchievementsBottomPad" $ConfigName | Out-Null
            }
            else {
                & $rainmeter "!HideMeter" "MeterRecentAchievementsBottomPad" $ConfigName | Out-Null
            }
        }
        else {
            & $rainmeter "!SetOption" "MeterRecentAchievementsHeader" "ImageName" "" $ConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterRecentAchievementsHeader" $ConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterRecentAchievementsTopPad" $ConfigName | Out-Null
            & $rainmeter "!HideMeter" "MeterRecentAchievementsBottomPad" $ConfigName | Out-Null
        }
        for ($i = 1; $i -le 10; $i++) {
            $groupMeter = "MeterAchievementGroup{0}" -f $i
            if ($i -le $achievementGroupPanels.Count) {
                $groupPanel = $achievementGroupPanels[$i - 1]
                if (-not [string]::IsNullOrWhiteSpace($groupPanel.ResolvedImagePath)) {
                    & $rainmeter "!SetOption" $groupMeter "ImageName" $groupPanel.ResolvedImagePath $ConfigName | Out-Null
                }
                & $rainmeter "!ShowMeter" $groupMeter $ConfigName | Out-Null
            }
            else {
                & $rainmeter "!SetOption" $groupMeter "ImageName" "" $ConfigName | Out-Null
                & $rainmeter "!HideMeter" $groupMeter $ConfigName | Out-Null
            }
        }
        if ($showTopGameInGameIcon) {
            & $rainmeter "!ShowMeter" "MeterGame1InGameIcon" $ConfigName | Out-Null
        }
        else {
            & $rainmeter "!HideMeter" "MeterGame1InGameIcon" $ConfigName | Out-Null
        }
        & $rainmeter "!HideMeter" "MeterCredentialsMissingBox" $ConfigName | Out-Null
        & $rainmeter "!HideMeter" "MeterCredentialsMissingText" $ConfigName | Out-Null
        & $rainmeter "!ShowMeter" "MeterSteam" $ConfigName | Out-Null
        & $rainmeter "!ShowMeter" "MeterProfile" $ConfigName | Out-Null
        & $rainmeter "!ShowMeter" "MeterRecentAchievementsBounds" $ConfigName | Out-Null
        if (-not [string]::IsNullOrWhiteSpace($resolvedProfileImagePath)) {
            & $rainmeter "!SetOption" "MeterProfile" "ImageName" $resolvedProfileImagePath $ConfigName | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($resolvedBannerImagePath)) {
            & $rainmeter "!SetOption" "MeterSteam" "ImageName" $resolvedBannerImagePath $ConfigName | Out-Null
        }
        & $rainmeter "!UpdateMeter" "*" $ConfigName | Out-Null
        & $rainmeter "!Update" $ConfigName | Out-Null
        & $rainmeter "!Redraw" $ConfigName | Out-Null
    }

    Log ("Display rebuilt with {0} visible of {1} tracked games (limit {2}, expiration {3})." -f $visibleGameCount, $launchedGamesCount, $displayGameCount, (Get-ExpirationDisplayLabel $recentlyPlayedExpirationMinutes))
}
catch {
    Log ("BuildDisplay ERROR: {0}" -f $_.Exception.Message)
    if ($NoExit) {
        throw
    }
    exit 1
}
finally {
    Hide-RebuildOverlay $ConfigName
}
