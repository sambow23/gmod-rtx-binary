if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable large render bounds for all entities")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "4096", true, false, "Size of render bounds")
local cv_rtx_updater_distance = CreateClientConVar("fr_rtx_distance", "2048", true, false, "Maximum render distance for RTX light updaters")
local cv_distance_scaling = CreateClientConVar("fr_distance_scaling", "1", true, false, "Enable distance-based render bounds scaling")
local cv_min_distance = CreateClientConVar("fr_min_distance", "256", true, false, "Distance at which scaling begins")
local cv_max_distance = CreateClientConVar("fr_max_distance", "8192", true, false, "Distance at which maximum bounds are reached")
local cv_min_bounds = CreateClientConVar("fr_min_bounds", "256", true, false, "Minimum render bounds size")
local cv_behind_scale = CreateClientConVar("fr_behind_scale", "1.5", true, false, "Multiplier for bounds size behind player")
local cv_scale_power = CreateClientConVar("fr_scale_power", "1.5", true, false, "Power curve for distance scaling (higher = more gradual)")
local cv_update_frequency = CreateClientConVar("fr_update_freq", "0.25", true, false, "How often to update bounds (in seconds)")
local cv_max_per_frame = CreateClientConVar("fr_max_updates", "10", true, false, "Maximum number of entities to update per frame")
local cv_behind_player_culling = CreateClientConVar("fr_behind_culling", "1", true, false, "Enable special handling of objects behind the player")



-- Cache
local boundsSize = cv_bounds_size:GetFloat()
local mins = Vector(-boundsSize, -boundsSize, -boundsSize)
local maxs = Vector(boundsSize, boundsSize, boundsSize)
local DEBOUNCE_TIME = 0.1
local boundsUpdateTimer = "FR_BoundsUpdate"
local rtxUpdateTimer = "FR_RTXUpdate"
local rtxUpdaterCache = {}
local rtxUpdaterCount = 0
local BATCH_SIZE = CreateClientConVar("fr_batch_size", "100", true, false, "How many entities to process per frame")
local processingQueue = {}
local isProcessing = false
local progressNotification = nil
local totalEntitiesToProcess = 0
local PARTITION_SIZE = 1024
local spatialPartitions = {}
local BOUNDS_UPDATE_INTERVAL = 0.25
local lastBoundsUpdate = 0
local lastPlayerPos = Vector(0, 0, 0)
local lastPlayerAng = Angle(0, 0, 0)
local updateQueue = {}
local nextQueueUpdate = 0
local lastPartitionUpdate = 0
local PARTITION_UPDATE_INTERVAL = 1.0

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

local function GetPartitionKey(pos)
    -- Larger partition size for better performance
    return math.floor(pos.x / (PARTITION_SIZE * 2)) .. ":" .. 
           math.floor(pos.y / (PARTITION_SIZE * 2))
end

local function UpdateSpatialPartitions()
    spatialPartitions = {}
    local player = LocalPlayer()
    if not IsValid(player) then return end
    
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) then
            local key = GetPartitionKey(ent:GetPos())
            spatialPartitions[key] = spatialPartitions[key] or {}
            table.insert(spatialPartitions[key], ent)
        end
    end
end

-- Optimization: Better queue management
local function UpdateEntityQueue()
    if CurTime() < nextQueueUpdate then return end
    nextQueueUpdate = CurTime() + cv_update_frequency:GetFloat()
    
    local player = LocalPlayer()
    if not IsValid(player) then return end
    
    -- Only update partitions if player has moved significantly
    local playerPos = player:GetPos()
    if playerPos:DistToSqr(lastPlayerPos) > 10000 or -- 100 units squared
       CurTime() - lastPartitionUpdate > PARTITION_UPDATE_INTERVAL then
        UpdateSpatialPartitions()
        lastPlayerPos = playerPos
        lastPartitionUpdate = CurTime()
    end
    
    -- Clear and rebuild queue
    updateQueue = {}
    
    -- Get player's partition and adjacent ones
    local playerKey = GetPartitionKey(playerPos)
    local px, py = playerKey:match("(-?%d+):(-?%d+)")
    px, py = tonumber(px), tonumber(py)
    
    -- Collect entities from relevant partitions
    for x = -1, 1 do
        for y = -1, 1 do
            local key = (px + x) .. ":" .. (py + y)
            if spatialPartitions[key] then
                for _, ent in ipairs(spatialPartitions[key]) do
                    if IsValid(ent) and not rtxUpdaterCache[ent] and 
                       ent:GetClass() ~= "hdri_cube_editor" then
                        table.insert(updateQueue, ent)
                    end
                end
            end
        end
    end
    
    -- Sort queue by distance to player
    table.sort(updateQueue, function(a, b)
        if not IsValid(a) or not IsValid(b) then return false end
        return a:GetPos():DistToSqr(playerPos) < b:GetPos():DistToSqr(playerPos)
    end)
