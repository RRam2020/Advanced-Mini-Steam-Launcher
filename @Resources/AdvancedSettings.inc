; ==============================================================================
; Advanced Settings
; ==============================================================================

[Variables]
; DisplayGameCount
; How many recent game banners the launcher can show at once. 0 hides the game banner area.
; Min: 0 | Max: 10
DisplayGameCount=3

; RecentlyPlayedExpirationMinutes
; Raw minutes for how long launched games stay in the recent list.
; The Mini-Steam Settings window shows this as a value plus Minutes / Hours / Days.
; Effective min: 0 minutes | Effective max: 1438560 minutes (999 days)
RecentlyPlayedExpirationMinutes=7200

; RecentAchievementDisplayCount
; How many recent achievements the widget can show at once. 0 hides the achievements area.
; Min: 0 | Max: 10
RecentAchievementDisplayCount=3

; RecentAchievementExpirationMinutes
; Raw minutes for how long achievements stay visible in the widget.
; The Mini-Steam Settings window shows this as a value plus Minutes / Hours / Days.
; Effective min: 0 minutes | Effective max: 1438560 minutes (999 days)
RecentAchievementExpirationMinutes=144000

; ShowAchievementRarity
; Toggles overlays based on global Steam unlock percentage.
; 0 = Off | 1 = On
ShowAchievementRarity=1

; If ShowAchievementRarity=1, achievements at or below these global completion
; percentages get the matching overlay. Decimals are allowed. Lower percent = rarer.
; Keep them in ascending order.
; Example: Gold <= Silver <= Bronze
GoldAchievementOverlayThresholdPercent=2.0
SilverAchievementOverlayThresholdPercent=5.0
BronzeAchievementOverlayThresholdPercent=9.0
