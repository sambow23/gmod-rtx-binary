if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable large render bounds for all entities")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "256", true, false, "Size of render bounds")
local cv_rtx_updater_distance = CreateClientConVar("fr_rtx_distance", "256", true, false, "Maximum render distance for regular RTX light updaters")
local cv_environment_light_distance = CreateClientConVar("fr_environment_light_distance", "32768", true, false, "Maximum render distance for environment light updaters")
local cv_debug = CreateClientConVar("fr_debug_messages", "0", true, false, "Enable debug messages for RTX view frustum optimization")
local cv_show_advanced = CreateClientConVar("fr_show_advanced", "0", true, false, "Show advanced RTX view frustum settings")

-- Caches
local boundsSize = cv_bounds_size:GetFloat()
local mins = Vector(-boundsSize, -boundsSize, -boundsSize)
local maxs = Vector(boundsSize, boundsSize, boundsSize)
local DEBOUNCE_TIME = 0.1
local boundsUpdateTimer = "FR_BoundsUpdate"
local rtxUpdateTimer = "FR_RTXUpdate"
local rtxUpdaterCache = {}
local rtxUpdaterCount = 0
local staticProps = {}
local originalBounds = {} -- Store original render bounds
local IsValid = IsValid
local Vector = Vector
local pairs = pairs
local ipairs = ipairs
local ZERO_VECTOR = Vector(0, 0, 0)
local ents_GetAll = ents.GetAll
local timer_Simple = timer.Simple
local timer_Create = timer.Create
local timer_Remove = timer.Remove
local timer_Exists = timer.Exists
local RTXMath = RTXMath

-- RTX Light Updater model list
local RTX_UPDATER_MODELS = {
    ["models/hunter/plates/plate.mdl"] = 1,
    ["models/hunter/blocks/cube025x025x025.mdl"] = 1
}

local SPECIAL_ENTITIES = {
    ["hdri_cube_editor"] = true,
    ["rtx_lightupdater"] = true,
    ["rtx_lightupdatermanager"] = true
}

-- Store light types as numbers instead of strings for faster comparisons
local LIGHT_TYPES = {
    POINT = 1,
    SPOT = 2,
    DYNAMIC = 3,
    ENVIRONMENT = 4
}

