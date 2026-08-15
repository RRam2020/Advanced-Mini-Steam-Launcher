local state = {}

local unitChoices = { "Minutes", "Hours", "Days" }

local function clamp(value, minimumValue, maximumValue)
    if value < minimumValue then
        return minimumValue
    end

    if value > maximumValue then
        return maximumValue
    end

    return value
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function splitChoices(rawValue)
    local choices = {}
    for choice in string.gmatch(tostring(rawValue or ""), "[^|]+") do
        choice = trim(choice)
        if choice ~= "" then
            table.insert(choices, choice)
        end
    end
    return choices
end

local function getStringVariable(name, defaultValue)
    local value = SKIN:GetVariable(name, defaultValue)
    value = trim(value)
    if value == "" then
        return defaultValue
    end
    return value
end

local function getIntVariable(name, defaultValue, minimumValue, maximumValue)
    local rawValue = tonumber(SKIN:GetVariable(name, tostring(defaultValue)))
    if rawValue == nil then
        rawValue = defaultValue
    end

    rawValue = math.floor(rawValue)
    return clamp(rawValue, minimumValue, maximumValue)
end

local function normalizeUnit(value)
    local normalizedValue = trim(value)
    for _, choice in ipairs(unitChoices) do
        if normalizedValue == choice then
            return choice
        end
    end
    return "Minutes"
end

local function normalizeRarity(value)
    local normalizedValue = string.lower(trim(value))
    if normalizedValue == "0" or normalizedValue == "false" or normalizedValue == "off" or normalizedValue == "no" then
        return 0
    end
    return 1
end

local function resolveUnitMinutes(inputValue, unitValue)
    if unitValue == "Hours" then
        return inputValue * 60
    end

    if unitValue == "Days" then
        return inputValue * 1440
    end

    return inputValue
end

local function setVariable(name, value)
    SKIN:Bang("!SetVariable", name, tostring(value))
end

local function syncState(redraw)
    local normalTextColor = SKIN:GetVariable("TextColor", "255,255,255,255")
    local disabledTextColor = SKIN:GetVariable("DisabledTextColor", "160,160,160,255")
    local normalButtonColor = SKIN:GetVariable("ButtonColor", "110,110,110,255")
    local normalButtonBorderColor = SKIN:GetVariable("ButtonBorderColor", "150,150,150,255")
    local disabledButtonColor = SKIN:GetVariable("DisabledButtonColor", "90,90,90,255")
    local disabledButtonBorderColor = SKIN:GetVariable("DisabledButtonBorderColor", "120,120,120,255")
    local recentlyPlayedMinutes = resolveUnitMinutes(state.DraftRecentlyPlayedExpirationInputValue, state.DraftRecentlyPlayedExpirationUnit)
    local recentAchievementMinutes = resolveUnitMinutes(state.DraftRecentAchievementExpirationInputValue, state.DraftRecentAchievementExpirationUnit)

    setVariable("DraftDisplayGameCount", state.DraftDisplayGameCount)

    setVariable("DraftRecentlyPlayedExpirationInputValue", state.DraftRecentlyPlayedExpirationInputValue)
    setVariable("DraftRecentlyPlayedExpirationUnit", state.DraftRecentlyPlayedExpirationUnit)
    setVariable("DraftRecentlyPlayedExpirationMinutes", recentlyPlayedMinutes)

    setVariable("DraftRecentAchievementDisplayCount", state.DraftRecentAchievementDisplayCount)

    setVariable("DraftRecentAchievementExpirationInputValue", state.DraftRecentAchievementExpirationInputValue)
    setVariable("DraftRecentAchievementExpirationUnit", state.DraftRecentAchievementExpirationUnit)
    setVariable("DraftRecentAchievementExpirationMinutes", recentAchievementMinutes)

    setVariable("DraftShowAchievementRarity", state.DraftShowAchievementRarity)
    setVariable("DraftShowAchievementRarityLabel", state.DraftShowAchievementRarity == 1 and "On" or "Off")
    setVariable("DraftIsSaving", state.IsSaving and 1 or 0)
    setVariable("DraftSaveButtonText", state.IsSaving and "Updating" or "Save")
    setVariable("DraftSaveButtonFontColor", state.IsSaving and disabledTextColor or normalTextColor)
    setVariable("DraftSaveButtonColor", state.IsSaving and disabledButtonColor or normalButtonColor)
    setVariable("DraftSaveButtonBorderColor", state.IsSaving and disabledButtonBorderColor or normalButtonBorderColor)
    setVariable("DraftCloseButtonFontColor", state.IsSaving and disabledTextColor or normalTextColor)

    SKIN:Bang("!UpdateMeterGroup", "SettingsDynamic")
    if redraw ~= false then
        SKIN:Bang("!Redraw")
    end
