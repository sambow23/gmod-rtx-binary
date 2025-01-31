if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable large render bounds for all entities")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "4096", true, false, "Size of render bounds")
local cv_rtx_updater_distance = CreateClientConVar("fr_rtx_distance", "2048", true, false, "Maximum render distance for regular RTX light updaters")
local cv_environment_light_distance = CreateClientConVar("fr_environment_light_distance", "32768", true, false, "Maximum render distance for environment light updaters")
local cv_batch_size = CreateClientConVar("fr_batch_size", "100", true, false, "Number of entities to update per frame")


-- Cache the bounds vectors
local boundsSize = cv_bounds_size:GetFloat()
local mins = Vector(-boundsSize, -boundsSize, -boundsSize)
local maxs = Vector(boundsSize, boundsSize, boundsSize)
local DEBOUNCE_TIME = 2
local boundsUpdateTimer = "FR_BoundsUpdate"
local rtxUpdateTimer = "FR_RTXUpdate"
local rtxUpdaterCache = {}
local rtxUpdaterCount = 0
local UPDATE_BATCH_SIZE = 50 -- Reduced default batch size
local MAX_QUEUED_UPDATES = 100 -- Safety limit for queue size
local MIN_FRAME_TIME = 0.016 -- Target ~60fps (adjust if needed)
local updateQueue = {}
local isProcessingQueue = false
local lastFrameTime = 0
local frameSkip = 0
local MAX_FRAME_SKIP = 3

local VALID_RTX_CLASSES = {
    hdri_cube_editor = true,
    rtx_lightupdater = true,
    rtx_lightupdatermanager = true
}

-- RTX Light Updater model list
local RTX_UPDATER_MODELS = {
    ["models/hunter/plates/plate.mdl"] = true,
    ["models/hunter/blocks/cube025x025x025.mdl"] = true
}

-- Cache for static props
local staticProps = {}
local originalBounds = {}

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

-- Helper function to identify RTX updaters
local function IsRTXUpdater(ent)
    if not IsValid(ent) then return false end
    local class = ent:GetClass()
    if VALID_RTX_CLASSES[class] then return true end
    local model = ent:GetModel()
    return model and RTX_UPDATER_MODELS[model]
end

-- Store original bounds for an entity
local function StoreOriginalBounds(ent)
    if not IsValid(ent) or originalBounds[ent] then return end
    local mins, maxs = ent:GetRenderBounds()
    originalBounds[ent] = {mins = mins, maxs = maxs}
end

-- Add RTX updater cache management functions
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
    else
        StoreOriginalBounds(ent)
        
        if ent:GetClass() == "hdri_cube_editor" then
            local hdriSize = 32768
            local hdriBounds = Vector(hdriSize, hdriSize, hdriSize)
            ent:SetRenderBounds(-hdriBounds, hdriBounds)
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        elseif rtxUpdaterCache[ent] then
            -- Completely separate handling for environment lights
            if ent.lightType == LIGHT_TYPES.ENVIRONMENT then
                local envSize = cv_environment_light_distance:GetFloat()
                local envBounds = Vector(envSize, envSize, envSize)
                ent:SetRenderBounds(-envBounds, envBounds)
                if cv_enabled:GetBool() then
                    print(string.format("[RTX Fixes] Environment light bounds: %d", envSize))
                end
            elseif REGULAR_LIGHT_TYPES[ent.lightType] then
                local rtxDistance = cv_rtx_updater_distance:GetFloat()
                local rtxBounds = Vector(rtxDistance, rtxDistance, rtxDistance)
                ent:SetRenderBounds(-rtxBounds, rtxBounds)
                if cv_enabled:GetBool() then
                    print(string.format("[RTX Fixes] Regular light bounds (%s): %d", 
                        ent.lightType, rtxDistance))
                end
            end
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        else
            ent:SetRenderBounds(mins, maxs)
        end
    end
end

local function SafeQueueUpdate(ent)
    if #updateQueue >= MAX_QUEUED_UPDATES then
        print("[RTX Fixes] Warning: Update queue full, skipping updates")
        return false
    end
    table.insert(updateQueue, ent)
    return true
end

