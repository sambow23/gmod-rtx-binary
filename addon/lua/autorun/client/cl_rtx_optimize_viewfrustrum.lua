if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable large render bounds for all entities")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "4096", true, false, "Size of render bounds")
local cv_rtx_updater_distance = CreateClientConVar("fr_rtx_distance", "2048", true, false, "Maximum render distance for RTX light updaters")
local cv_dynamic_bounds = CreateClientConVar("fr_dynamic_bounds", "1", true, false, "Enable distance-based dynamic render bounds")
local cv_update_interval = CreateClientConVar("fr_update_interval", "0.1", true, false, "How often to update distance-based bounds (seconds)")
local cv_entities_per_frame = CreateClientConVar("fr_entities_per_frame", "10", true, false, "How many entities to update per frame")

local DISTANCE_TIERS = {
    {distance = 1024, scale = 4.0},    -- Very close objects: largest bounds
    {distance = 2048, scale = 2.0},    -- Close objects: large bounds
    {distance = 4096, scale = 1.0},    -- Medium distance: normal bounds
    {distance = 8192, scale = 0.5}     -- Far objects: smallest bounds
}

-- Cache the bounds vectors
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
local lastPlayerPos = Vector(0, 0, 0)
local lastUpdateTime = 0
local UPDATE_INTERVAL = 0.1  -- Update position every 0.1 seconds
local nextBoundsUpdate = 0
local ENTITIES_PER_FRAME = 10
local precalculatedBounds = {}
local updateQueue = {}
local IsValid = IsValid
local CurTime = CurTime
local table_insert = table.insert
local table_remove = table.remove
local pairs = pairs
local ipairs = ipairs
local math_random = math.random
local Vector = Vector
local ZERO_VECTOR = Vector(0, 0, 0)
local HDRI_BOUNDS = Vector(32768, 32768, 32768)
local SCALE_LOOKUP = {
    [1024] = 4.0,
    [2048] = 2.0,
    [4096] = 1.0,
    [8192] = 0.5
}

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

local function UpdatePrecalculatedBounds()
    precalculatedBounds = {}
    for _, tier in ipairs(DISTANCE_TIERS) do
        local scaledSize = boundsSize * tier.scale
        precalculatedBounds[tier.distance] = {
            mins = Vector(-scaledSize, -scaledSize, -scaledSize),
            maxs = Vector(scaledSize, scaledSize, scaledSize)
        }
    end
end
UpdatePrecalculatedBounds()