end

function Initialize()
    state.DraftDisplayGameCount = getIntVariable("DraftDisplayGameCount", 10, 0, 10)
    state.DraftRecentlyPlayedExpirationInputValue = getIntVariable("DraftRecentlyPlayedExpirationInputValue", 336, 0, 999)
    state.DraftRecentlyPlayedExpirationUnit = normalizeUnit(getStringVariable("DraftRecentlyPlayedExpirationUnit", "Hours"))
    state.DraftRecentAchievementDisplayCount = getIntVariable("DraftRecentAchievementDisplayCount", 10, 0, 10)
    state.DraftRecentAchievementExpirationInputValue = getIntVariable("DraftRecentAchievementExpirationInputValue", 7, 0, 999)
    state.DraftRecentAchievementExpirationUnit = normalizeUnit(getStringVariable("DraftRecentAchievementExpirationUnit", "Days"))
    state.DraftShowAchievementRarity = normalizeRarity(getStringVariable("DraftShowAchievementRarity", "1"))
    state.IsSaving = false

    syncState(false)
end

function AdjustNumber(name, deltaValue, minimumValue, maximumValue)
    if state.IsSaving then
        return
    end

    if state[name] == nil then
        return
    end

    local currentValue = tonumber(state[name]) or 0
    local nextValue = clamp(
        currentValue + (tonumber(deltaValue) or 0),
        tonumber(minimumValue) or currentValue,
        tonumber(maximumValue) or currentValue
    )

    if nextValue ~= currentValue then
        state[name] = nextValue
        syncState(true)
    end
end

function CycleChoice(name, rawChoices, directionValue)
    if state.IsSaving then
        return
    end

    if state[name] == nil then
        return
    end

    local choices = splitChoices(rawChoices)
    if #choices < 2 then
        return
    end

    local currentValue = tostring(state[name])
    local currentIndex = 1
    for index, choice in ipairs(choices) do
        if choice == currentValue then
            currentIndex = index
            break
        end
    end

    local direction = tonumber(directionValue) or 1
    local step = direction < 0 and -1 or 1
    local nextIndex = currentIndex + step

    if nextIndex < 1 then
        nextIndex = #choices
    elseif nextIndex > #choices then
        nextIndex = 1
    end

    local nextValue = choices[nextIndex]
    if name == "DraftShowAchievementRarity" then
        nextValue = normalizeRarity(nextValue)
    elseif name == "DraftRecentlyPlayedExpirationUnit" or name == "DraftRecentAchievementExpirationUnit" then
        nextValue = normalizeUnit(nextValue)
    end

    if nextValue ~= state[name] then
        state[name] = nextValue
        syncState(true)
    end
end

function TrySave()
    if state.IsSaving then
        return
    end

    state.IsSaving = true
    syncState(true)
    SKIN:Bang("!CommandMeasure", "MeasureSaveSettingsDraft", "Run")
end

function EndSave()
    state.IsSaving = false
    syncState(true)
end

function TryClose()
    if state.IsSaving then
        return
    end

    SKIN:Bang("!DeactivateConfig")
end
