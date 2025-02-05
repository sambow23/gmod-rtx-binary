if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable large render bounds for all entities")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "4096", true, false, "Size of render bounds")
local cv_rtx_updater_distance = CreateClientConVar("fr_rtx_distance", "2048", true, false, "Maximum render distance for regular RTX light updaters")
local cv_environment_light_distance = CreateClientConVar("fr_environment_light_distance", "32768", true, false, "Maximum render distance for environment light updaters")
local cv_debug = CreateClientConVar("fr_debug_messages", "0", true, false, "Enable debug messages for RTX view frustum optimization")
local cv_show_advanced = CreateClientConVar("fr_show_advanced", "0", true, false, "Show advanced RTX view frustum settings")
local cv_static_mode = CreateClientConVar("fr_static_mode", "0", true, false, "Use static render bounds instead of distance-based")
local cv_static_regular_bounds = CreateClientConVar("fr_static_regular_bounds", "4096", true, false, "Size of static render bounds for regular entities")
local cv_static_rtx_bounds = CreateClientConVar("fr_static_rtx_bounds", "2048", true, false, "Size of static render bounds for RTX lights")
local cv_static_env_bounds = CreateClientConVar("fr_static_env_bounds", "32768", true, false, "Size of static render bounds for environment lights")

-- Cache the bounds vectors
local boundsSize = cv_bounds_size:GetFloat()
local mins = Vector(-boundsSize, -boundsSize, -boundsSize)
local maxs = Vector(boundsSize, boundsSize, boundsSize)
local DEBOUNCE_TIME = 0.1
local boundsUpdateTimer = "FR_BoundsUpdate"
local rtxUpdateTimer = "FR_RTXUpdate"
local rtxUpdaterCache = {}
local rtxUpdaterCount = 0

-- RTX Light Updater model list
local RTX_UPDATER_MODELS = {
    ["models/hunter/plates/plate.mdl"] = true,
    ["models/hunter/blocks/cube025x025x025.mdl"] = true
}

-- Cache for static props
local staticProps = {}
local originalBounds = {} -- Store original render bounds

local SPECIAL_ENTITIES = {
    ["hdri_cube_editor"] = true,
    ["rtx_lightupdater"] = true,
    ["rtx_lightupdatermanager"] = true
}

local LIGHT_TYPES = {
    POINT = "light",
    SPOT = "light_spot",
    DYNAMIC = "light_dynamic",
    ENVIRONMENT = "light_environment"
}

local REGULAR_LIGHT_TYPES = {
    [LIGHT_TYPES.POINT] = true,
    [LIGHT_TYPES.SPOT] = true,
    [LIGHT_TYPES.DYNAMIC] = true
}

local SPECIAL_ENTITY_BOUNDS = {
    ["prop_door_rotating"] = {
        size = 256, -- Default size for doors
        description = "Door entities", -- For debug/documentation
    }
    -- Add more entities here as needed:
    -- ["entity_class"] = { size = number, description = "description" }
}

-- Helper function to add new special entities
function AddSpecialEntityBounds(class, size, description)
    SPECIAL_ENTITY_BOUNDS[class] = {
        size = size,
        description = description
    }
    
    -- Update existing entities of this class if the optimization is enabled
    if cv_enabled:GetBool() then
        for _, ent in ipairs(ents.FindByClass(class)) do
            if IsValid(ent) then
                SetEntityBounds(ent, false)
            end
        end
    end
end

-- Helper function to identify RTX updaters
local function IsRTXUpdater(ent)
    if not IsValid(ent) then return false end
    local class = ent:GetClass()
    return SPECIAL_ENTITIES[class] or 
           (ent:GetModel() and RTX_UPDATER_MODELS[ent:GetModel()])
end

-- Store original bounds for an entity
local function StoreOriginalBounds(ent)
    if not IsValid(ent) or originalBounds[ent] then return end
    local mins, maxs = ent:GetRenderBounds()
    originalBounds[ent] = {mins = mins, maxs = maxs}
end