local function ProcessUpdateQueue()
    if #updateQueue == 0 then
        isProcessingQueue = false
        return
    end

    -- Skip frames if we're struggling
    if frameSkip > 0 then
        frameSkip = frameSkip - 1
        timer.Simple(engine.TickInterval(), ProcessUpdateQueue)
        return
    end

    local currentTime = SysTime()
    local deltaTime = currentTime - lastFrameTime

    -- If frame time is too high, skip some frames
    if deltaTime > MIN_FRAME_TIME * 2 then
        frameSkip = MAX_FRAME_SKIP
        timer.Simple(engine.TickInterval(), ProcessUpdateQueue)
        return
    end

    local processCount = 0
    local i = 1
    local removeIndices = {}
    
    -- Process batch
    while i <= #updateQueue and processCount < UPDATE_BATCH_SIZE do
        local ent = updateQueue[i]
        if IsValid(ent) then
            -- Safety check before updating bounds
            if not ent:IsWorld() and not ent:IsWeapon() then
                xpcall(function()
                    SetEntityBounds(ent, not cv_enabled:GetBool())
                end, function(err)
                    print("[RTX Fixes] Error updating bounds: ", err)
                end)
            end
            processCount = processCount + 1
        end
        table.insert(removeIndices, i)
        i = i + 1
    end

    -- Remove processed entities (in reverse to maintain indices)
    for i = #removeIndices, 1, -1 do
        table.remove(updateQueue, removeIndices[i])
    end

    lastFrameTime = SysTime()

    if #updateQueue > 0 then
        -- Schedule next batch with dynamic delay based on queue size
        local delay = math.max(0, MIN_FRAME_TIME - deltaTime)
        timer.Simple(delay, ProcessUpdateQueue)
    else
        isProcessingQueue = false
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
    -- Clear existing queue
    updateQueue = {}
    local entities = ents.GetAll()
    
    -- Process in chunks
    local chunkSize = 1000
    local currentChunk = 1
    
    local function QueueNextChunk()
        local startIdx = (currentChunk - 1) * chunkSize + 1
        local endIdx = math.min(startIdx + chunkSize - 1, #entities)
        
        for i = startIdx, endIdx do
            local ent = entities[i]
            if IsValid(ent) and not ent:IsWorld() then
                SafeQueueUpdate(ent)
            end
        end
        
        currentChunk = currentChunk + 1
        
        if endIdx < #entities then
            timer.Simple(0.1, QueueNextChunk)
        elseif not isProcessingQueue then
            isProcessingQueue = true
            ProcessUpdateQueue()
        end
    end
    
    QueueNextChunk()
end

-- Hook for new entities
hook.Add("OnEntityCreated", "SetLargeRenderBounds", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if IsValid(ent) then
            AddToRTXCache(ent)
            table.insert(updateQueue, ent)
            
            if not isProcessingQueue then
                isProcessingQueue = true
                ProcessUpdateQueue()
            end
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

cvars.AddChangeCallback("fr_batch_size", function(_, _, new)
    UPDATE_BATCH_SIZE = math.Clamp(tonumber(new) or 100, 1, 1000)
end)

cvars.AddChangeCallback("fr_bounds_size", function(_, _, new)
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
    if not cv_enabled:GetBool() then return end
    
    if timer.Exists(rtxUpdateTimer) then
        timer.Remove(rtxUpdateTimer)
    end
    
    timer.Create(rtxUpdateTimer, DEBOUNCE_TIME, 1, function()
        local rtxDistance = tonumber(new)
        local rtxBoundsSize = Vector(rtxDistance, rtxDistance, rtxDistance)
        
        -- Clear queue before adding new updates
        updateQueue = {}
        
        for ent in pairs(rtxUpdaterCache) do
            if IsValid(ent) and REGULAR_LIGHT_TYPES[ent.lightType] then
                SafeQueueUpdate(ent)
            end
        end

        if not isProcessingQueue and #updateQueue > 0 then
            isProcessingQueue = true
            ProcessUpdateQueue()
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
        
        -- Queue environment lights for update
        updateQueue = {}
        for ent in pairs(rtxUpdaterCache) do
            if IsValid(ent) and ent.lightType == LIGHT_TYPES.ENVIRONMENT then
                table.insert(updateQueue, ent)
            end
        end

        if not isProcessingQueue and #updateQueue > 0 then
            isProcessingQueue = true
            ProcessUpdateQueue()
        end
    end)
end)

-- Emergency controls
concommand.Add("fr_emergency_stop", function()
    updateQueue = {}
    isProcessingQueue = false
    print("[RTX Fixes] Emergency stop - cleared update queue")
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
end)

local function CreateSettingsPanel(panel)
    -- Clear the panel first
    panel:ClearControls()
    
    -- Create a scroll panel to contain everything
    local scrollPanel = vgui.Create("DScrollPanel", panel)
    scrollPanel:Dock(FILL)
    scrollPanel:DockMargin(0, 0, 0, 0)
    
    -- Enable/Disable Toggle
    panel:CheckBox("Enable RTX View Frustrum", "fr_enabled")
    
    -- Add some spacing
    panel:Help("")
    
    -- Bounds Size Slider
    local boundsSlider = panel:NumSlider("Render Bounds Size", "fr_bounds_size", 256, 32000, 0)
    boundsSlider:SetTooltip("Size of render bounds for regular entities")
    
    -- Add some spacing
    panel:Help("")
    
    -- RTX Updater Distance Slider
    local rtxDistanceSlider = panel:NumSlider("RTX Updater Distance", "fr_rtx_distance", 256, 32000, 0)
    rtxDistanceSlider:SetTooltip("Maximum render distance for RTX light updaters")
    
    -- Add some spacing
    panel:Help("")
    
    -- Refresh Button
    local refreshBtn = panel:Button("Refresh All Bounds")
    function refreshBtn.DoClick()
        RunConsoleCommand("fr_refresh")
        surface.PlaySound("buttons/button14.wav")
    end
    
    -- Debug Button
    local debugBtn = panel:Button("Print Debug Info")
    function debugBtn.DoClick()
        RunConsoleCommand("fr_debug")
        surface.PlaySound("buttons/button14.wav")
    end
end

-- Add to Utilities menu
hook.Add("PopulateToolMenu", "RTXFrustumOptimizationMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_OVF", "#RTX View Frustum", "", "", function(panel)
        CreateSettingsPanel(panel)
    end)
end)