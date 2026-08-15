param(
    [string]$ConfigName = "",
    [switch]$RunStartupUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$CachePath = Join-Path $Root "Cache"
$DataCachePath = Join-Path $CachePath "Data"
$SteamAccountSettingsPath = Join-Path $Root "SteamAccountInfo.inc"
$OutputPath = Join-Path $DataCachePath "playtime_2weeks.json"
$ConnectionStatePath = Join-Path $DataCachePath "ConnectionState.json"
$LogPath = Join-Path $CachePath "Update.log"
$UpdateScriptPath = Join-Path $Root "UpdatePlayedGames.ps1"
$UpdateRecentAchievementsScriptPath = Join-Path $Root "UpdateRecentAchievements.ps1"
$BuildDisplayScriptPath = Join-Path $Root "BuildDisplay.ps1"

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

function Assert-Configured([string]$ApiKey, [string]$SteamId) {
    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey -eq "YOUR_STEAM_WEB_API_KEY") {
        throw "SteamAPIKey is not configured in SteamAccountInfo.inc."
    }
    if ([string]::IsNullOrWhiteSpace($SteamId) -or $SteamId -eq "YOUR_STEAMID64") {
        throw "SteamID64 is not configured in SteamAccountInfo.inc."
    }
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

    Ensure-ParentDirectory $OutputPath
    $json = if ($snapshot.Count -eq 0) { "[]" } else { ConvertTo-Json $snapshot -Depth 3 }
    $tmp = "$OutputPath.new"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    $null = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
    Move-Item -LiteralPath $tmp -Destination $OutputPath -Force

    return $snapshot.Count
}

try {
    New-Item -ItemType Directory -Path $CachePath -Force | Out-Null
    New-Item -ItemType Directory -Path $DataCachePath -Force | Out-Null
    $apiKey = Read-IniValue $SteamAccountSettingsPath "SteamAPIKey"
    $steamId = Read-IniValue $SteamAccountSettingsPath "SteamID64"
    if (-not (Test-SteamCredentialsConfigured $apiKey $steamId)) {
        if (-not (Test-Path -LiteralPath $BuildDisplayScriptPath)) {
            throw "Missing BuildDisplay.ps1."
        }

        & $BuildDisplayScriptPath -ConfigName $ConfigName
        Log "InitializePlaytime skipped Steam refresh because credentials are not configured."
        exit 0
    }
    Assert-Configured $apiKey $steamId
    $shouldBuildDisplay = $false
    $connectionState = $null

    try {
        $snapshotCount = Save-RecentlyPlayedSnapshot $apiKey $steamId
        $connectionState = Set-ConnectionState $false "" "InitializePlaytime"
        $shouldBuildDisplay = $connectionState.Changed
        Log ("playtime_2weeks.json saved with {0} entries." -f $snapshotCount)
    }
    catch {
        if (-not (Test-ShouldUseOfflineFallback $_)) {
            throw
        }

        $connectionState = Set-ConnectionState $true $_.Exception.Message "InitializePlaytime"
        $shouldBuildDisplay = $true
        Log ("InitializePlaytime switched to cached offline mode: {0}" -f $_.Exception.Message)
    }

    if ($RunStartupUpdate -and -not $connectionState.IsOffline) {
        if (-not (Test-Path -LiteralPath $UpdateScriptPath)) {
            throw "Missing UpdatePlayedGames.ps1."
        }
        if (-not (Test-Path -LiteralPath $BuildDisplayScriptPath)) {
            throw "Missing BuildDisplay.ps1."
        }

        & $UpdateScriptPath -ConfigName $ConfigName -RebuildDisplay Never

        if (Test-Path -LiteralPath $UpdateRecentAchievementsScriptPath) {
            & $UpdateRecentAchievementsScriptPath -ConfigName $ConfigName -RebuildDisplay Never
        }

        & $BuildDisplayScriptPath -ConfigName $ConfigName
    }
    elseif ($shouldBuildDisplay) {
        if (-not (Test-Path -LiteralPath $BuildDisplayScriptPath)) {
            throw "Missing BuildDisplay.ps1."
        }
        & $BuildDisplayScriptPath -ConfigName $ConfigName
    }
}
catch {
    Log ("InitializePlaytime ERROR: {0}" -f $_.Exception.Message)
    exit 1
}