-- RTX updater cache management functions
local function AddToRTXCache(ent)
    if not IsValid(ent) or rtxUpdaterCache[ent] then return end
    if IsRTXUpdater(ent) then
        rtxUpdaterCache[ent] = true
        rtxUpdaterCount = rtxUpdaterCount + 1
        
        -- Set initial RTX bounds
        local rtxDistance = cv_rtx_updater_distance:GetFloat()
        local rtxBoundsSize = Vector(rtxDistance, rtxDistance, rtxDistance)
        ent:SetRenderBounds(-rtxBoundsSize, rtxBoundsSize)
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
        
        -- Special handling for hdri_cube_editor to ensure it's never culled
        if ent:GetClass() == "hdri_cube_editor" then
            -- Using a very large value for HDRI cube editor
            local hdriSize = 32768 -- Maximum recommended size
            local hdriBounds = Vector(hdriSize, hdriSize, hdriSize)
            ent:SetRenderBounds(-hdriBounds, hdriBounds)
        end
    end
end

local function RemoveFromRTXCache(ent)
    if rtxUpdaterCache[ent] then
        rtxUpdaterCache[ent] = nil
        rtxUpdaterCount = rtxUpdaterCount - 1
    end
end

-- Set bounds for a single entity
local function SetEntityBounds(ent, useOriginal)
    if not IsValid(ent) then return end
    
    if useOriginal then
        if originalBounds[ent] then
            ent:SetRenderBounds(originalBounds[ent].mins, originalBounds[ent].maxs)
        end
        return
    end
    
    StoreOriginalBounds(ent)
    
    -- Static mode handling
    if cv_static_mode:GetBool() then
        -- Get static bounds sizes
        local regularSize = cv_static_regular_bounds:GetFloat()
        local rtxSize = cv_static_rtx_bounds:GetFloat()
        local envSize = cv_static_env_bounds:GetFloat()
        
        -- Special entity classes first
        local specialBounds = SPECIAL_ENTITY_BOUNDS[ent:GetClass()]
        if specialBounds then
            local size = specialBounds.size
            local bounds = Vector(size, size, size)
            ent:SetRenderBounds(-bounds, bounds)
            
            if cv_debug:GetBool() then
                print(string.format("[RTX Fixes Static] Special entity bounds (%s): %d", 
                    ent:GetClass(), size))
            end
        -- HDRI cube editor handling
        elseif ent:GetClass() == "hdri_cube_editor" then
            local bounds = Vector(envSize, envSize, envSize)
            ent:SetRenderBounds(-bounds, bounds)
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
            
            if cv_debug:GetBool() then
                print(string.format("[RTX Fixes Static] HDRI bounds: %d", envSize))
            end
        -- RTX updater handling
        elseif rtxUpdaterCache[ent] then
            if ent.lightType == LIGHT_TYPES.ENVIRONMENT then
                local bounds = Vector(envSize, envSize, envSize)
                ent:SetRenderBounds(-bounds, bounds)
                if cv_debug:GetBool() then
                    print(string.format("[RTX Fixes Static] Environment light bounds: %d", envSize))
                end
            else
                local bounds = Vector(rtxSize, rtxSize, rtxSize)
                ent:SetRenderBounds(-bounds, bounds)
                if cv_debug:GetBool() then
                    print(string.format("[RTX Fixes Static] RTX light bounds: %d", rtxSize))
                end
            end
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        -- Regular entities
        else
            local bounds = Vector(regularSize, regularSize, regularSize)
            ent:SetRenderBounds(-bounds, bounds)
            if cv_debug:GetBool() then
                print(string.format("[RTX Fixes Static] Regular entity bounds: %d", regularSize))
            end
        end
        return
    end
    
    -- Distance-based mode handling
    -- Special entity classes first
    local specialBounds = SPECIAL_ENTITY_BOUNDS[ent:GetClass()]
    if specialBounds then
        local size = specialBounds.size
        local bounds = Vector(size, size, size)
        ent:SetRenderBounds(-bounds, bounds)
        
        -- Debug output if enabled
        if cv_enabled:GetBool() and cv_debug:GetBool() then
            print(string.format("[RTX Fixes] Special entity bounds (%s): %d", 
                ent:GetClass(), size))
        end
    -- HDRI cube editor handling
    elseif ent:GetClass() == "hdri_cube_editor" then
        local hdriSize = 32768
        local hdriBounds = Vector(hdriSize, hdriSize, hdriSize)
        ent:SetRenderBounds(-hdriBounds, hdriBounds)
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
    -- RTX updater handling
    elseif rtxUpdaterCache[ent] then
        -- Environment lights
        if ent.lightType == LIGHT_TYPES.ENVIRONMENT then
            local envSize = cv_environment_light_distance:GetFloat()
            local envBounds = Vector(envSize, envSize, envSize)
            ent:SetRenderBounds(-envBounds, envBounds)
            
            -- Debug output
            if cv_enabled:GetBool() and cv_debug:GetBool() then
                print(string.format("[RTX Fixes] Environment light bounds: %d", envSize))
            end
        -- Regular lights
        elseif REGULAR_LIGHT_TYPES[ent.lightType] then
            local rtxDistance = cv_rtx_updater_distance:GetFloat()
            local rtxBounds = Vector(rtxDistance, rtxDistance, rtxDistance)
            ent:SetRenderBounds(-rtxBounds, rtxBounds)
            
            -- Debug output
            if cv_enabled:GetBool() and cv_debug:GetBool() then
                print(string.format("[RTX Fixes] Regular light bounds (%s): %d", 
                    ent.lightType, rtxDistance))
            end
        end
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
    -- Regular entities
    else
        ent:SetRenderBounds(mins, maxs)
    end
