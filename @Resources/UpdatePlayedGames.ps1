param(
    [string]$ConfigName = "",
    [ValidateSet("Never", "OnChange", "Always")]
    [string]$RebuildDisplay = "Never"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CachePath = Join-Path $Root "Cache"
$DataCachePath = Join-Path $CachePath "Data"
$SteamAccountSettingsPath = Join-Path $Root "SteamAccountInfo.inc"
$AdvancedSettingsPath = Join-Path $Root "AdvancedSettings.inc"
$PlayedPath = Join-Path $DataCachePath "PlayedGames.json"
$PlaytimePath = Join-Path $DataCachePath "playtime_2weeks.json"
$GamesPath = Join-Path $DataCachePath "Games.inc"
$ConnectionStatePath = Join-Path $DataCachePath "ConnectionState.json"
$LockPath = Join-Path $DataCachePath "PlayedGames.lock"
$LogPath = Join-Path $CachePath "Update.log"
$BuildDisplayScriptPath = Join-Path $Root "BuildDisplay.ps1"
$LockStream = $null

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

function Get-PropertyString([AllowNull()][object]$InputObject, [string]$Name) {
    if ($null -eq $InputObject) { return "" }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return "" }
    if ($null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Normalize-LastPlayedUtc([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    try {
        $parsed = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        return $parsed.UtcDateTime.ToString("o")
    }
    catch {
        return ""
    }
}

function Get-LastPlayedSortTicks([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return [long]::MinValue }
    try {
        return ([DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)).UtcTicks
    }
    catch {
        return [long]::MinValue
    }
}

function Normalize-PlayedGames([object[]]$Items) {
    $result = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($item in @($Items)) {
        $appId = (Get-PropertyString $item "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId)) { continue }
        if ($seen.ContainsKey($appId)) { continue }
        $seen[$appId] = $true

        $name = (Get-PropertyString $item "Name").Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "Steam App $appId"
        }

        $lastPlayedUtc = Normalize-LastPlayedUtc (Get-PropertyString $item "LastPlayedUtc")
        $source = (Get-PropertyString $item "Source").Trim()

        $result.Add([pscustomobject][ordered]@{
            AppId = $appId
            Name = $name
            LastPlayedUtc = $lastPlayedUtc
            Source = $source
        })
    }

    $normalized = @(
        $result |
        Sort-Object @{ Expression = { Get-LastPlayedSortTicks ([string]$_.LastPlayedUtc) }; Descending = $true }, @{ Expression = { [string]$_.Name }; Descending = $false } |
        Select-Object -First 10
    )

    return @($normalized)
}

function Convert-PlayedGamesToJson([object[]]$Items) {
    $array = @(Normalize-PlayedGames $Items)

    if ($array.Count -eq 0) {
        return "[]"
    }
    elseif ($array.Count -eq 1) {
        return "[" + [Environment]::NewLine + (ConvertTo-Json $array[0] -Depth 3) + [Environment]::NewLine + "]"
    }
    else {
        return (ConvertTo-Json $array -Depth 3)
    }
}

function Assert-Configured([string]$ApiKey, [string]$SteamId) {
    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey -eq "YOUR_STEAM_WEB_API_KEY") {
        throw "SteamAPIKey is not configured in SteamAccountInfo.inc."
    }
    if ([string]::IsNullOrWhiteSpace($SteamId) -or $SteamId -eq "YOUR_STEAMID64") {
        throw "SteamID64 is not configured in SteamAccountInfo.inc."
    }
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
        Log ("ConnectionState.json was invalid and has been reset: {0}" -f $_.Exception.Message)
        return Get-DefaultConnectionState
    }
}

function Set-ConnectionState([bool]$IsOffline, [string]$LastError, [string]$Source) {
    $current = Load-ConnectionState
    $stateChanged = ([bool]$current.IsOffline -ne $IsOffline)
    $timestamp = [DateTime]::UtcNow.ToString("o")
    $lastChangedUtc = if ($stateChanged -or [string]::IsNullOrWhiteSpace([string]$current.LastChangedUtc)) { $timestamp } else { [string]$current.LastChangedUtc }

    $next = [pscustomobject][ordered]@{
        IsOffline = $IsOffline
        LastCheckedUtc = $timestamp
        LastChangedUtc = $lastChangedUtc
        LastError = if ($IsOffline) { [string]$LastError } else { "" }
        LastSource = [string]$Source
    }

    Ensure-ParentDirectory $ConnectionStatePath
    $tmp = "$ConnectionStatePath.new"
    [IO.File]::WriteAllText($tmp, ($next | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $ConnectionStatePath -Force

    return [pscustomobject]@{
        Changed = $stateChanged
        IsOffline = $IsOffline
        PreviousIsOffline = [bool]$current.IsOffline
    }
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

function Test-ShouldUseOfflineFallback([System.Management.Automation.ErrorRecord]$ErrorRecord) {
    return ((Get-WebStatusCode $ErrorRecord) -eq 0)
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

function Get-RecentEligibleSignature([object[]]$Items, [int]$ExpirationMinutes) {
    $appIds = New-Object System.Collections.Generic.List[string]

    foreach ($item in @($Items)) {
        $appId = (Get-PropertyString $item "AppId").Trim()
        if ([string]::IsNullOrWhiteSpace($appId)) { continue }
        if (-not (Test-IsRecentlyPlayedWithinWindow (Get-PropertyString $item "LastPlayedUtc") $ExpirationMinutes)) { continue }
        $appIds.Add($appId)
    }

    return [string]::Join("|", @($appIds))
}

function Get-RenderedRecentEligibleSignature {
    if (-not (Test-Path -LiteralPath $GamesPath)) { return "__missing__" }

    try {
        return Read-IniValue $GamesPath "RecentEligibleSignature"
    }
    catch {
        return "__missing__"
    }
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
    throw "Timed out waiting for PlayedGames lock."
}

function Release-Lock {
    if ($null -ne $script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
    }
}

function Load-PlayedGames {
    if (-not (Test-Path -LiteralPath $PlayedPath)) { return @() }
    $raw = [IO.File]::ReadAllText($PlayedPath)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    try {
        $data = $raw | ConvertFrom-Json
    }
    catch {
        Log ("PlayedGames.json was invalid and has been reset: {0}" -f $_.Exception.Message)
        Save-PlayedGames @()
        return @()
    }

    $normalized = @(Normalize-PlayedGames @($data))
    $canonicalJson = Convert-PlayedGamesToJson $normalized

    if ($raw.Trim() -ne $canonicalJson.Trim()) {
        [IO.File]::WriteAllText($PlayedPath, $canonicalJson, (New-Object Text.UTF8Encoding($false)))
        Log ("PlayedGames.json normalized on load; count={0}" -f $normalized.Count)
    }

    return @($normalized)
}

function Save-PlayedGames([object[]]$Items) {
    Ensure-ParentDirectory $PlayedPath
    $json = Convert-PlayedGamesToJson $Items
    $tmp = "$PlayedPath.new"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    $null = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    Move-Item -LiteralPath $tmp -Destination $PlayedPath -Force
}

function Save-RecentlyPlayedSnapshot([string]$ApiKey, [string]$SteamId) {
    $url = "https://api.steampowered.com/IPlayerService/GetRecentlyPlayedGames/v0001/?key=$ApiKey&steamid=$SteamId&format=json&count=50"
    $response = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "Mozilla/5.0 Mini-Steam-Launcher" }

    $snapshot = @(
        @($response.response.games) |
        ForEach-Object {
            [pscustomobject][ordered]@{
                AppId = [string]$_.appid
                Name = [string]$_.name
                playtime_2weeks = if ($null -ne $_.PSObject.Properties["playtime_2weeks"]) { [int]$_.playtime_2weeks } else { 0 }
            }
        } |
        Sort-Object @{Expression = { [int]$_.playtime_2weeks }; Descending = $true }, @{Expression = { [string]$_.Name }; Descending = $false}
    )

    Ensure-ParentDirectory $PlaytimePath
    $json = if ($snapshot.Count -eq 0) { "[]" } else { ConvertTo-Json $snapshot -Depth 3 }
    $tmp = "$PlaytimePath.new"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    $null = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    Move-Item -LiteralPath $tmp -Destination $PlaytimePath -Force

    return $snapshot.Count
}

function Invoke-DisplayBuild {
    if (-not (Test-Path -LiteralPath $BuildDisplayScriptPath)) {
        throw "Missing BuildDisplay.ps1."
    }
    & $BuildDisplayScriptPath -ConfigName $ConfigName
}

function Find-RainmeterExe {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles "Rainmeter\Rainmeter.exe") }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} "Rainmeter\Rainmeter.exe") }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "Rainmeter\Rainmeter.exe") }
    return $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

