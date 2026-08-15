# Advanced Mini-Steam Launcher

Advanced Mini-Steam Launcher shows recent games, recent achievements, and quick links in a configurable compact layout.

## Screenshots
<table>
  <tr>
    <td style="text-align: center;">
      <strong>Mini-Steam Launcher</strong><br>
      <strong>3 Games &amp; 3 Achievements</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Mini-Steam Settings</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Mini-Steam Launcher</strong><br>
      <strong>1 Game &amp; 3 Achievements</strong><br>
    </td>
    <td style="text-align: center;">
      <strong>Mini-Steam Launcher</strong><br>
      <strong>10 Games &amp; 10 Achievements</strong><br>
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


<img src=".git-files/App%20breakdown.png" alt="App breakdown" style="display: block; width: 100%; max-width: 400px; height: auto; margin: 0;">


## Features

- Tracks the currently active Steam game and pins it to the top of the list
- Fills remaining slots from recently played games
- Displays up to 10 game banners
- Displays up to 10 recent achievements
- Achievements can be displayed with rarity overlay
- Supports offline fallback by reusing previously cached data and images
- Opens games, game details, Steam library, friends, profile pages, and achievement pages directly from the skin
- Includes a settings sub-skin to make adjusting settings easier

## Requirements

- Windows
- Rainmeter
- Steam
  - Steam Web API key
  - SteamID64
- PowerShell
- Internet connection

Steam privacy and status requirements:

- `My Profile` must be `Public` for achievement tracking
- `Game Details` must be `Public` for achievement tracking
- Steam user status needs to be `Online` for active game detection

## Basic setup

1. Install Rainmeter.
2. Copy the `Advanced Mini-Steam Launcher` folder into `Documents\Rainmeter\Skins\`, or install using the .rmskin.
3. Refresh Rainmeter, then load `\Advanced Mini-Steam-Launcher.ini`.
4. Click the missing credentials message to open `@Resources\SteamAccountInfo.inc`.
5. Open `SteamAccountInfo.inc` and fill in:
   - `SteamAPIKey`
   - `SteamID64`
6. Refresh Rainmeter again.
7. Optional: adjust Settings and `@Resources\AdvancedSettings.inc`.

## Usage

Common actions:

- Game Art
  - Left-click: Launch the game through Steam
  - Right-click: Open the game's Steam library page
- Game Banner
  - Left-click: Open the user's Steam library page
- Profile Image
  - Left-click: Open Steam friends
  - Right-click: Open the Steam community profile
- Achievement Panel
  - Left-click: Open the game's achievement page in Steam
- Settings Gear
  - Visible when hovering over the game banner
  - Opens the Mini-Steam Settings menu

## Known issues / limitations

- Rebuild can be slow at times
- Active game tracking and achievement visibility depend entirely on Steam privacy settings.

## Project status

Work in progress / prototype.

## License

Creative Commons Attribution-NonCommercial-ShareAlike 3.0.

## Credits / acknowledgments

- Project authors: IZY2091
- Based on Venelder Mini-Steam Launcher

Check for updates here:<br>
[Advanced Mini-Steam Launcher on GitHub](https://github.com/RRam2020/Advanced-Mini-Steam-Launcher)

To report issues or request features, use:<br>
[GitHub Issues](https://github.com/RRam2020/Advanced-Mini-Steam-Launcher/issues).