end

-- Create clientside static props
local function CreateStaticProps()
    -- Clear existing static props
    for _, prop in pairs(staticProps) do
        if IsValid(prop) then
            prop:Remove()
        end
    end
    staticProps = {}

    if cv_enabled:GetBool() and NikNaks and NikNaks.CurrentMap then
        local props = NikNaks.CurrentMap:GetStaticProps()
        for _, propData in pairs(props) do
            local prop = ClientsideModel(propData:GetModel())
            if IsValid(prop) then
                prop:SetPos(propData:GetPos())
                prop:SetAngles(propData:GetAngles())
                prop:SetRenderBounds(mins, maxs)
                prop:SetColor(propData:GetColor())
                prop:SetModelScale(propData:GetScale())
                table.insert(staticProps, prop)
            end
        end
    end
end

-- Update all entities
local function UpdateAllEntities(useOriginal)
    for _, ent in ipairs(ents.GetAll()) do
        SetEntityBounds(ent, useOriginal)
    end
end

-- Hook for new entities
hook.Add("OnEntityCreated", "SetLargeRenderBounds", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if IsValid(ent) then
            AddToRTXCache(ent)
            SetEntityBounds(ent, not cv_enabled:GetBool())
        end
    end)
end)
-- Initial setup
hook.Add("InitPostEntity", "InitialBoundsSetup", function()
    timer.Simple(1, function()
        if cv_enabled:GetBool() then
            UpdateAllEntities(false)
            CreateStaticProps()
        end
    end)
end)

-- Map cleanup/reload handler
hook.Add("OnReloaded", "RefreshStaticProps", function()
    -- Clear bounds cache
    originalBounds = {}
    
    -- Remove existing static props
    for _, prop in pairs(staticProps) do
        if IsValid(prop) then
            prop:Remove()
        end
    end
    staticProps = {}
    
    -- Recreate if enabled
    if cv_enabled:GetBool() then
        timer.Simple(1, CreateStaticProps)
    end
end)

-- Handle ConVar changes
cvars.AddChangeCallback("fr_enabled", function(_, _, new)
    local enabled = tobool(new)
    
    if enabled then
        UpdateAllEntities(false)
        CreateStaticProps()
    else
        UpdateAllEntities(true)
        -- Remove static props
        for _, prop in pairs(staticProps) do
            if IsValid(prop) then
                prop:Remove()
            end
        end
        staticProps = {}
    end
end)

cvars.AddChangeCallback("fr_static_mode", function(_, _, new)
    local isStatic = tobool(new)
    
    -- Handle bounds and timer logic
    if isStatic then
        timer.Remove(boundsUpdateTimer)
        timer.Remove(rtxUpdateTimer)
        timer.Remove("fr_environment_update")
        
        -- Apply static bounds to all entities
        if cv_enabled:GetBool() then
            UpdateAllEntities(false)
        end
    else
        -- Reset to distance-based mode
        if cv_enabled:GetBool() then
            -- Reset cached values
            boundsSize = cv_bounds_size:GetFloat()
            mins = Vector(-boundsSize, -boundsSize, -boundsSize)
            maxs = Vector(boundsSize, boundsSize, boundsSize)
            
            print("[RTX Fixes] Switching back to distance-based bounds...")
            UpdateAllEntities(false)
            CreateStaticProps()
        end
    end
end)

