param(
    [string]$ConfigName = "",
    [string]$ParentConfigName = "",
    [string]$RootConfig = "",
    [string]$DisplayGameCount = "",
    [string]$RecentlyPlayedExpirationInputValue = "",
    [string]$RecentlyPlayedExpirationUnit = "",
    [string]$RecentAchievementDisplayCount = "",
    [string]$RecentAchievementExpirationInputValue = "",
    [string]$RecentAchievementExpirationUnit = "",
    [string]$ShowAchievementRarity = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CachePath = Join-Path $Root "Cache"
$DataCachePath = Join-Path $CachePath "Data"
$DraftPath = Join-Path $DataCachePath "SettingsDraft.inc"
$AdvancedSettingsPath = Join-Path $Root "AdvancedSettings.inc"
$BuildDisplayScriptPath = Join-Path $Root "BuildDisplay.ps1"
$PrepareSettingsDraftScriptPath = Join-Path $Root "PrepareSettingsDraft.ps1"
$UpdateRecentAchievementsScriptPath = Join-Path $Root "UpdateRecentAchievements.ps1"
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

function Find-RainmeterExe {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "Rainmeter\Rainmeter.exe") }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} "Rainmeter\Rainmeter.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Rainmeter\Rainmeter.exe") }
    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Read-IniValue([string]$Path, [string]$Name) {
    $pattern = "^\s*" + [regex]::Escape($Name) + "\s*=\s*(.*?)\s*$"
    $match = Get-Content -LiteralPath $Path | Select-String -Pattern $pattern | Select-Object -First 1
    if (-not $match) { throw "Missing $Name in $Path" }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function Set-IniValue([string]$Path, [string]$Name, [string]$Value) {
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            $lines.Add([string]$line)
        }
    }

    $sectionPattern = '^\s*\[(.+?)\]\s*$'
    $valuePattern = "^\s*" + [regex]::Escape($Name) + "\s*="
    $variablesIndex = -1
    $insertIndex = -1
    $updated = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        if ($line -match '^\s*\[Variables\]\s*$') {
            $variablesIndex = $i
            $insertIndex = $i + 1
            continue
        }

        if ($variablesIndex -ge 0) {
            if ($line -match $valuePattern) {
                $lines[$i] = "{0}={1}" -f $Name, $Value
                $updated = $true
                break
            }

            if ($line -match $sectionPattern) {
                $insertIndex = $i
                break
            }

            $insertIndex = $i + 1
        }
    }

    if (-not $updated) {
        if ($variablesIndex -lt 0) {
            if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
                $lines.Add("")
            }
            $lines.Add("[Variables]")
            $lines.Add("{0}={1}" -f $Name, $Value)
        }
        else {
            if ($insertIndex -lt 0) {
                $insertIndex = $lines.Count
            }
            $lines.Insert($insertIndex, ("{0}={1}" -f $Name, $Value))
        }
    }

    Ensure-ParentDirectory $Path
    $tmp = Get-TemporaryWritePath $Path
    [IO.File]::WriteAllLines($tmp, @($lines), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-DraftInt([string]$Name, [int]$DefaultValue) {
    try { return [int](Read-IniValue $DraftPath $Name) } catch { return $DefaultValue }
}

function Get-DraftString([string]$Name, [string]$DefaultValue = "") {
    try { return (Read-IniValue $DraftPath $Name) } catch { return $DefaultValue }
}

function Get-ProvidedInt([string]$RawValue, [string]$DraftName, [int]$DefaultValue) {
    if (-not [string]::IsNullOrWhiteSpace($RawValue)) {
        $parsedValue = 0
        if ([int]::TryParse($RawValue.Trim(), [ref]$parsedValue)) {
            return $parsedValue
        }
    }

    return (Get-DraftInt $DraftName $DefaultValue)
}

function Get-ProvidedString([string]$RawValue, [string]$DraftName, [string]$DefaultValue = "") {
    if (-not [string]::IsNullOrWhiteSpace($RawValue)) {
        return $RawValue.Trim()
    }

    return (Get-DraftString $DraftName $DefaultValue)
}

function Clamp-Int([int]$Value, [int]$Minimum, [int]$Maximum) {
    return [Math]::Max($Minimum, [Math]::Min($Maximum, $Value))
}

function Resolve-UnitInputMinutes([int]$InputValue, [string]$Unit) {
    $safeInput = Clamp-Int $InputValue 0 999

    switch ($Unit) {
        "Hours" { return ($safeInput * 60) }
        "Days" { return ($safeInput * 1440) }
        default { return $safeInput }
    }
}

try {
    $displayGameCount = Clamp-Int (Get-ProvidedInt $DisplayGameCount "DraftDisplayGameCount" 10) 0 10
    $recentlyPlayedExpirationInputValue = Clamp-Int (Get-ProvidedInt $RecentlyPlayedExpirationInputValue "DraftRecentlyPlayedExpirationInputValue" (Get-DraftInt "DraftRecentlyPlayedExpirationMinutes" 20160)) 0 999
    $recentlyPlayedExpirationUnit = Get-ProvidedString $RecentlyPlayedExpirationUnit "DraftRecentlyPlayedExpirationUnit" "Minutes"
    $recentlyPlayedExpirationMinutes = Clamp-Int (Resolve-UnitInputMinutes $recentlyPlayedExpirationInputValue $recentlyPlayedExpirationUnit) 0 1438560
    $recentAchievementDisplayCount = Clamp-Int (Get-ProvidedInt $RecentAchievementDisplayCount "DraftRecentAchievementDisplayCount" 10) 0 10
    $recentAchievementExpirationInputValue = Clamp-Int (Get-ProvidedInt $RecentAchievementExpirationInputValue "DraftRecentAchievementExpirationInputValue" (Get-DraftInt "DraftRecentAchievementExpirationMinutes" 10080)) 0 999
    $recentAchievementExpirationUnit = Get-ProvidedString $RecentAchievementExpirationUnit "DraftRecentAchievementExpirationUnit" "Minutes"
    $recentAchievementExpirationMinutes = Clamp-Int (Resolve-UnitInputMinutes $recentAchievementExpirationInputValue $recentAchievementExpirationUnit) 0 1438560
    $showAchievementRarity = Clamp-Int (Get-ProvidedInt $ShowAchievementRarity "DraftShowAchievementRarity" 1) 0 1
    $parentConfigName = Get-ProvidedString $ParentConfigName "DraftParentConfigName"
    $rootConfig = Get-ProvidedString $RootConfig "DraftRootConfig" $parentConfigName

    Set-IniValue $AdvancedSettingsPath "DisplayGameCount" ([string]$displayGameCount)
    Set-IniValue $AdvancedSettingsPath "RecentlyPlayedExpirationMinutes" ([string]$recentlyPlayedExpirationMinutes)
    Set-IniValue $AdvancedSettingsPath "RecentAchievementDisplayCount" ([string]$recentAchievementDisplayCount)
    Set-IniValue $AdvancedSettingsPath "RecentAchievementExpirationMinutes" ([string]$recentAchievementExpirationMinutes)
    Set-IniValue $AdvancedSettingsPath "ShowAchievementRarity" ([string]$showAchievementRarity)
    Log ("Settings draft saved to AdvancedSettings.inc.")

    if (-not (Test-Path -LiteralPath $PrepareSettingsDraftScriptPath)) {
        throw "Missing PrepareSettingsDraft.ps1."
    }
    if (-not (Test-Path -LiteralPath $UpdateRecentAchievementsScriptPath)) {
        throw "Missing UpdateRecentAchievements.ps1."
    }
    if (-not (Test-Path -LiteralPath $BuildDisplayScriptPath)) {
        throw "Missing BuildDisplay.ps1."
    }

    & $PrepareSettingsDraftScriptPath -ParentConfigName $parentConfigName -RootConfig $rootConfig
    Log ("Settings draft regenerated from AdvancedSettings.inc.")

    & $UpdateRecentAchievementsScriptPath -ConfigName $parentConfigName -RebuildDisplay Never
    & $BuildDisplayScriptPath -ConfigName $parentConfigName

    $rainmeter = Find-RainmeterExe
    if ($rainmeter) {
        if (-not [string]::IsNullOrWhiteSpace($parentConfigName)) {
            & $rainmeter "!Refresh" $parentConfigName | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($ConfigName)) {
            & $rainmeter "!Refresh" $ConfigName | Out-Null
        }
    }
}
catch {
    Log ("SaveSettingsDraft ERROR: {0}" -f $_.Exception.Message)
    exit 1
}