-- Get appropriate bounds for distance
local function GetBoundsForDistance(distance)
    -- Local reference is faster than global
    local preBounds = precalculatedBounds
    local distTiers = DISTANCE_TIERS
    
    -- Quick early returns for common cases
    if distance <= distTiers[1].distance then
        return preBounds[distTiers[1].distance]
    elseif distance >= distTiers[#distTiers].distance then
        return preBounds[distTiers[#distTiers].distance]
    end
    
    -- Single-pass lookup
    for i = 2, #distTiers do
        if distance <= distTiers[i].distance then
            return preBounds[distTiers[i].distance]
        end
    end
    
    return preBounds[distTiers[#distTiers].distance]
end

-- Queue entities for update
local function QueueEntitiesForUpdate()
    if not cv_enabled:GetBool() or not cv_dynamic_bounds:GetBool() then return end
    
    local curTime = CurTime()
    if curTime - lastUpdateTime > UPDATE_INTERVAL and IsValid(LocalPlayer()) then
        lastPlayerPos = LocalPlayer():GetPos()
        lastUpdateTime = curTime
    end
    
    local queue = updateQueue
    queue = {}
    
    -- More efficient entity collection
    local entities = ents.GetAll()
    local count = #entities
    local j = 1
    
    for i = 1, count do
        local ent = entities[i]
        if IsValid(ent) and not rtxUpdaterCache[ent] and ent:GetClass() ~= "hdri_cube_editor" then
            queue[j] = ent
            j = j + 1
        end
    end
    
    -- Fisher-Yates shuffle (more efficient than random swapping)
    local n = #queue
    while n > 1 do
        local k = math_random(n)
        queue[n], queue[k] = queue[k], queue[n]
        n = n - 1
    end
    
    updateQueue = queue
end

-- Process entities in the queue
local function ProcessQueuedEntities()
    if #updateQueue == 0 then
        QueueEntitiesForUpdate()
        return
    end
    
    local processed = 0
    local maxProcess = ENTITIES_PER_FRAME
    local queue = updateQueue -- Local reference
    local pos = lastPlayerPos -- Cache player position
    
    while processed < maxProcess and #queue > 0 do
        local ent = table_remove(queue)
        if IsValid(ent) then
            -- Avoid creating temporary Vector objects
            local entPos = ent:GetPos()
            local dx = entPos.x - pos.x
            local dy = entPos.y - pos.y
            local dz = entPos.z - pos.z
            local distance = (dx * dx + dy * dy + dz * dz) ^ 0.5 -- Faster than Vector:Distance
            
            local bounds = GetBoundsForDistance(distance)
            ent:SetRenderBounds(bounds.mins, bounds.maxs)
        end
        processed = processed + 1
    end
end

local function GetBoundsScaleForDistance(distance)
    for _, tier in ipairs(DISTANCE_TIERS) do
        if distance <= tier.distance then
            return tier.scale
        end
    end
    return DISTANCE_TIERS[#DISTANCE_TIERS].scale -- Use largest scale for very far objects
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
        local orig = originalBounds[ent]
        if orig then
            ent:SetRenderBounds(orig.mins, orig.maxs)
        end
        return
    end

    StoreOriginalBounds(ent)
    
    local class = ent:GetClass()
    
    -- Use early returns and avoid repeated conditions
    if class == "hdri_cube_editor" then
        ent:SetRenderBounds(-HDRI_BOUNDS, HDRI_BOUNDS)
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
        return
    end
    
    if rtxUpdaterCache[ent] then
        local rtxDistance = cv_rtx_updater_distance:GetFloat()
        local rtxBounds = Vector(rtxDistance, rtxDistance, rtxDistance)
        ent:SetRenderBounds(-rtxBounds, rtxBounds)
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
        return
    end

    local lp = LocalPlayer()
    if not IsValid(lp) then return end
    
    -- Optimize distance calculation
    local entPos = ent:GetPos()
    local playerPos = lp:GetPos()
    local dx = entPos.x - playerPos.x
    local dy = entPos.y - playerPos.y
    local dz = entPos.z - playerPos.z
    local distance = (dx * dx + dy * dy + dz * dz) ^ 0.5
    
    local bounds = GetBoundsForDistance(distance)
    ent:SetRenderBounds(bounds.mins, bounds.maxs)
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

hook.Add("Think", "FR_DynamicBoundsUpdate", function()
    if not cv_enabled:GetBool() or not cv_dynamic_bounds:GetBool() then return end
    
    ENTITIES_PER_FRAME = cv_entities_per_frame:GetInt()
    ProcessQueuedEntities()
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
    UpdatePrecalculatedBounds()
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
    print("\nDynamic Bounds Info:")
    print("Dynamic Bounds Enabled:", cv_dynamic_bounds:GetBool())
    print("Entities Per Frame:", cv_entities_per_frame:GetInt())
    print("Update Interval:", cv_update_interval:GetFloat())
    print("Queued Entities:", #updateQueue)
    print("Distance Tiers:")
    print("\nDistance Tiers (from closest to farthest):")
    for i, tier in ipairs(DISTANCE_TIERS) do
        print(string.format("  Tier %d: <= %d units (scale: %.1fx) - %s",
            i,
            tier.distance,
            tier.scale,
            i == 1 and "Largest bounds" or
            i == #DISTANCE_TIERS and "Smallest bounds" or
            "Medium bounds"
        ))
    end
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

    -- Dynamic Bounds Settings
    panel:CheckBox("Enable Dynamic Distance-Based Bounds", "fr_dynamic_bounds")
    
    -- Entities Per Frame Slider
    local frameSlider = panel:NumSlider("Entities Per Frame", "fr_entities_per_frame", 1, 50, 0)
    frameSlider:SetTooltip("How many entities to update per frame (higher = faster updates but more performance impact)")
    
    -- Update Interval Slider
    local updateSlider = panel:NumSlider("Queue Update Interval", "fr_update_interval", 0.1, 1.0, 2)
    updateSlider:SetTooltip("How often to refresh the update queue (seconds)")

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