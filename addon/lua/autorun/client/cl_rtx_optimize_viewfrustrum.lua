if not CLIENT then return end

-- ConVars
local cv_disable_culling = CreateClientConVar("fr_disable", "1", true, false, "Disable frustum culling")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "2048", true, false, "Size of render bounds when culling is disabled")
local cv_update_frequency = CreateClientConVar("fr_update_frequency", "0.5", true, false, "How often to update entities")
local cv_batch_size = CreateClientConVar("fr_batch_size", "50", true, false, "How many entities to process per frame")

-- Cache system
local Cache = {
    processQueue = {},
    isProcessing = false,
    lastUpdate = 0,
    boundsSize = cv_bounds_size:GetFloat(),
    mins = Vector(-cv_bounds_size:GetFloat(), -cv_bounds_size:GetFloat(), -cv_bounds_size:GetFloat()),
    maxs = Vector(cv_bounds_size:GetFloat(), cv_bounds_size:GetFloat(), cv_bounds_size:GetFloat()),
    boundUpdateTimes = {},
    boundUpdateStates = {},
    nextBoundUpdate = 0,
    updateInterval = 0.1,
    distanceThresholds = {
        {dist = 1000, interval = 0.1},
        {dist = 2000, interval = 0.25},
        {dist = 4000, interval = 0.5},
        {dist = 8000, interval = 1.0},
        {dist = 16000, interval = 2.0}
    }
}

-- Helper functions
local function IsGameReady()
    return LocalPlayer() and IsValid(LocalPlayer())
end

local function ShouldUpdateBounds(ent)
    if not IsValid(ent) then return false end
    
    local curTime = CurTime()
    
    -- Global throttle check
    if curTime < Cache.nextBoundUpdate then return false end
    
    -- Check entity's last update time
    local lastUpdate = Cache.boundUpdateTimes[ent] or 0
    local playerPos = LocalPlayer():GetPos()
    local entPos = ent:GetPos()
    local distance = playerPos:Distance(entPos)
    
    -- Determine update interval based on distance
    local updateInterval = Cache.updateInterval
    for _, threshold in ipairs(Cache.distanceThresholds) do
        if distance > threshold.dist then
            updateInterval = threshold.interval
        else
            break
        end
    end
    
    -- Check if enough time has passed for this entity
    return curTime - lastUpdate >= updateInterval
end

local function ShouldHandleEntity(ent)
    if not IsValid(ent) then return false end
    
    local class = ent:GetClass()
    return class == "prop_physics" or class == "hdri_cube_editor"
end

-- Entity Bounds Management
local function SetEntityBounds(ent)
    if not IsValid(ent) or not cv_disable_culling:GetBool() then return end
    
    -- Only update if necessary
    if not ShouldUpdateBounds(ent) then return end
    
    -- Regular entities
    local currentState = Cache.boundUpdateStates[ent]
    local newState = tostring(Cache.mins) .. tostring(Cache.maxs)
    
    if currentState ~= newState then
        ent:SetRenderBounds(Cache.mins, Cache.maxs)
        Cache.boundUpdateStates[ent] = newState
    end
    
    -- Update the last update time
    Cache.boundUpdateTimes[ent] = CurTime()
    Cache.nextBoundUpdate = CurTime() + 0.016 -- Limit to roughly once per frame maximum
end

-- Batch processing
local function ProcessBatch()
    if #Cache.processQueue == 0 then
        Cache.isProcessing = false
        return
    end
    
    local batchSize = math.min(cv_batch_size:GetInt(), #Cache.processQueue)
    local processed = 0
    local startTime = SysTime()
    
    while processed < batchSize and (SysTime() - startTime) < 0.002 do
        local ent = table.remove(Cache.processQueue, 1)
        if IsValid(ent) then
            SetEntityBounds(ent)
            processed = processed + 1
        end
    end
    
    if #Cache.processQueue > 0 then
        timer.Simple(0, ProcessBatch)
    else
        Cache.isProcessing = false
    end
end

local function QueueEntities()
    if not IsGameReady() then return end
    
    table.Empty(Cache.processQueue)
    
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ShouldHandleEntity(ent) then
            table.insert(Cache.processQueue, ent)
        end
    end
    
    if not Cache.isProcessing and #Cache.processQueue > 0 then
        Cache.isProcessing = true
        ProcessBatch()
    end
end

local function UpdateCacheSettings()
    Cache.boundsSize = cv_bounds_size:GetFloat()
    Cache.mins = Vector(-Cache.boundsSize, -Cache.boundsSize, -Cache.boundsSize)
    Cache.maxs = Vector(Cache.boundsSize, Cache.boundsSize, Cache.boundsSize)
    
    -- Clear caches to force updates
    Cache.boundUpdateTimes = {}
    Cache.boundUpdateStates = {}
    Cache.nextBoundUpdate = 0
    Cache.lastUpdate = 0
    
    -- Force a full refresh
    if IsGameReady() then
        QueueEntities()
    end
end

-- Hooks
hook.Add("Think", "UpdateRenderBounds", function()
    if not cv_disable_culling:GetBool() then return end
    if not IsGameReady() then return end
    
    local curTime = CurTime()
    if curTime < Cache.lastUpdate + cv_update_frequency:GetFloat() then return end
    
    Cache.lastUpdate = curTime
    QueueEntities()
end)

hook.Add("OnEntityCreated", "HandleNewEntity", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if IsValid(ent) and ShouldHandleEntity(ent) then
            SetEntityBounds(ent)
        end
    end)
end)

hook.Add("EntityRemoved", "CleanupBoundsCache", function(ent)
    Cache.boundUpdateTimes[ent] = nil
    Cache.boundUpdateStates[ent] = nil
end)

cvars.AddChangeCallback("fr_bounds_size", UpdateCacheSettings)
cvars.AddChangeCallback("fr_disable", UpdateCacheSettings)
cvars.AddChangeCallback("fr_update_frequency", function(convar, old, new)
    Cache.lastUpdate = 0 -- Force next update
end)
cvars.AddChangeCallback("fr_batch_size", function(convar, old, new)
    Cache.processQueue = {} -- Reset process queue
    Cache.isProcessing = false
    QueueEntities() -- Restart queue processing
end)

-- Debug command
concommand.Add("fr_debug", function()
    print("\nFrustum Optimization Debug:")
    print("Culling Disabled:", cv_disable_culling:GetBool())
    print("Bounds Size:", cv_bounds_size:GetFloat())
    print("Update Frequency:", cv_update_frequency:GetFloat())
    print("\nCurrent State:")
    print("Queue Size:", #Cache.processQueue)
    print("Is Processing:", Cache.isProcessing)
    
    local handledCount = 0
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ShouldHandleEntity(ent) then
            handledCount = handledCount + 1
        end
    end
    print("Handled Entities:", handledCount)
end)