cvars.AddChangeCallback("fr_bounds_size", function(_, _, new)
    if cv_static_mode:GetBool() then return end
    -- Cancel any pending updates
    if timer.Exists(boundsUpdateTimer) then
        timer.Remove(boundsUpdateTimer)
    end
    
    -- Schedule the update
    timer.Create(boundsUpdateTimer, DEBOUNCE_TIME, 1, function()
        boundsSize = tonumber(new)
        mins = Vector(-boundsSize, -boundsSize, -boundsSize)
        maxs = Vector(boundsSize, boundsSize, boundsSize)
        
        if cv_enabled:GetBool() then
            UpdateAllEntities(false)
            CreateStaticProps()
        end
    end)
end)


cvars.AddChangeCallback("fr_rtx_distance", function(_, _, new)
    if cv_static_mode:GetBool() then return end
    if not cv_enabled:GetBool() then return end
    
    if timer.Exists(rtxUpdateTimer) then
        timer.Remove(rtxUpdateTimer)
    end
    
    timer.Create(rtxUpdateTimer, DEBOUNCE_TIME, 1, function()
        local rtxDistance = tonumber(new)
        local rtxBoundsSize = Vector(rtxDistance, rtxDistance, rtxDistance)
        
        -- Only update non-environment light updaters
        for ent in pairs(rtxUpdaterCache) do
            if IsValid(ent) then
                -- Explicitly skip environment lights
                if ent.lightType ~= "light_environment" then
                    ent:SetRenderBounds(-rtxBoundsSize, rtxBoundsSize)
                end
            else
                RemoveFromRTXCache(ent)
            end
        end
    end)
end)

-- Separate callback for environment light distance changes
cvars.AddChangeCallback("fr_environment_light_distance", function(_, _, new)
    if cv_static_mode:GetBool() then return end
    if not cv_enabled:GetBool() then return end
    
    if timer.Exists("fr_environment_update") then
        timer.Remove("fr_environment_update")
    end
    
    timer.Create("fr_environment_update", DEBOUNCE_TIME, 1, function()
        local envDistance = tonumber(new)
        local envBoundsSize = Vector(envDistance, envDistance, envDistance)
        
        -- Only update environment light updaters
        for ent in pairs(rtxUpdaterCache) do
            if IsValid(ent) and ent.lightType == "light_environment" then
                ent:SetRenderBounds(-envBoundsSize, envBoundsSize)
                
                -- Only print if debug is enabled
                if cv_enabled:GetBool() and cv_debug:GetBool() then
                    print(string.format("[RTX Fixes] Updating environment light bounds to %d", envDistance))
                end
            end
        end
    end)
end)

-- ConCommand to refresh all entities' bounds
concommand.Add("fr_refresh", function()
    -- Clear bounds cache
    originalBounds = {}
    
    if cv_enabled:GetBool() then
        boundsSize = cv_bounds_size:GetFloat()
        mins = Vector(-boundsSize, -boundsSize, -boundsSize)
        maxs = Vector(boundsSize, boundsSize, boundsSize)
        
        UpdateAllEntities(false)
        CreateStaticProps()
    else
        UpdateAllEntities(true)
    end
    
    print("Refreshed render bounds for all entities" .. (cv_enabled:GetBool() and " with large bounds" or " with original bounds"))
end)

-- Entity cleanup
hook.Add("EntityRemoved", "CleanupRTXCache", function(ent)
    RemoveFromRTXCache(ent)
    originalBounds[ent] = nil
end)