end

-- Optimization: More efficient GetBoundsSizeForDistance
local cachedBoundsSizes = {}
local lastBoundsUpdate = 0
local BOUNDS_CACHE_LIFETIME = 0.5

local function GetBoundsSizeForDistance(ent)
    if not cv_distance_scaling:GetBool() then
        return boundsSize
    end

    local player = LocalPlayer()
    if not IsValid(player) or not IsValid(ent) then return boundsSize end
    
    -- Check cache
    if cachedBoundsSizes[ent] and 
       CurTime() - cachedBoundsSizes[ent].time < BOUNDS_CACHE_LIFETIME then
        return cachedBoundsSizes[ent].size
    end

    local entPos = ent:GetPos()
    local playerPos = player:GetPos()
    local distance = entPos:Distance(playerPos)
    
    -- Early return if within minimum distance
    if distance <= cv_min_distance:GetFloat() then
        return cv_min_bounds:GetFloat()
    end

    -- Calculate base scaling factor
    local minDist = cv_min_distance:GetFloat()
    local maxDist = cv_max_distance:GetFloat()
    local scaleFactor = math.Clamp((distance - minDist) / (maxDist - minDist), 0, 1)
    
    -- Apply power curve for more gradual scaling
    local power = cv_scale_power:GetFloat()
    scaleFactor = math.pow(scaleFactor, power)
    
    -- Only apply behind-player scaling if enabled
    if cv_behind_player_culling:GetBool() then
        local playerAng = player:EyeAngles()
        local playerForward = playerAng:Forward()
        local toEntity = (entPos - playerPos):GetNormalized()
        local dotProduct = playerForward:Dot(toEntity)
        
        if dotProduct < 0 then
            -- Gradually increase scale based on how far behind the player it is
            local behindScale = Lerp(-dotProduct, 1, cv_behind_scale:GetFloat())
            scaleFactor = scaleFactor * behindScale
        end
    end
    
    -- Calculate final bounds size
    local finalSize = Lerp(scaleFactor, cv_min_bounds:GetFloat(), boundsSize)
    
    -- Add minimum padding based on entity's model bounds
    if originalBounds[ent] then
        local origMins, origMaxs = originalBounds[ent].mins, originalBounds[ent].maxs
        local modelSize = math.max(
            math.abs(origMaxs.x - origMins.x),
            math.abs(origMaxs.y - origMins.y),
            math.abs(origMaxs.z - origMins.z)
        )
        finalSize = math.max(finalSize, modelSize * 1.5)
    end
    
    -- Cache the result
    cachedBoundsSizes[ent] = {
        size = finalSize,
        time = CurTime()
    }
    
    return finalSize
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
        
        -- Special handling for HDRI cube editor
        if ent:GetClass() == "hdri_cube_editor" then
            local hdriSize = 32768
            local hdriBounds = Vector(hdriSize, hdriSize, hdriSize)
            ent:SetRenderBounds(-hdriBounds, hdriBounds)
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        -- Use cache to check for RTX updaters
        elseif rtxUpdaterCache[ent] then
            local rtxDistance = cv_rtx_updater_distance:GetFloat()
            local rtxBoundsSize = Vector(rtxDistance, rtxDistance, rtxDistance)
            ent:SetRenderBounds(-rtxBoundsSize, rtxBoundsSize)
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        else
            local scaledSize = GetBoundsSizeForDistance(ent)
            local scaledMins = Vector(-scaledSize, -scaledSize, -scaledSize)
            local scaledMaxs = Vector(scaledSize, scaledSize, scaledSize)
            ent:SetRenderBounds(scaledMins, scaledMaxs)
        end
    end