function Clear-TopGameInGameOverlay([string]$TargetConfigName) {
    if ([string]::IsNullOrWhiteSpace($TargetConfigName)) { return }

    $rainmeter = Find-RainmeterExe
    if (-not $rainmeter) { return }

    & $rainmeter "!HideMeter" "MeterGame1InGameIcon" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "MeterGame1Image" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "MeterGame1Fallback" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "MeterGame1FallbackText" $TargetConfigName | Out-Null
    & $rainmeter "!UpdateMeter" "MeterGame1InGameIcon" $TargetConfigName | Out-Null
    & $rainmeter "!Redraw" $TargetConfigName | Out-Null
}

function Test-RecentEligibilityChanged([object[]]$Played, [int]$ExpirationMinutes) {
    $currentSignature = Get-RecentEligibleSignature $Played $ExpirationMinutes
    $renderedSignature = Get-RenderedRecentEligibleSignature
    return [pscustomobject]@{
        Changed = ($currentSignature -ne $renderedSignature)
        CurrentSignature = $currentSignature
        RenderedSignature = $renderedSignature
    }
}

$shouldBuildDisplay = $false
$shouldClearTopGameInGameOverlay = $false

try {
    New-Item -ItemType Directory -Path $CachePath -Force | Out-Null
    New-Item -ItemType Directory -Path $DataCachePath -Force | Out-Null
    Acquire-Lock

    $apiKey = Read-IniValue $SteamAccountSettingsPath "SteamAPIKey"
    $steamId = Read-IniValue $SteamAccountSettingsPath "SteamID64"
    $recentlyPlayedExpirationMinutes = Get-ConfiguredRecentlyPlayedExpirationMinutes $AdvancedSettingsPath
    if (-not (Test-SteamCredentialsConfigured $apiKey $steamId)) {
        exit 0
    }
    Assert-Configured $apiKey $steamId

    $url = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=$apiKey&steamids=$steamId&format=json"
    $played = @(Load-PlayedGames)
    $profile = $null
    $connectionState = $null
    $connectionRecovered = $false

    try {
        $response = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "Mozilla/5.0 Mini-Steam-Launcher" }
        $profile = @($response.response.players) | Select-Object -First 1
        if (-not $profile) { throw "Steam returned no profile data." }

        $connectionState = Set-ConnectionState $false "" "UpdatePlayedGames"
        $connectionRecovered = ($connectionState.Changed -and -not $connectionState.IsOffline)

        if ($connectionRecovered) {
            try {
                $snapshotCount = Save-RecentlyPlayedSnapshot $apiKey $steamId
                Log ("Connection restored; playtime_2weeks.json refreshed with {0} entries." -f $snapshotCount)
            }
            catch {
                Log ("Connection restored but playtime_2weeks.json refresh failed; keeping cached snapshot: {0}" -f $_.Exception.Message)
            }
        }
    }
    catch {
        if (-not (Test-ShouldUseOfflineFallback $_)) {
            throw
        }

        $connectionState = Set-ConnectionState $true $_.Exception.Message "UpdatePlayedGames"
        Log ("Steam polling offline; using cached data: {0}" -f $_.Exception.Message)

        $recentEligibilityState = Test-RecentEligibilityChanged $played $recentlyPlayedExpirationMinutes
        if ($recentEligibilityState.Changed) {
            Log ("Refreshing cached display because the recent-played window changed while offline. Current={0} Rendered={1}" -f $recentEligibilityState.CurrentSignature, $recentEligibilityState.RenderedSignature)
        }

        $shouldBuildDisplay = (
            ($RebuildDisplay -eq "Always") -or
            (
                $RebuildDisplay -ne "Never" -and
                ($connectionState.Changed -or $recentEligibilityState.Changed)
            )
        )
    }

    if ($null -ne $profile) {
        $gameId = if ($null -ne $profile.PSObject.Properties["gameid"]) { [string]$profile.gameid } else { "" }
        $gameName = if ($null -ne $profile.PSObject.Properties["gameextrainfo"]) { [string]$profile.gameextrainfo } else { "" }

        if ([string]::IsNullOrWhiteSpace($gameId)) {
            Log "No active game reported."
            $recentEligibilityState = Test-RecentEligibilityChanged $played $recentlyPlayedExpirationMinutes
            if ($recentEligibilityState.Changed) {
                Log ("Recently played expiration changed the active window; display refresh needed. Current={0} Rendered={1}" -f $recentEligibilityState.CurrentSignature, $recentEligibilityState.RenderedSignature)
                $shouldBuildDisplay = $RebuildDisplay -ne "Never"
            }
            else {
                $shouldBuildDisplay = $RebuildDisplay -eq "Always"
                if (-not $shouldBuildDisplay) {
                    $shouldClearTopGameInGameOverlay = $true
                }
            }
        }
        else {
            $topId = if ($played.Count -gt 0) { [string]$played[0].AppId } else { "" }

            if ($gameId -eq $topId) {
                $topEntry = @($played | Where-Object { [string]$_.AppId -eq $gameId } | Select-Object -First 1)
                $remaining = @(
                    $played | Where-Object { [string]$_.AppId -ne $gameId }
                )

                $resolvedName = ""
                if (-not [string]::IsNullOrWhiteSpace($gameName)) {
                    $resolvedName = $gameName
                }
                elseif ($topEntry.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$topEntry[0].Name)) {
                    $resolvedName = [string]$topEntry[0].Name
                }
                else {
                    $resolvedName = "Steam App $gameId"
                }

                $refreshedEntry = [pscustomobject][ordered]@{
                    AppId = $gameId
                    Name = $resolvedName
                    LastPlayedUtc = [DateTime]::UtcNow.ToString("o")
                    Source = "ActiveGame"
                }

                $updated = @($refreshedEntry) + @($remaining)
                Save-PlayedGames $updated
                Log ("Active game already at top; refreshed LastPlayedUtc: {0} ({1})" -f $refreshedEntry.Name, $gameId)

                $recentEligibilityState = Test-RecentEligibilityChanged $updated $recentlyPlayedExpirationMinutes
                if ($recentEligibilityState.Changed) {
                    Log ("Refreshing display because active top game timestamp changed the recent-played window. Current={0} Rendered={1}" -f $recentEligibilityState.CurrentSignature, $recentEligibilityState.RenderedSignature)
                    $shouldBuildDisplay = $RebuildDisplay -ne "Never"
                }
                else {
                    $shouldBuildDisplay = $RebuildDisplay -eq "Always"
                }
            }
            else {
                $existingEntry = @($played | Where-Object { [string]$_.AppId -eq $gameId } | Select-Object -First 1)
                $remaining = @(
                    $played | Where-Object { [string]$_.AppId -ne $gameId }
                )

                $resolvedName = ""
                if (-not [string]::IsNullOrWhiteSpace($gameName)) {
                    $resolvedName = $gameName
                }
                elseif ($existingEntry.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$existingEntry[0].Name)) {
                    $resolvedName = [string]$existingEntry[0].Name
                }
                else {
                    $resolvedName = "Steam App $gameId"
                }

                $newEntry = [pscustomobject][ordered]@{
                    AppId = $gameId
                    Name = $resolvedName
                    LastPlayedUtc = [DateTime]::UtcNow.ToString("o")
                    Source = "ActiveGame"
                }

                $updated = @($newEntry) + @($remaining)
                Save-PlayedGames $updated
                Log ("Moved active game to top: {0} ({1})" -f $newEntry.Name, $gameId)
                Log ("Active game entry written: {0}" -f (ConvertTo-Json $newEntry -Compress -Depth 3))
                $shouldBuildDisplay = $RebuildDisplay -ne "Never"
            }
        }
    }

    if ($connectionRecovered -and $RebuildDisplay -ne "Never") {
        $shouldBuildDisplay = $true
    }
}
catch {
    Log ("UpdatePlayedGames ERROR: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    Release-Lock
}

if ($shouldBuildDisplay) {
    try {
        Invoke-DisplayBuild
    }
    catch {
        Log ("UpdatePlayedGames build trigger ERROR: {0}" -f $_.Exception.Message)
        exit 1
    }
}
elseif ($shouldClearTopGameInGameOverlay) {
    try {
        Clear-TopGameInGameOverlay $ConfigName
    }
    catch {
        Log ("UpdatePlayedGames in-game overlay clear ERROR: {0}" -f $_.Exception.Message)
        exit 1
    }
}