-- Debug command
concommand.Add("fr_debug", function()
    print("\nRTX Frustum Optimization Debug:")
    print("Enabled:", cv_enabled:GetBool())
    print("Bounds Size:", cv_bounds_size:GetFloat())
    print("RTX Updater Distance:", cv_rtx_updater_distance:GetFloat())
    print("Static Props Count:", #staticProps)
    print("Stored Original Bounds:", table.Count(originalBounds))
    print("RTX Updaters (Cached):", rtxUpdaterCount)
    
    -- Special entities debug info
    print("\nSpecial Entity Classes:")
    for class, data in pairs(SPECIAL_ENTITY_BOUNDS) do
        print(string.format("  %s: %d units (%s)", 
            class, 
            data.size, 
            data.description))
    end
end)

local function CreateSettingsPanel(panel)
    -- Clear the panel first
    panel:ClearControls()
    
    -- Main toggle
    panel:CheckBox("Enable RTX View Frustum", "fr_enabled")
    panel:ControlHelp("Enables optimized render bounds for all entities")
    
    panel:Help("")

    -- Mode Selection
    local staticToggle = panel:CheckBox("Use Static Bounds", "fr_static_mode")
    panel:ControlHelp("Apply bounds once and disable automatic updates (May worsen performance)")
    
    -- Create a container for static bounds settings
    local staticPanel = vgui.Create("DPanel", panel)
    staticPanel:Dock(TOP)
    staticPanel:DockMargin(8, 8, 8, 8)
    staticPanel:SetPaintBackground(false)
    staticPanel:SetVisible(cv_static_mode:GetBool())
    staticPanel:SetTall(160)
    
    -- Static bounds settings
    local staticForm = vgui.Create("DForm", staticPanel)
    staticForm:Dock(FILL)
    staticForm:SetName("Static Bounds Settings")
    
    local regularSlider = staticForm:NumSlider("Regular Entity Bounds", "fr_static_regular_bounds", 256, 32000, 0)
    regularSlider:SetTooltip("Size of render bounds for regular entities in static mode")
    
    local rtxSlider = staticForm:NumSlider("RTX Light Bounds", "fr_static_rtx_bounds", 256, 32000, 0)
    rtxSlider:SetTooltip("Size of render bounds for RTX lights in static mode")
    
    local envSlider = staticForm:NumSlider("Environment Light Bounds", "fr_static_env_bounds", 16384, 65536, 0)
    envSlider:SetTooltip("Size of render bounds for environment lights in static mode")
    
    -- Add refresh button specifically for static mode
    local staticRefreshBtn = staticForm:Button("Apply Static Bounds")
    function staticRefreshBtn:DoClick()
        if cv_static_mode:GetBool() then
            print("[RTX Fixes] Applying static bounds to all entities...")
            UpdateAllEntities(false)
            surface.PlaySound("buttons/button14.wav")
        end
    end

    local staticCallbackID = "StaticModeToggle_" .. tostring(math.random(1, 10000))
    cvars.AddChangeCallback("fr_static_mode", function(_, _, new)
        if IsValid(staticPanel) then
            local isStatic = tobool(new)
            staticPanel:SetVisible(isStatic)
            -- Force panel layout update
            if IsValid(panel) then
                panel:InvalidateLayout(true)
                panel:InvalidateChildren(true)
            end
        end
    end, staticCallbackID)
    
    -- Advanced settings toggle
    panel:Help("")
    local advancedToggle = panel:CheckBox("Show Advanced Settings", "fr_show_advanced")
    panel:ControlHelp("Enable manual control of render bounds (Use with caution!)")
    
    -- Create a container for advanced settings
    local advancedPanel = vgui.Create("DPanel", panel)
    advancedPanel:Dock(TOP)
    advancedPanel:DockMargin(8, 8, 8, 8)
    advancedPanel:SetPaintBackground(false)
    advancedPanel:SetVisible(cv_show_advanced:GetBool())
    advancedPanel:SetTall(200)
    
    -- Advanced settings content
    local advancedContent = vgui.Create("DScrollPanel", advancedPanel)
    advancedContent:Dock(FILL)
    
    -- Light settings (including regular entity bounds)
    local lightGroup = vgui.Create("DForm", advancedContent)
    lightGroup:Dock(TOP)
    lightGroup:DockMargin(0, 0, 0, 5)
    lightGroup:SetName("Light Settings")
    
    -- Regular entity bounds now part of light settings
    local distanceSlider = lightGroup:NumSlider("Regular Entity Bounds", "fr_bounds_size", 256, 32000, 0)
    distanceSlider:SetTooltip("Size of render bounds for regular entities")
    
    local rtxDistanceSlider = lightGroup:NumSlider("Regular Light Distance", "fr_rtx_distance", 256, 32000, 0)
    rtxDistanceSlider:SetTooltip("Maximum render distance for regular RTX light updaters")
    rtxDistanceSlider:SetEnabled(not cv_static_mode:GetBool())
    
    local envLightSlider = lightGroup:NumSlider("Environment Light Distance", "fr_environment_light_distance", 16384, 65536, 0)
    envLightSlider:SetTooltip("Maximum render distance for environment light updaters")
    envLightSlider:SetEnabled(not cv_static_mode:GetBool())
    
    -- Warning text
    local warningLabel = vgui.Create("DLabel", advancedContent)
    warningLabel:Dock(TOP)
    warningLabel:DockMargin(5, 5, 5, 5)
    warningLabel:SetTextColor(Color(255, 200, 0))
    warningLabel:SetText("Warning: Changing these values may affect performance and visual quality.")
    warningLabel:SetWrap(true)
    warningLabel:SetTall(40)
    
    -- Debug settings
    panel:Help("\nDebug Settings")
    panel:CheckBox("Show Debug Messages", "fr_debug_messages")
    panel:ControlHelp("Show detailed debug messages in console")
    
    -- Update UI states based on static mode
    local function UpdateControlStates(isStatic)
        if IsValid(staticPanel) then
            staticPanel:SetVisible(isStatic)
            staticPanel:InvalidateLayout(true)
        end
        if IsValid(distancePanel) then
            distancePanel:SetVisible(not isStatic)
            distancePanel:InvalidateLayout(true)
        end
        if IsValid(advancedPanel) then
            advancedPanel:SetVisible(cv_show_advanced:GetBool())
            advancedPanel:InvalidateLayout(true)
        end
        -- Update slider states in advanced panel
        if rtxDistanceSlider then rtxDistanceSlider:SetEnabled(not isStatic) end
        if envLightSlider then envLightSlider:SetEnabled(not isStatic) end
        
        -- Force the parent panel to update its layout
        if IsValid(panel) then
            panel:InvalidateLayout(true)
        end
    end

    -- Callback for static mode changes
    hook.Add("RTXFixesStaticModeChanged", panel, function(isStatic)
        UpdateControlStates(isStatic)
    end)
    
    -- Update advanced panel visibility when show_advanced changes
    local callbackID = "ShowAdvancedToggle_" .. tostring(math.random(1, 10000))
    cvars.AddChangeCallback("fr_show_advanced", function(_, _, new)
        if IsValid(advancedPanel) then
            advancedPanel:SetVisible(tobool(new))
        end
    end, callbackID)
    
    -- Clean up hooks and callbacks when panel is removed
    panel.OnRemove = function()
        hook.Remove("RTXFixesStaticModeChanged", panel)
        cvars.RemoveChangeCallback("fr_show_advanced", callbackID)
        cvars.RemoveChangeCallback("fr_static_mode", staticCallbackID) -- Add this line
    end
    
    -- Initial states
    UpdateControlStates(cv_static_mode:GetBool())
end

-- Add to Utilities menu
hook.Add("PopulateToolMenu", "RTXFrustumOptimizationMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_OVF", "#RTX View Frustum", "", "", function(panel)
        CreateSettingsPanel(panel)
    end)
end)

concommand.Add("fr_add_special_entity", function(ply, cmd, args)
    if not args[1] or not args[2] then
        print("Usage: fr_add_special_entity <class> <size> [description]")
        return
    end
    
    local class = args[1]
    local size = tonumber(args[2])
    local description = args[3] or "Custom entity bounds"
    
    if not size then
        print("Size must be a number!")
        return
    end
    
    AddSpecialEntityBounds(class, size, description)
    print(string.format("Added special entity bounds for %s: %d units", class, size))
end)

local function ApplyStaticBoundsChange()
    if cv_static_mode:GetBool() and cv_enabled:GetBool() then
        print("[RTX Fixes] Updating static bounds...")
        UpdateAllEntities(false)
    end
end

cvars.AddChangeCallback("fr_static_regular_bounds", function(_, _, new)
    ApplyStaticBoundsChange()
end)

cvars.AddChangeCallback("fr_static_rtx_bounds", function(_, _, new)
    ApplyStaticBoundsChange()
end)

cvars.AddChangeCallback("fr_static_env_bounds", function(_, _, new)
    ApplyStaticBoundsChange()
end)