end

-- Optimization: Frame budgeted updates
local function ProcessQueuedUpdates()
    local maxUpdates = cv_max_per_frame:GetInt()
    local processed = 0
    
    while processed < maxUpdates and #updateQueue > 0 do
        local ent = table.remove(updateQueue, 1)
        if IsValid(ent) then
            SetEntityBounds(ent, false)
            processed = processed + 1
        end
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
    -- Clear any existing processing
    processingQueue = {}
    isProcessing = false
    
    -- Gather valid entities and process them
    local entities = ents.GetAll()
    for _, ent in ipairs(entities) do
        if IsValid(ent) then
            SetEntityBounds(ent, useOriginal)
        end
    end
    
    -- Signal completion
    hook.Run("FR_FinishedProcessing")
end

-- Status reporting
local lastProcessStatus = 0
hook.Add("HUDPaint", "FR_ProcessingStatus", function()
    if not isProcessing then return end
    
    -- Update status once per second
    if CurTime() - lastProcessStatus > 1 then
        lastProcessStatus = CurTime()
        
        local progress = math.Round((1 - (#processingQueue / #ents.GetAll())) * 100)
        notification.AddProgress("FR_Processing", "Updating Render Bounds: " .. progress .. "%", progress / 100)
    end
end)

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

-- Clean up cache periodically
timer.Create("FR_CacheCleaner", 5, 0, function()
    local currentTime = CurTime()
    for ent, data in pairs(cachedBoundsSizes) do
        if not IsValid(ent) or currentTime - data.time > BOUNDS_CACHE_LIFETIME then
            cachedBoundsSizes[ent] = nil
        end
    end
end)

-- Replace the Think hook with optimized version
hook.Remove("Think", "FR_UpdateDynamicBounds")
hook.Add("Think", "FR_UpdateDynamicBounds", function()
    if not cv_enabled:GetBool() or not cv_distance_scaling:GetBool() then return end
    
    -- Update queue periodically
    UpdateEntityQueue()
    
    -- Process a limited number of updates per frame
    ProcessQueuedUpdates()
end)

-- Add performance monitoring
local performanceStats = {
    updateTime = 0,
    entitiesProcessed = 0,
    lastReset = 0
}

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
        -- Delay static prop creation until entity processing is done
        hook.Add("FR_FinishedProcessing", "FR_CreateStaticProps", function()
            CreateStaticProps()
            hook.Remove("FR_FinishedProcessing", "FR_CreateStaticProps")
        end)
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
        
        -- Use cache instead of iterating all entities
        for ent in pairs(rtxUpdaterCache) do
            if IsValid(ent) then
                ent:SetRenderBounds(-rtxBoundsSize, rtxBoundsSize)
            else
                RemoveFromRTXCache(ent)
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

local debugInfo = {
    totalProcessed = 0,
    lastBatchTime = 0,
    averageBatchTime = 0
}

-- Debug command
concommand.Add("fr_debug", function()
    print("\nRTX Frustum Optimization Debug:")
    print("Enabled:", cv_enabled:GetBool())
    print("Batch Size:", BATCH_SIZE:GetInt())
    print("Currently Processing:", isProcessing)
    print("Queued Entities:", #processingQueue)
    print("Total Processed:", debugInfo.totalProcessed)
    print("Average Batch Time:", string.format("%.3f ms", debugInfo.averageBatchTime * 1000))
    print("Static Props Count:", #staticProps)
    print("Stored Original Bounds:", table.Count(originalBounds))
    print("RTX Updaters (Cached):", rtxUpdaterCount)
    print("\nPerformance Statistics:")
    print("Average Update Time:", string.format("%.3f ms", performanceStats.updateTime * 1000))
    print("Entities in Queue:", #updateQueue)
    print("Entities Processed:", performanceStats.entitiesProcessed)
    print("Cached Bounds:", table.Count(cachedBoundsSizes))
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

    -- Add distance scaling toggle
    panel:CheckBox("Enable Distance-Based Scaling", "fr_distance_scaling")
    
    -- Add distance scaling settings
    local minDistSlider = panel:NumSlider("Minimum Distance", "fr_min_distance", 64, 1024, 0)
    minDistSlider:SetTooltip("Distance at which scaling begins")
    
    local maxDistSlider = panel:NumSlider("Maximum Distance", "fr_max_distance", 1024, 16384, 0)
    maxDistSlider:SetTooltip("Distance at which maximum bounds are reached")
    
    local minBoundsSlider = panel:NumSlider("Minimum Bounds Size", "fr_min_bounds", 64, 1024, 0)
    minBoundsSlider:SetTooltip("Minimum size of render bounds for close objects")

    panel:Help("")
    panel:Help("Behind-Player Culling Settings:")
    
    -- Add behind-player culling toggle
    panel:CheckBox("Enable Behind-Player Culling", "fr_behind_culling")
    
    -- Only show these sliders if behind-player culling is enabled
    local behindScaleSlider
    local function UpdateBehindPlayerSettings()
        if IsValid(behindScaleSlider) then
            behindScaleSlider:SetEnabled(cv_behind_player_culling:GetBool())
        end
    end
    
    behindScaleSlider = panel:NumSlider("Behind Player Scale", "fr_behind_scale", 1, 3, 2)
    behindScaleSlider:SetTooltip("Multiplier for bounds size when objects are behind the player")
    
    -- Update slider state when the checkbox changes
    cvars.AddChangeCallback("fr_behind_culling", function(_, _, new)
        UpdateBehindPlayerSettings()
    end)
    
    -- Initial state
    UpdateBehindPlayerSettings()
    
    -- Add some spacing
    panel:Help("")

    panel:Help("Performance Settings:")
    
    local updateFreqSlider = panel:NumSlider("Update Frequency", "fr_update_freq", 0.1, 1.0, 2)
    updateFreqSlider:SetTooltip("How often to update bounds (in seconds)")
    
    local maxUpdatesSlider = panel:NumSlider("Max Updates Per Frame", "fr_max_updates", 1, 50, 0)
    maxUpdatesSlider:SetTooltip("Maximum number of entities to update per frame")
    

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
    
    -- Add more spacing before status
    panel:Help("")
    panel:Help("")
    
    -- Status Label Container
    local statusContainer = vgui.Create("DPanel", panel)
    statusContainer:Dock(BOTTOM)
    statusContainer:SetTall(80) -- Adjust height as needed
    statusContainer:DockMargin(0, 5, 0, 0)
    statusContainer.Paint = function(self, w, h)
        surface.SetDrawColor(0, 0, 0, 50)
        surface.DrawRect(0, 0, w, h)
    end
    
    -- Status Label
    local status = vgui.Create("DLabel", statusContainer)
    status:Dock(FILL)
    status:DockMargin(5, 5, 5, 5)
    status:SetText("Status Information:")
    status:SetWrap(true)
    
    -- Update status periodically
    function status:Think()
        if self.NextUpdate and self.NextUpdate > CurTime() then return end
        self.NextUpdate = CurTime() + 1
        
        local rtxCount = 0
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and IsRTXUpdater(ent) then
                rtxCount = rtxCount + 1
            end
        end
        
        local statusText = string.format(
            "Status Information:\n\n" ..
            "Static Props: %d\n" ..
            "RTX Updaters: %d\n" ..
            "Stored Bounds: %d",
            #staticProps,
            rtxCount,
            table.Count(originalBounds)
        )
        self:SetText(statusText)
    end
end

-- Add to Utilities menu
hook.Add("PopulateToolMenu", "RTXFrustumOptimizationMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_OVF", "#RTX View Frustum", "", "", function(panel)
        CreateSettingsPanel(panel)
    end)
end)