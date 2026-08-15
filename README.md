# Advanced Mini-Steam Launcher

Advanced Mini-Steam Launcher is a Windows Rainmeter skin that turns Steam activity into a compact desktop game launcher.
It also has a recent Steam Achievement tracking and various shortcuts to relevant steam pages.
The number of tracked games and achievements can be set in settings and the application will adaptively resize to reflect this amount.

## Screenshots
<table>
  <tr>
    <td style="text-align: center;">
      <strong>Main launcher view</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Settings window</strong><br>
    </td>
  </tr>
  <tr>
    <td style="text-align: center;">
      <img src=".git-files/img.png" alt="Main launcher view" style="width: 140px; height: auto;">
    </td>
    <td style="text-align: center;">
      <img src=".git-files/img_1.png" alt="Settings window" style="width: 140px; height: auto;">
    </td>
  </tr>
</table>

## Features

- Tracks the currently active Steam game and pins it to the top of the list
- Fills remaining slots from recently played games
- Displays up to 10 game banners with text fallbacks when artwork is missing
- Shows an in-game badge on the top listed game while a game is running
- Polls active game status every 15 seconds
- Polls recent achievements every 60 seconds
- Shows recent achievements with cached icons and optional rarity overlays
- Supports offline fallback by reusing previously cached data and images
- Opens games, game details, Steam library, friends, profile pages, and achievement pages directly from the skin
- Includes a settings sub-skin for game count, expiration windows, achievement count, and achievement rarity

## Requirements

- Windows
- Rainmeter
- A Steam Web API key
- A SteamID64
- PowerShell
- Internet connection

Steam privacy and status requirements:

- `My Profile` must be `Public` for achievement tracking
- `Game Details` must be `Public` for achievement tracking
- Steam status should be `Online` for active game detection

## Basic setup

RE-Write this
1. Install with the Rainmeter exe? or Copy the `Advanced Mini-Steam Launcher` folder into your Rainmeter folder 
2. Load `Advanced Mini-Steam-Launcher.ini`.
3. Click the missing credentials msg to open the `@Resources\SteamAccountInfo.inc` file.
4. Fill in:
   - `SteamAPIKey`
   - `SteamID64`
5. Refresh Rainmeter. 
6. Optional: Adjust settings and Advanced settings

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

First release version will be ready soon

## License

Creative Commons Attribution-NonCommercial-ShareAlike 3.0.

## Credits / acknowledgments

- Project authors: IZY2091
- Based on Venelder Mini-Steam Launcher
