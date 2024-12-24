-- RTX Light Queue System
local RTXUpdateQueue = {
    queue = {},
    processing = false,
    maxUpdatesPerFrame = 5,
    minTimeBetweenUpdates = 0.05,
    defaultPriority = 1
}

-- Performance monitoring
local performanceMetrics = {
    updateTimes = {},
    avgUpdateTime = 0,
    lastAdjustment = 0,
    adjustmentInterval = 1 -- Adjust settings every second
}

function RTXUpdateQueue:Add(light, properties, priority)
    if not IsValid(light) then return end
    
    priority = priority or self.defaultPriority

    -- Check for existing update
    for i, update in ipairs(self.queue) do
        if update.light == light then
            -- Merge properties and take highest priority
            table.Merge(update.properties, properties)
            update.priority = math.max(update.priority, priority)
            return
        end
    end

    -- Create new update
    local update = {
        light = light,
        properties = properties,
        priority = priority,
        lastUpdate = 0,
        addedTime = CurTime()
    }

    -- Insert sorted by priority
    local inserted = false
    for i, existing in ipairs(self.queue) do
        if existing.priority < priority then
            table.insert(self.queue, i, update)
            inserted = true
            break
        end
    end
    
    if not inserted then
        table.insert(self.queue, update)
    end
end

function RTXUpdateQueue:Process()
    if #self.queue == 0 then return end
    
    local startTime = SysTime()
    local currentTime = CurTime()
    local updatesThisFrame = 0

    -- Process queue from highest to lowest priority
    for i = #self.queue, 1, -1 do
        if updatesThisFrame >= self.maxUpdatesPerFrame then break end
        
        local update = self.queue[i]
        if not IsValid(update.light) then
            table.remove(self.queue, i)
            continue
        end

        -- Check update timing
        if currentTime - update.lastUpdate < self.minTimeBetweenUpdates then
            continue
        end

        -- Apply update
        if update.light.rtxLightHandle then
            local pos = update.light:GetPos()
            local success = pcall(function()
                update.light.rtxLightHandle = UpdateRTXLight(
                    update.light.rtxLightHandle,
                    pos.x, pos.y, pos.z,
                    update.properties.size or update.light:GetLightSize(),
                    update.properties.brightness or update.light:GetLightBrightness(),
                    (update.properties.r or update.light:GetLightR()) / 255,
                    (update.properties.g or update.light:GetLightG()) / 255,
                    (update.properties.b or update.light:GetLightB()) / 255
                )
            end)

            if success then
                table.remove(self.queue, i)
                updatesThisFrame = updatesThisFrame + 1
            end
        else
            table.remove(self.queue, i)
        end
    end

    -- Update performance metrics
    local updateTime = SysTime() - startTime
    table.insert(performanceMetrics.updateTimes, updateTime)
    if #performanceMetrics.updateTimes > 100 then
        table.remove(performanceMetrics.updateTimes, 1)
    end

    -- Adjust performance settings periodically
    if currentTime - performanceMetrics.lastAdjustment > performanceMetrics.adjustmentInterval then
        self:AdjustPerformance()
        performanceMetrics.lastAdjustment = currentTime
    end
end

function RTXUpdateQueue:AdjustPerformance()
    -- Calculate moving average
    local sum = 0
    for _, time in ipairs(performanceMetrics.updateTimes) do
        sum = sum + time
    end
    performanceMetrics.avgUpdateTime = sum / #performanceMetrics.updateTimes

    -- Adjust settings based on performance
    if performanceMetrics.avgUpdateTime > 0.016 then -- Taking too long
        self.maxUpdatesPerFrame = math.max(1, self.maxUpdatesPerFrame - 1)
    elseif performanceMetrics.avgUpdateTime < 0.008 then -- Room for more
        self.maxUpdatesPerFrame = math.min(10, self.maxUpdatesPerFrame + 1)
    end

    -- Debug info
    if GetConVar("developer"):GetBool() then
        print(string.format("[RTX Queue] Avg update time: %.3fms, Updates per frame: %d, Queue size: %d",
            performanceMetrics.avgUpdateTime * 1000,
            self.maxUpdatesPerFrame,
            #self.queue
        ))
    end
end

-- Create ConVars for configuration
CreateConVar("rtx_queue_updates_per_frame", "5", FCVAR_ARCHIVE, "Maximum RTX light updates per frame")
CreateConVar("rtx_queue_update_interval", "0.05", FCVAR_ARCHIVE, "Minimum time between updates for the same light")

-- Hook into the think system
hook.Add("Think", "RTXUpdateQueue_Process", function()
    -- Update settings from ConVars
    RTXUpdateQueue.maxUpdatesPerFrame = GetConVar("rtx_queue_updates_per_frame"):GetInt()
    RTXUpdateQueue.minTimeBetweenUpdates = GetConVar("rtx_queue_update_interval"):GetFloat()
    
    RTXUpdateQueue:Process()
end)

return RTXUpdateQueue