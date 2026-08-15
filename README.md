# Advanced Mini-Steam Launcher

Advanced Mini-Steam Launcher is a Windows Rainmeter skin that turns Steam activity into a compact desktop launcher. It shows recent games, recent achievements, and quick links to relevant Steam pages. Game and achievement counts are configurable, and the widget resizes automatically to match.

## Screenshots
<table>
  <tr>
    <td style="text-align: center;">
      <strong>Mini-Steam Launcher</strong><br>
      <strong>3 Game &amp; 3 Achievements</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Settings window</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Mini-Steam Launcher</strong><br>
      <strong>1 Game &amp; 3 Achievements</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Mini-Steam Launcher</strong><br>
      <strong>10 games &amp; 10 achievements</strong><br>
    </td>
  </tr>
  <tr>
    <td style="text-align: center; vertical-align: bottom; width: 25%; height: 455px;">
      <img src=".git-files/3x3.png" alt="Main launcher 3 game and 3 achievements" style="max-width: 140px; max-height: 455px; width: auto; height: auto; display: block; margin: 0 auto;">
    </td>
    <td style="text-align: center; vertical-align: bottom; width: 25%; height: 455px;">
      <img src=".git-files/Settings.png" alt="Settings window" style="max-width: 140px; max-height: 455px; width: auto; height: auto; display: block; margin: 0 auto;">
    </td>
    <td style="text-align: center; vertical-align: bottom; width: 25%; height: 455px;">
      <img src=".git-files/1x3.png" alt="1 game and 3 achievements" style="max-width: 140px; max-height: 455px; width: auto; height: auto; display: block; margin: 0 auto;">
    </td>
    <td style="text-align: center; vertical-align: bottom; width: 25%; height: 455px;">
      <img src=".git-files/10x10.png" alt="10 games and 10 achievements" style="max-width: 140px; max-height: 455px; width: auto; height: auto; display: block; margin: 0 auto;">
    </td>
  </tr>
</table>

## Features

- Tracks the currently active Steam game and pins it to the top of the list
- Fills remaining slots from recently played games
- Displays up to 10 game banners with text fallbacks if artwork is missing
- Shows an in-game badge on the top listed game
- Polls active game status every 15 seconds
- Polls recent achievements every 60 seconds
- Shows recent achievements with cached icons and optional rarity overlays
- Supports offline fallback by reusing previously cached data and images
- Opens games, game details, Steam library, friends, profile pages, and achievement pages directly from the skin
- Includes a settings sub-skin for game count, expiration windows, achievement count, and achievement rarity

## Requirements

- Windows
- Rainmeter
- Steam desktop client
- A Steam Web API key
- A SteamID64
- PowerShell
- Internet connection

Steam privacy and status requirements:

- `My Profile` must be `Public` for achievement tracking
- `Game Details` must be `Public` for achievement tracking
- Steam status should be `Online` for active game detection

## Basic setup

1. Install Rainmeter if it is not already installed.
2. Copy the `Advanced Mini-Steam Launcher` folder into `Documents\Rainmeter\Skins\`.
3. Refresh Rainmeter, then load `Advanced Mini-Steam-Launcher.ini`.
4. Click the missing credentials message to open `@Resources\SteamAccountInfo.inc`.
5. Fill in:
   - `SteamAPIKey`
   - `SteamID64`
6. Refresh Rainmeter again.
7. Optional: adjust Settings and `@Resources\AdvancedSettings.inc`.

If credentials are missing, the launcher shows a black setup tile that links directly to `SteamAccountInfo.inc`.

## Usage

Common actions:

- Left-click a game banner: launch that game in Steam
- Right-click a game banner: open that game's Steam details page
- Left-click the bottom Steam banner: open the Steam games/library area
- Left-click the profile image: open Steam friends
- Right-click the profile image: open the Steam community profile
- Left-click an achievement panel: open that game's achievement page in Steam
- Use the gear on the bottom banner or the Rainmeter context menu to open Settings
- Use `Rebuild` from the Rainmeter context menu to force a manual refresh

## Known issues / limitations

- First load after clearing `@Resources\Cache` can take longer because the launcher must rebuild data files, banners, and achievement assets
- Achievement visibility depends on Steam API availability and Steam privacy settings
- Active game tracking depends on Steam reporting an online in-game state

## Project status

Work in progress / prototype.

## License

Creative Commons Attribution-NonCommercial-ShareAlike 3.0.

## Credits / acknowledgments

- Project authors: IZY2091
- Based on Venelder Mini-Steam Launcher
