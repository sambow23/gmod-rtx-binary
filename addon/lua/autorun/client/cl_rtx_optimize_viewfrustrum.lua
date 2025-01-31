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
local DEBOUNCE_TIME = 0.1
local boundsUpdateTimer = "FR_BoundsUpdate"
local rtxUpdateTimer = "FR_RTXUpdate"
local rtxUpdaterCache = {}
local rtxUpdaterCount = 0
local UPDATE_BATCH_SIZE = 100 
local updateQueue = {}
local isProcessingQueue = false

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

-- Separate regular lights from environment lights
local REGULAR_LIGHT_TYPES = {
    [LIGHT_TYPES.POINT] = true,
    [LIGHT_TYPES.SPOT] = true,
    [LIGHT_TYPES.DYNAMIC] = true
}

-- Add this function to handle batched updates
local function ProcessUpdateQueue()
    if #updateQueue == 0 then
        isProcessingQueue = false
        return
    end

    local processCount = 0
    local i = 1
    
    while i <= #updateQueue and processCount < UPDATE_BATCH_SIZE do
        local ent = updateQueue[i]
        if IsValid(ent) then
            SetEntityBounds(ent, not cv_enabled:GetBool())
            processCount = processCount + 1
        end
        table.remove(updateQueue, i)
    end

    if #updateQueue > 0 then
        -- Schedule next batch for next frame
        timer.Simple(0, ProcessUpdateQueue)
    else
        isProcessingQueue = false
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
    -- Clear existing queue and processing
    updateQueue = {}
    
    -- Queue all entities for update
    for _, ent in ipairs(ents.GetAll()) do
        table.insert(updateQueue, ent)
    end

    -- Start processing if not already running
    if not isProcessingQueue then
        isProcessingQueue = true
        ProcessUpdateQueue()
    end
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
        
        -- Queue RTX updaters for update
        updateQueue = {}
        for ent in pairs(rtxUpdaterCache) do
            if IsValid(ent) and REGULAR_LIGHT_TYPES[ent.lightType] then
                table.insert(updateQueue, ent)
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