local LIGHT_TYPE_STRINGS = {
    [1] = "light",
    [2] = "light_spot",
    [3] = "light_dynamic",
    [4] = "light_environment"
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
    if SPECIAL_ENTITIES[class] or (ent:GetModel() and RTX_UPDATER_MODELS[ent:GetModel()] == 1) then
        local distSqr = RTXMath.DistToSqr(ent:GetPos(), LocalPlayer():GetPos())
        return distSqr <= (cv_rtx_updater_distance:GetFloat() ^ 2)
    end
    
    return false
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
    if not IsRTXUpdater(ent) then return end
    
    rtxUpdaterCache[ent] = true
    rtxUpdaterCount = rtxUpdaterCount + 1
    
    -- Batch process RTX updater setup
    timer.Simple(0, function()
        if not IsValid(ent) then return end
        
        -- Set all properties in one frame
        if ent:GetClass() == "hdri_cube_editor" then
            local hdriSize = 32768
            local hdriBounds = Vector(hdriSize, hdriSize, hdriSize)
            ent:SetRenderBounds(-hdriBounds, hdriBounds)
        else
            local rtxDistance = cv_rtx_updater_distance:GetFloat()
            local rtxBounds = Vector(rtxDistance, rtxDistance, rtxDistance)
            ent:SetRenderBounds(-rtxBounds, rtxBounds)
        end
        
        -- Batch these property changes
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
        ent:SetPredictable(false)
    end)
end

local function RemoveFromRTXCache(ent)
    if rtxUpdaterCache[ent] then
        rtxUpdaterCache[ent] = nil
        rtxUpdaterCount = rtxUpdaterCount - 1
    end
end

local function BatchUpdateRTXBounds(entities, boundsSize)
    local vectorBounds = Vector(boundsSize, boundsSize, boundsSize)
    local negVectorBounds = Vector(-boundsSize, -boundsSize, -boundsSize) -- Add this line
    
    -- Process entities in batches of 100 to prevent frame hitches
    local batchSize = 100
    local processed = 0
    
    local function ProcessBatch()
        local endIndex = math.min(processed + batchSize, #entities)
        for i = processed + 1, endIndex do
            local ent = entities[i]
            if IsValid(ent) then
                local entPos = ent:GetPos()
                -- Make sure we have a valid position
                if entPos then
                    -- Use native bounds check
                    if RTXMath.IsWithinBounds(entPos, negVectorBounds, vectorBounds) then
                        ent:SetRenderBounds(negVectorBounds, vectorBounds)
                    end
                end
            end
        end
        processed = endIndex
        
        if processed < #entities then
            timer.Simple(0, ProcessBatch) -- Continue next frame
        end
    end
    
    ProcessBatch()
end

-- Set bounds for a single entity
local function SetEntityBounds(ent, useOriginal)
    if not IsValid(ent) then return end
    
    if useOriginal then
        if originalBounds[ent] then
            ent:SetRenderBounds(originalBounds[ent].mins, originalBounds[ent].maxs)
        end
    else
        StoreOriginalBounds(ent)
        
        -- Check for special entity classes first
        local specialBounds = SPECIAL_ENTITY_BOUNDS[ent:GetClass()]
        if specialBounds then
            local size = specialBounds.size
            local bounds = Vector(size, size, size)
            local negBounds = Vector(-size, -size, -size)
            
            -- Use native bounds check for optimization
            if RTXMath.IsWithinBounds(ent:GetPos(), negBounds, bounds) then
                ent:SetRenderBounds(negBounds, bounds)
                
                -- Debug output if enabled
                if cv_enabled:GetBool() and cv_debug:GetBool() then
                    print(string.format("[RTX Fixes] Special entity bounds (%s): %d", 
                        ent:GetClass(), size))
                end
            end
            
        -- Then check other entity types
        elseif ent:GetClass() == "hdri_cube_editor" then
            local hdriSize = 32768
            local hdriBounds = Vector(hdriSize, hdriSize, hdriSize)
            local negHdriBounds = Vector(-hdriSize, -hdriSize, -hdriSize)
            
            -- Use native bounds check
            if RTXMath.IsWithinBounds(ent:GetPos(), negHdriBounds, hdriBounds) then
                ent:SetRenderBounds(negHdriBounds, hdriBounds)
                ent:DisableMatrix("RenderMultiply")
                ent:SetNoDraw(false)
            end
            
        elseif rtxUpdaterCache[ent] then
            -- Completely separate handling for environment lights
            if ent.lightType == LIGHT_TYPES.ENVIRONMENT then
                local envSize = cv_environment_light_distance:GetFloat()
                local envBounds = Vector(envSize, envSize, envSize)
                local negEnvBounds = Vector(-envSize, -envSize, -envSize)
                
                -- Use native bounds and distance check
                local entPos = ent:GetPos()
                if RTXMath.IsWithinBounds(entPos, negEnvBounds, envBounds) then
                    ent:SetRenderBounds(negEnvBounds, envBounds)
                    
                    -- Only print if debug is enabled
                    if cv_enabled:GetBool() and cv_debug:GetBool() then
                        local distSqr = RTXMath.DistToSqr(entPos, vector_origin)
                        print(string.format("[RTX Fixes] Environment light bounds: %d (Distance: %.2f)", 
                            envSize, math.sqrt(distSqr)))
                    end
                end
                
            elseif REGULAR_LIGHT_TYPES[ent.lightType] then
                local rtxDistance = cv_rtx_updater_distance:GetFloat()
                local rtxBounds = Vector(rtxDistance, rtxDistance, rtxDistance)
                local negRtxBounds = Vector(-rtxDistance, -rtxDistance, -rtxDistance)
                
                -- Use native bounds and distance check
                local entPos = ent:GetPos()
                if RTXMath.IsWithinBounds(entPos, negRtxBounds, rtxBounds) then
                    ent:SetRenderBounds(negRtxBounds, rtxBounds)
                    
                    -- Only print if debug is enabled
                    if cv_enabled:GetBool() and cv_debug:GetBool() then
                        local distSqr = RTXMath.DistToSqr(entPos, vector_origin)
                        print(string.format("[RTX Fixes] Regular light bounds (%s): %d (Distance: %.2f)", 
                            ent.lightType, rtxDistance, math.sqrt(distSqr)))
                    end
                end
            end
            
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        else
            -- Default bounds
            if RTXMath.IsWithinBounds(ent:GetPos(), mins, maxs) then
                ent:SetRenderBounds(mins, maxs)
            end
        end
    end
end

-- Create clientside static props
local function CreateStaticProps()
    -- Clear existing props first
    for _, prop in pairs(staticProps) do
        if IsValid(prop) then
            prop:Remove()
        end
    end
    staticProps = {}

    if not (cv_enabled:GetBool() and NikNaks and NikNaks.CurrentMap) then return end

    -- Disable engine props before creating our own
    RunConsoleCommand("r_drawstaticprops", "0")
    
    local props = NikNaks.CurrentMap:GetStaticProps()
    -- Pre-filter props to only create ones that are likely to be visible
    local playerPos = LocalPlayer():GetPos()
    local maxDistance = 16384 -- Adjust based on your needs
    local maxDistanceSqr = maxDistance * maxDistance
    
    local batchSize = 50 -- Create fewer props per frame
    local processed = 0
    
    local function CreatePropBatch()
        local endIndex = math.min(processed + batchSize, #props)
        for i = processed + 1, endIndex do
            local propData = props[i]
            -- Use native distance check
            if RTXMath.DistToSqr(propData:GetPos(), playerPos) <= maxDistanceSqr then
                local prop = ClientsideModel(propData:GetModel())
                if IsValid(prop) then
                    prop:SetPos(propData:GetPos())
                    prop:SetAngles(propData:GetAngles())
                    prop:SetRenderBounds(mins, maxs)
                    prop:SetColor(propData:GetColor())
                    prop:SetModelScale(propData:GetScale())
                    -- Reduce network overhead
                    prop:SetPredictable(false)
                    -- Disable collisions if not needed
                    prop:SetCollisionGroup(COLLISION_GROUP_NONE)
                    table.insert(staticProps, prop)
                end
            end
        end
        processed = endIndex
        
        if processed < #props then
            timer.Simple(0, CreatePropBatch)
        end
    end
    
    CreatePropBatch()
end

-- Update all entities
local function UpdateAllEntities(useOriginal)
    local entities = ents.GetAll()
    if useOriginal then
        -- Batch process original bounds restoration
        local boundsEntities = {}
        for _, ent in ipairs(entities) do
            if originalBounds[ent] then
                table.insert(boundsEntities, ent)
            end
        end
        BatchUpdateRTXBounds(boundsEntities, cv_bounds_size:GetFloat())
    else
        -- Separate entities by type for optimized processing
        local regularEnts = {}
        local rtxUpdaters = {}
        local envLights = {}
        
        for _, ent in ipairs(entities) do
            if rtxUpdaterCache[ent] then
                if ent.lightType == LIGHT_TYPE_STRINGS[LIGHT_TYPES.ENVIRONMENT] then
                    table.insert(envLights, ent)
                else
                    table.insert(rtxUpdaters, ent)
                end
            else
                table.insert(regularEnts, ent)
            end
        end
        
        -- Process each type with appropriate bounds
        BatchUpdateRTXBounds(regularEnts, cv_bounds_size:GetFloat())
        BatchUpdateRTXBounds(rtxUpdaters, cv_rtx_updater_distance:GetFloat())
        BatchUpdateRTXBounds(envLights, cv_environment_light_distance:GetFloat())
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
        -- Disable engine static props when enabled
        RunConsoleCommand("r_drawstaticprops", "0")
    else
        UpdateAllEntities(true)
        -- Remove static props
        for _, prop in pairs(staticProps) do
            if IsValid(prop) then
                prop:Remove()
            end
        end
        staticProps = {}
        -- Re-enable engine static props when disabled
        RunConsoleCommand("r_drawstaticprops", "1")
    end
end)

cvars.AddChangeCallback("fr_bounds_size", function(_, _, new)
    -- Cancel any pending updates
    if timer.Exists(boundsUpdateTimer) then
        timer.Remove(boundsUpdateTimer)
    end
    
    -- Schedule the update
    timer.Create(boundsUpdateTimer, DEBOUNCE_TIME, 1, function()
        boundsSize = tonumber(new)
        local newBounds = Vector(boundsSize, boundsSize, boundsSize)
        local negNewBounds = Vector(-boundsSize, -boundsSize, -boundsSize)
        
        -- Pre-validate bounds for all entities
        local validEnts = {}
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and RTXMath.IsWithinBounds(ent:GetPos(), negNewBounds, newBounds) then
                table.insert(validEnts, ent)
            end
        end
        
        mins = negNewBounds
        maxs = newBounds
        
        if cv_enabled:GetBool() then
            BatchUpdateRTXBounds(validEnts, boundsSize)
            CreateStaticProps()
        end
    end)
end)


cvars.AddChangeCallback("fr_rtx_distance", function(_, _, new)
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

hook.Add("ShutDown", "CleanupStaticPropSettings", function()
    -- Restore engine static props on shutdown
    RunConsoleCommand("r_drawstaticprops", "1")
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
    -- Add distance analysis
    local playerPos = LocalPlayer():GetPos()
    print("\nDistance Analysis:")
    for ent in pairs(rtxUpdaterCache) do
        if IsValid(ent) then
            local distSqr = RTXMath.DistToSqr(ent:GetPos(), playerPos)
            print(string.format("  %s: %.2f units", 
                ent:GetClass(), 
                math.sqrt(distSqr)))
        end
    end
end)

local function CreateSettingsPanel(panel)
    -- Clear the panel first
    panel:ClearControls()
    
    -- Main toggle
    panel:CheckBox("Enable RTX View Frustum", "fr_enabled")
    panel:ControlHelp("Enables optimized render bounds for all entities")
    
    panel:Help("")
    
    -- Advanced settings toggle
    local advancedToggle = panel:CheckBox("Show Advanced Settings", "fr_show_advanced")
    panel:ControlHelp("Enable manual control of render bounds (Use with caution!)")
    
    -- Create a container for advanced settings
    local advancedPanel = vgui.Create("DPanel", panel)
    advancedPanel:Dock(TOP)
    advancedPanel:DockMargin(8, 8, 8, 8)
    advancedPanel:SetPaintBackground(false)
    advancedPanel:SetVisible(cv_show_advanced:GetBool())
    advancedPanel:SetTall(200) -- Adjust height as needed
    
    -- Advanced settings content
    local advancedContent = vgui.Create("DScrollPanel", advancedPanel)
    advancedContent:Dock(FILL)
    
    -- Regular entity bounds
    local boundsGroup = vgui.Create("DForm", advancedContent)
    boundsGroup:Dock(TOP)
    boundsGroup:DockMargin(0, 0, 0, 5)
    boundsGroup:SetName("Entity Bounds")
    
    local boundsSlider = boundsGroup:NumSlider("Regular Entity Bounds", "fr_bounds_size", 256, 32000, 0)
    boundsSlider:SetTooltip("Size of render bounds for regular entities")

    -- Light settings
    local lightGroup = vgui.Create("DForm", advancedContent)
    lightGroup:Dock(TOP)
    lightGroup:DockMargin(0, 0, 0, 5)
    lightGroup:SetName("Light Settings")
    
    local rtxDistanceSlider = lightGroup:NumSlider("Regular Light Distance", "fr_rtx_distance", 256, 32000, 0)
    rtxDistanceSlider:SetTooltip("Maximum render distance for regular RTX light updaters")
    
    local envLightSlider = lightGroup:NumSlider("Environment Light Distance", "fr_environment_light_distance", 16384, 65536, 0)
    envLightSlider:SetTooltip("Maximum render distance for environment light updaters")
    
    -- Warning text
    local warningLabel = vgui.Create("DLabel", advancedContent)
    warningLabel:Dock(TOP)
    warningLabel:DockMargin(5, 5, 5, 5)
    warningLabel:SetTextColor(Color(255, 200, 0))
    warningLabel:SetText("Warning: Changing these values may affect performance and visual quality.")
    warningLabel:SetWrap(true)
    warningLabel:SetTall(40)
    
    -- Tools section
    local toolsGroup = vgui.Create("DForm", advancedContent)
    toolsGroup:Dock(TOP)
    toolsGroup:DockMargin(0, 0, 0, 5)
    toolsGroup:SetName("Tools")
    
    local refreshBtn = toolsGroup:Button("Refresh All Bounds")
    function refreshBtn:DoClick()
        RunConsoleCommand("fr_refresh")
        surface.PlaySound("buttons/button14.wav")
    end
    
    -- Debug settings
    panel:Help("\nDebug Settings")
    panel:CheckBox("Show Debug Messages", "fr_debug_messages")
    panel:ControlHelp("Show detailed debug messages in console")
    
    -- Update advanced panel visibility when the ConVar changes
    cvars.AddChangeCallback("fr_show_advanced", function(_, _, new)
        if IsValid(advancedPanel) then
            advancedPanel:SetVisible(tobool(new))
        end
    end)
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