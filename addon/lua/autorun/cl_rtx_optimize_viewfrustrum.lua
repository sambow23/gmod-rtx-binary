-- Optimize the view frustrum to work better with RTX Remix. This code is pretty heavy but it's the current solution we have until we get proper engine patches.
-- MAJOR THANK YOU to the creator of NikNaks, a lot of this would not be possible without it.

if not CLIENT then return end

-- ConVars
local cv_disable_culling = CreateClientConVar("disable_frustum_culling", "1", true, false, "Disable frustum culling")
local cv_bounds_size = CreateClientConVar("frustum_bounds_size", "10000", true, false, "Size of render bounds when culling is disabled (default: 1000)")
local cv_enable_pvs = CreateClientConVar("enable_pvs_culling", "1", true, false, "Enable PVS-based culling")
local cv_nearby_radius = CreateClientConVar("pvs_nearby_radius", "512", true, false, "Radius for nearby entity rendering")
local cv_update_rate = CreateClientConVar("pvs_update_rate", "0.25", true, false, "How often to update PVS data (in seconds)")
local cv_update_frequency = CreateClientConVar("frustum_update_frequency", "0.5", true, false, "How often to update moving entities (in seconds)")
local cv_process_batch_size = CreateClientConVar("frustum_batch_size", "50", true, false, "How many entities to process per frame when refreshing")
local cv_smart_radius = CreateClientConVar("pvs_smart_radius", "1", true, false, "Enable smart radius adjustment")
local cv_min_radius = CreateClientConVar("pvs_min_radius", "512", true, false, "Minimum radius for nearby entity rendering")
local cv_max_radius = CreateClientConVar("pvs_max_radius", "2048", true, false, "Maximum radius for nearby entity rendering")
local cv_view_distance = CreateClientConVar("pvs_view_distance", "2048", true, false, "How far to extend radius in view direction")
local cv_static_prop_enabled = CreateClientConVar("disable_frustum_culling_static_props", "1", true, false, "Include static props in frustum culling disable")
local cv_static_prop_distance = CreateClientConVar("frustum_static_prop_distance", "8000", true, false, "Maximum distance to process static props")
local cv_static_prop_batch = CreateClientConVar("frustum_static_prop_batch", "100", true, false, "How many static props to process per frame")
local cv_indoor_mode = CreateClientConVar("pvs_indoor_mode", "1", true, false, "Enable optimizations for indoor environments")
local cv_corridor_extend = CreateClientConVar("pvs_corridor_extend", "256", true, false, "How far to extend visibility in corridors")
local cv_flicker_prevention = CreateClientConVar("pvs_flicker_prevention", "1", true, false, "Prevent light/object flickering in corridors")
local cv_visibility_buffer = CreateClientConVar("pvs_visibility_buffer", "2", true, false, "Number of additional PVS clusters to keep visible")
local cv_light_render_distance = CreateClientConVar("frustum_light_distance", "2048", true, false, "Maximum distance to render lights")
local cv_light_updater_bounds = CreateClientConVar("frustum_light_updater_bounds", "16", true, false, "Size of render bounds for light updater entities")

local LIGHT_UPDATER_MODELS = {
    ["models/hunter/plates/plate.mdl"] = true,
    ["models/hunter/blocks/cube025x025x025.mdl"] = true
}

-- Function to check if the game is ready
local function IsGameReady()
    if not LocalPlayer then return false end
    local ply = LocalPlayer()
    return IsValid(ply) and ply:IsPlayer()
end

local function IsInRange(pos, range)
    if not LocalPlayer then return false end
    if not IsGameReady() then return false end
    local ply = LocalPlayer()
    if not IsValid(ply) then return false end
    local playerPos = ply:GetPos()
    if not playerPos then return false end
    return pos:DistToSqr(playerPos) <= (range * range)
end

-- Cache variables
local lastPVSUpdate = 0
local cachedPVS = nil
local cachedNearbyLeafs = nil
local currentLeaf = nil
local processing_queue = {}
local is_processing = false
local cached_bounds_size = cv_bounds_size:GetFloat()
local cached_mins = Vector(-cached_bounds_size, -cached_bounds_size, -cached_bounds_size)
local cached_maxs = Vector(cached_bounds_size, cached_bounds_size, cached_bounds_size)

-- Cache for environment analysis
local isOpenArea = false
local currentRadius = cv_min_radius:GetFloat()
local lastAreaCheck = 0
local AREA_CHECK_INTERVAL = 0.5

-- Cache for static props
local cached_static_props = {}
local static_prop_queue = {}
local is_processing_props = false
local last_distance_check = 0
local DISTANCE_CHECK_INTERVAL = 1 -- Check distances every second

-- Helper function to check for RTX light updater entities
local function IsRTXLightUpdater(ent)
    if not IsValid(ent) then return false end
    local class = ent:GetClass()
    return class == "rtx_lightupdater" or class == "rtx_lightupdatermanager"
end

-- Helper function to check if entity is a light
local function IsLight(ent)
    if not IsValid(ent) then return false end
    
    -- Check for light updater models
    local model = ent:GetModel()
    if model and LIGHT_UPDATER_MODELS[model] then
        return true
    end
    
    local class = ent:GetClass()
    return class == "light" or 
           class == "light_dynamic" or 
           class == "light_spot" or 
           class == "light_environment" or 
           class == "light_point" or
           string.find(class, "light") ~= nil
end


local function DrawDebugRadius()
    if not cv_enable_pvs:GetBool() then return end
    
    local ply = LocalPlayer()
    local pos = ply:GetPos()
    local radius = GetSmartRadius()
    
    -- Draw current radius
    render.DrawWireframeSphere(pos, radius, 32, 32, Color(0, 255, 0, 100))
    
    -- Draw view distance cone
    local viewDir = ply:GetAimVector()
    debugoverlay.Line(pos, pos + viewDir * cv_view_distance:GetFloat(), 0.1, Color(255, 255, 0))
end

if debug_draw_enabled then
    hook.Add("PostDrawTranslucentRenderables", "DebugVisibilityRadius", DrawDebugRadius)
end

-- Function to check if we're in an open area
local function IsInOpenArea()
    local bsp = NikNaks.CurrentMap
    if not bsp then return false end
    
    local ply = LocalPlayer()
    if not IsValid(ply) then return false end
    
    local pos = ply:GetPos()
    if not pos then return false end  -- Add position check
    
    local upTrace = util.TraceLine({
        start = pos,
        endpos = pos + Vector(0, 0, 1000),
        mask = MASK_SOLID
    })
    
    -- Ensure upTrace is valid
    if not upTrace then return false end
    
    local traces = {}
    local traceCount = 8
    for i = 1, traceCount do
        local ang = Angle(0, (i - 1) * (360 / traceCount), 0)
        local dir = ang:Forward()
        
        local tr = util.TraceLine({
            start = pos,
            endpos = pos + dir * 1000,
            mask = MASK_SOLID
        })
        
        -- Add null check for trace result
        if tr then
            table.insert(traces, tr.Fraction)
        else
            table.insert(traces, 0)  -- Use 0 as fallback if trace fails
        end
    end
    
    -- Guard against empty traces table
    if #traces == 0 then return false end
    
    -- Calculate average open space
    local avgSpace = 0
    for _, frac in ipairs(traces) do
        avgSpace = avgSpace + frac
    end
    avgSpace = avgSpace / #traces
    
    -- Consider it an open area if:
    -- 1. High ceiling (>500 units)
    -- 2. Average horizontal space >70%
    return upTrace.Fraction > 0.5 and avgSpace > 0.7
end

-- Function to get dynamic radius based on environment
local function GetSmartRadius()
    local bsp = NikNaks.CurrentMap
    if not bsp or not cv_smart_radius:GetBool() then
        return cv_nearby_radius:GetFloat()
    end
    
    -- Add player validity check
    local ply = LocalPlayer()
    if not IsValid(ply) then return cv_nearby_radius:GetFloat() end
    
    local curTime = CurTime()
    if curTime > lastAreaCheck + AREA_CHECK_INTERVAL then
        -- Add pcall to catch any errors in IsInOpenArea
        local success, result = pcall(IsInOpenArea)
        isOpenArea = success and result or false
        lastAreaCheck = curTime
        
        -- Smoothly adjust radius
        local targetRadius = isOpenArea and cv_max_radius:GetFloat() or cv_min_radius:GetFloat()
        currentRadius = Lerp(0.1, currentRadius, targetRadius)
    end
    
    return currentRadius
end

-- Function to detect if we're in a corridor
local function IsInCorridor()
    local ply = LocalPlayer()
    if not IsValid(ply) then return false end
    
    local pos = ply:GetPos()
    if not pos then return false end
    
    local traces = {}
    local traceCount = 4
    
    -- Check horizontal space in four directions
    for i = 1, traceCount do
        local ang = Angle(0, (i - 1) * (360 / traceCount), 0)
        local dir = ang:Forward()
        
        local tr = util.TraceLine({
            start = pos,
            endpos = pos + dir * 256,
            mask = MASK_SOLID
        })
        
        if tr then
            table.insert(traces, tr.Fraction)
        end
    end
    
    -- Calculate average space
    local avgSpace = 0
    for _, frac in ipairs(traces) do
        avgSpace = avgSpace + frac
    end
    avgSpace = avgSpace / #traces
    
    -- Consider it a corridor if average space is small but we have clear line of sight forward
    local forwardTrace = util.TraceLine({
        start = pos,
        endpos = pos + ply:GetAimVector() * 512,
        mask = MASK_SOLID
    })
    
    if not forwardTrace then return false end
    
    return avgSpace < 0.4 and forwardTrace.Fraction > 0.7
end

-- Helper function to update visibility data
local function UpdateVisibilityData()
    local bsp = NikNaks.CurrentMap
    if not bsp then return end
    
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    
    local pos = ply:GetPos()
    if not pos then return end

    -- Get current leaf with safety check
    local leaf = bsp:PointInLeaf(0, pos)
    if not leaf then return end
    currentLeaf = leaf
    
    if cv_enable_pvs:GetBool() then
        -- Get PVS data with safety check
        local pvs = bsp:PVSForOrigin(pos)
        if not pvs then return end
        cachedPVS = pvs

        -- If in indoor mode, handle corridors specially
        if cv_indoor_mode:GetBool() and IsInCorridor() then
            -- Extend PVS along corridor direction
            local viewDir = ply:GetAimVector()
            local extendDist = cv_corridor_extend:GetFloat()
            
            -- Get additional PVS clusters along the corridor
            for i = 1, cv_visibility_buffer:GetInt() do
                local extendedPos = pos + viewDir * (extendDist * i)
                local extendedPVS = bsp:PVSForOrigin(extendedPos)
                if extendedPVS then
                    -- Merge PVS data
                    for k, v in pairs(extendedPVS) do
                        if type(k) == "number" then
                            cachedPVS[k] = true
                        end
                    end
                end
            end
            
            -- If flicker prevention is enabled, add neighboring clusters
            if cv_flicker_prevention:GetBool() then
                local leaf = bsp:PointInLeaf(0, pos)
                if leaf and leaf.neighbors then
                    for _, neighborLeaf in ipairs(leaf.neighbors) do
                        if neighborLeaf.cluster then
                            cachedPVS[neighborLeaf.cluster] = true
                        end
                    end
                end
            end
        end

        -- Get PAS data with safety check
        local pas = bsp:PASForOrigin(pos)
        if pas then -- Only merge if PAS exists
            -- Merge PVS and PAS data
            for k, v in pairs(pas) do
                if type(k) == "number" then
                    cachedPVS[k] = true
                end
            end
        end
        
        -- Get nearby leafs with smart radius and safety check
        local radius = GetSmartRadius()
        local nearbyLeafs = bsp:SphereInLeafs(0, pos, radius)
        if not nearbyLeafs then return end
        cachedNearbyLeafs = nearbyLeafs
        
        -- Add leafs in view direction with safety check
        local viewDir = ply:GetAimVector()
        if viewDir then
            local viewLeafs = bsp:LineInLeafs(0, pos, pos + viewDir * cv_view_distance:GetFloat())
            if viewLeafs then
                for _, leaf in ipairs(viewLeafs) do
                    if leaf then
                        table.insert(cachedNearbyLeafs, leaf)
                    end
                end
            end
        end
    else
        cachedPVS = nil
        cachedNearbyLeafs = nil
    end
end

-- Helper function to check if entity should be rendered
local function ShouldRenderEntity(ent)
    if not cv_enable_pvs:GetBool() then return true end
    if not IsValid(ent) then return false end

    -- Always render light updater models
    local model = ent:GetModel()
    if model and LIGHT_UPDATER_MODELS[model] then
        return true
    end
    
    -- Always render light updater models and entities
    local model = ent:GetModel()
    if model and LIGHT_UPDATER_MODELS[model] or 
       ent:GetClass() == "rtx_lightupdater" or 
       ent:GetClass() == "rtx_lightupdatermanager" then
        return true
    end
    
    -- Rest of the existing visibility checks
    local bsp = NikNaks.CurrentMap
    if not bsp or not cachedPVS then return true end
    
    -- Always render if culling is disabled
    if not cv_disable_culling:GetBool() then return true end
    
    -- Get entity's leaf with safety check
    local entPos = ent:GetPos()
    if not entPos then return true end
    
    local entLeaf = bsp:PointInLeaf(0, entPos)
    if not entLeaf or not entLeaf.cluster then return true end
    
    -- Special handling for corridors
    if cv_indoor_mode:GetBool() and IsInCorridor() then
        local ply = LocalPlayer()
        if not IsValid(ply) then return true end
        
        local plyPos = ply:GetPos()
        if not plyPos then return true end
        
        local viewDir = ply:GetAimVector()
        if not viewDir then return true end
        
        -- Check if entity is in the general direction we're looking
        local toEnt = (entPos - plyPos):GetNormalized()
        local dotProduct = viewDir:Dot(toEnt)
        
        -- More lenient dot product check in corridors
        if dotProduct > -0.7 then
            return true
        end
    end
    
    -- Always render entities in PVS
    if cachedPVS[entLeaf.cluster] then return true end
    
    -- Check if in nearby leafs
    if cachedNearbyLeafs then
        for _, leaf in ipairs(cachedNearbyLeafs) do
            if leaf and entLeaf and leaf:GetIndex() == entLeaf:GetIndex() then
                -- If in open area, check if entity is behind player
                if isOpenArea then
                    local ply = LocalPlayer()
                    if not IsValid(ply) then return true end
                    
                    local plyPos = ply:GetPos()
                    if not plyPos then return true end
                    
                    local toEnt = (entPos - plyPos):GetNormalized()
                    local viewDir = ply:GetAimVector()
                    if not viewDir then return true end
                    
                    local dotProduct = viewDir:Dot(toEnt)
                    
                    -- Render if entity is in front of player or close enough
                    return dotProduct > -0.5 or plyPos:DistToSqr(entPos) < (cv_min_radius:GetFloat() ^ 2)
                end
                return true
            end
        end
    end
    
    return false
end

local function SetHugeRenderBounds(ent)
    if not IsValid(ent) then return end
    if not ent.SetRenderBounds then return end
    
    -- Only set bounds for visible entities
    if ent:GetNoDraw() then return end
    
    -- Special handling for RTX light updaters
    if IsRTXLightUpdater(ent) then
        local bounds_size = cv_light_updater_bounds:GetFloat()
        local bounds = Vector(bounds_size, bounds_size, bounds_size)
        ent:SetRenderBounds(-bounds, bounds)
        return
    end
    
    -- Special handling for light updater models and entities
    local model = ent:GetModel()
    if model and LIGHT_UPDATER_MODELS[model] or 
       ent:GetClass() == "rtx_lightupdater" or 
       ent:GetClass() == "rtx_lightupdatermanager" then
        -- Use extremely large bounds for light updaters
        local huge_bounds = Vector(16384, 16384, 16384)  -- Maximum possible size
        ent:SetRenderBounds(-huge_bounds, huge_bounds)
        -- Force disable culling for these entities
        ent:DisableMatrix("RenderMultiply") -- Reset any render transformations
        ent:SetNoDraw(false) -- Ensure drawing is enabled
        return
    end
    
    -- Handle regular lights
    if IsLight(ent) then
        local light_distance = cv_light_render_distance:GetFloat()
        local light_bounds = Vector(light_distance, light_distance, light_distance)
        ent:SetRenderBounds(-light_bounds, light_bounds)
        return
    end
    
    -- Skip static props if disabled
    if ent.IsStaticProp and not cv_static_prop_enabled:GetBool() then return end
    
    -- Check if entity is renderable (has a model)
    local model = ent:GetModel()
    if not model or model == "" then return end
    
    -- Update visibility data if needed
    local curTime = CurTime()
    if curTime > lastPVSUpdate + cv_update_rate:GetFloat() then
        UpdateVisibilityData()
        lastPVSUpdate = curTime
    end
    
    -- Set huge bounds if entity should be rendered
    if ShouldRenderEntity(ent) then
        if ent.IsStaticProp then
            -- Use model-based bounds for static props
            local mins, maxs = ent:GetModelBounds()
            if mins and maxs then
                local bounds_size = cv_bounds_size:GetFloat()
                mins = mins * bounds_size
                maxs = maxs * bounds_size
                ent:SetRenderBounds(mins, maxs)
            end
        else
            -- Use standard huge bounds for regular entities
            local bounds_size = cv_bounds_size:GetFloat()
            local mins = Vector(-bounds_size, -bounds_size, -bounds_size)
            local maxs = Vector(bounds_size, bounds_size, bounds_size)
            ent:SetRenderBounds(mins, maxs)
        end
    else
        -- Set minimal bounds if entity shouldn't be rendered
        ent:SetRenderBounds(Vector(-1, -1, -1), Vector(1, 1, 1))
    end
end

local function ProcessStaticPropBatch()
    if #static_prop_queue == 0 then
        is_processing_props = false
        return
    end
    
    local batch_size = math.min(cv_static_prop_batch:GetInt(), #static_prop_queue)
    local range = cv_static_prop_distance:GetFloat()
    local playerPos = LocalPlayer():GetPos()
    
    for i = 1, batch_size do
        local prop = table.remove(static_prop_queue, 1)
        if not prop.OriginalStaticProp then continue end
        
        -- Only process props within range
        if IsInRange(prop.OriginalStaticProp:GetPos(), range) then
            SetHugeRenderBounds(prop)
        end
    end
    
    if #static_prop_queue > 0 then
        timer.Simple(0, ProcessStaticPropBatch)
    else
        is_processing_props = false
    end
end

local function CreateStaticPropEntity(staticProp)
    -- Skip props that are too far
    if not IsInRange(staticProp:GetPos(), cv_static_prop_distance:GetFloat()) then
        return
    end

    local ent = ClientsideModel(staticProp:GetModel())
    if not IsValid(ent) then return end
    
    ent:SetPos(staticProp:GetPos())
    ent:SetAngles(staticProp:GetAngles())
    ent:SetModelScale(staticProp:GetScale())
    ent:SetColor(staticProp:GetColor())
    ent:SetRenderMode(RENDERMODE_NORMAL)
    
    -- Store minimal required data
    ent.IsStaticProp = true
    ent.OriginalStaticProp = {
        GetPos = function() return staticProp:GetPos() end,
        GetModel = function() return staticProp:GetModel() end
    }
    
    return ent
end

-- Function to initialize static props
local function InitializeStaticProps()
    -- Check if LocalPlayer function exists
    if not LocalPlayer then
        timer.Create("RetryInitializeStaticProps", 1, 1, InitializeStaticProps)
        return
    end

    -- Check if game is ready
    if not IsGameReady() then
        timer.Create("RetryInitializeStaticProps", 1, 1, InitializeStaticProps)
        return
    end

    if not NikNaks or not NikNaks.CurrentMap then 
        timer.Create("RetryInitializeStaticProps", 1, 1, InitializeStaticProps)
        return 
    end
    
    -- Clear existing props
    for _, ent in pairs(cached_static_props) do
        if IsValid(ent) then ent:Remove() end
    end
    cached_static_props = {}
    static_prop_queue = {}
    
    -- Create props within range
    local range = cv_static_prop_distance:GetFloat()
    local playerPos = LocalPlayer():GetPos()
    
    for _, staticProp in pairs(NikNaks.CurrentMap:GetStaticProps()) do
        if IsInRange(staticProp:GetPos(), range) then
            local ent = CreateStaticPropEntity(staticProp)
            if IsValid(ent) then
                table.insert(cached_static_props, ent)
            end
        end
    end
end

-- Batch processing function
local function ProcessBatch()
    if #processing_queue == 0 then
        is_processing = false
        return
    end
    
    local batch_size = math.min(cv_process_batch_size:GetInt(), #processing_queue)
    
    for i = 1, batch_size do
        local ent = table.remove(processing_queue, 1)
        if IsValid(ent) then
            -- Add pcall to catch any errors in SetHugeRenderBounds
            pcall(SetHugeRenderBounds, ent)
        end
    end
    
    if #processing_queue > 0 then
        -- Use CreateTimer instead of timer.Simple for better error handling
        timer.Create("ProcessBatchTimer", 0, 1, ProcessBatch)
    else
        is_processing = false
    end
end

-- Function to queue entities for processing
local function QueueEntitiesForProcessing(entities)
    for _, ent in ipairs(entities) do
        table.insert(processing_queue, ent)
    end
    
    if not is_processing then
        is_processing = true
        ProcessBatch()
    end
end

-- Hook entity spawn
hook.Add("OnEntityCreated", "SetHugeRenderBounds", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if IsValid(ent) then
            SetHugeRenderBounds(ent)
        end
    end)
end)

-- Add command to toggle
concommand.Add("toggle_frustum_culling", function()
    cv_disable_culling:SetBool(not cv_disable_culling:GetBool())
    print("Frustum culling: " .. (cv_disable_culling:GetBool() and "DISABLED" or "ENABLED"))
end)

-- Add command to adjust bounds size
concommand.Add("set_frustum_bounds", function(ply, cmd, args)
    if not args[1] then 
        print("Current bounds size: " .. cv_bounds_size:GetFloat())
        return
    end
    
    local new_size = tonumber(args[1])
    if not new_size then
        print("Invalid size value. Please use a number.")
        return
    end
    
    cv_bounds_size:SetFloat(new_size)
    print("Set frustum bounds size to: " .. new_size)
    
    -- Queue all entities for processing
    QueueEntitiesForProcessing(ents.GetAll())
end)

-- Update cached vectors when bounds size changes
cvars.AddChangeCallback("frustum_bounds_size", function(name, old, new)
    cached_bounds_size = cv_bounds_size:GetFloat()
    cached_mins = Vector(-cached_bounds_size, -cached_bounds_size, -cached_bounds_size)
    cached_maxs = Vector(cached_bounds_size, cached_bounds_size, cached_bounds_size)
    
    -- Queue all entities for processing
    QueueEntitiesForProcessing(ents.GetAll())
end)

-- Monitor other convar changes
cvars.AddChangeCallback("disable_frustum_culling", function(name, old, new)
    QueueEntitiesForProcessing(ents.GetAll())
end)

-- Optimized think hook with timer-based updates
local next_update = 0
hook.Add("Think", "UpdateRenderBounds", function()
    if not LocalPlayer then return end
    if not IsGameReady() then return end
    if not cv_disable_culling:GetBool() then return end
    
    local curTime = CurTime()
    if curTime < next_update then return end
    
    next_update = curTime + cv_update_frequency:GetFloat()
    
    -- Process RTX light updaters first
    for _, ent in ipairs(ents.FindByClass("rtx_lightupdater*")) do
        if IsValid(ent) then
            SetHugeRenderBounds(ent)
        end
    end
    
    -- Process regular lights
    for _, ent in ipairs(ents.FindByClass("light*")) do
        if IsValid(ent) and not IsRTXLightUpdater(ent) then
            SetHugeRenderBounds(ent)
        end
    end
    
    -- Process dynamic entities
    local dynamic_entities = {}
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and 
           not IsLight(ent) and  -- Skip lights as they're handled separately
           not IsRTXLightUpdater(ent) and -- Skip RTX light updaters
           ent:GetMoveType() != MOVETYPE_NONE and
           ent:GetBoneCount() and ent:GetBoneCount() > 0 then
            table.insert(dynamic_entities, ent)
        end
    end
    
    -- Process static props periodically
    if cv_static_prop_enabled:GetBool() and curTime > last_distance_check + DISTANCE_CHECK_INTERVAL then
        last_distance_check = curTime
        static_prop_queue = table.Copy(cached_static_props)
        
        if not is_processing_props and #static_prop_queue > 0 then
            is_processing_props = true
            ProcessStaticPropBatch()
        end
    end
    
    QueueEntitiesForProcessing(dynamic_entities)
end)

-- Hook to catch entity spawns immediately
hook.Add("OnEntityCreated", "SetupLightUpdaters", function(ent)
    if not IsValid(ent) then return end
    
    -- Immediate check for light updater
    local model = ent:GetModel()
    if model and LIGHT_UPDATER_MODELS[model] or 
       ent:GetClass() == "rtx_lightupdater" or 
       ent:GetClass() == "rtx_lightupdatermanager" then
        
        -- Set huge bounds immediately and on next frame
        local huge_bounds = Vector(16384, 16384, 16384)
        ent:SetRenderBounds(-huge_bounds, huge_bounds)
        
        -- Also set them again next frame to ensure they stick
        timer.Simple(0, function()
            if IsValid(ent) then
                ent:SetRenderBounds(-huge_bounds, huge_bounds)
                ent:DisableMatrix("RenderMultiply")
                ent:SetNoDraw(false)
            end
        end)
    end
end)

-- Think hook specifically for light updaters
hook.Add("Think", "UpdateLightUpdaters", function()
    -- Update light updater entities every frame
    for _, ent in ipairs(ents.FindByClass("rtx_lightupdater")) do
        if IsValid(ent) then
            local huge_bounds = Vector(16384, 16384, 16384)
            ent:SetRenderBounds(-huge_bounds, huge_bounds)
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        end
    end
    
    for _, ent in ipairs(ents.FindByClass("rtx_lightupdatermanager")) do
        if IsValid(ent) then
            local huge_bounds = Vector(16384, 16384, 16384)
            ent:SetRenderBounds(-huge_bounds, huge_bounds)
            ent:DisableMatrix("RenderMultiply")
            ent:SetNoDraw(false)
        end
    end
end)

-- Force override the entity's Draw function
hook.Add("InitPostEntity", "SetupLightUpdaterOverrides", function()
    local lightupdater = scripted_ents.GetStored("rtx_lightupdater")
    if lightupdater and lightupdater.t then
        local oldDraw = lightupdater.t.Draw
        lightupdater.t.Draw = function(self)
            local huge_bounds = Vector(16384, 16384, 16384)
            self:SetRenderBounds(-huge_bounds, huge_bounds)
            if oldDraw then
                oldDraw(self)
            else
                self:DrawModel()
            end
        end
    end
    
    local manager = scripted_ents.GetStored("rtx_lightupdatermanager")
    if manager and manager.t then
        local oldDraw = manager.t.Draw
        manager.t.Draw = function(self)
            local huge_bounds = Vector(16384, 16384, 16384)
            self:SetRenderBounds(-huge_bounds, huge_bounds)
            if oldDraw then
                oldDraw(self)
            else
                self:DrawModel()
            end
        end
    end
end)

hook.Add("InitPostEntity", "InitializeStaticProps", function()
    -- Delay the initialization to ensure everything is loaded
    timer.Create("InitializeStaticPropsDelay", 2, 1, function()
        if not LocalPlayer then return end
        InitializeStaticProps()
    end)
    
    -- Setup original render bounds override
    local meta = FindMetaTable("Entity")
    if not meta then return end
    
    local originalSetupBones = meta.SetupBones
    if originalSetupBones then
        function meta:SetupBones()
            if cv_disable_culling:GetBool() and (self:GetBoneCount() and self:GetBoneCount() > 0 or self.IsStaticProp) then
                SetHugeRenderBounds(self)
            end
            return originalSetupBones(self)
        end
    end
end)

-- Hook to reinitialize when the player spawns
hook.Add("PlayerSpawn", "ReinitializeStaticProps", function(ply)
    if not LocalPlayer then return end
    if ply == LocalPlayer() then
        timer.Create("ReinitializeStaticPropsDelay", 1, 1, InitializeStaticProps)
    end
end)

-- Add safety check for map changes
hook.Add("OnReloaded", "RefreshStaticProps", function()
    if IsGameReady() then
        InitializeStaticProps()
    end
end)

-- Optimized bone setup hook
hook.Add("InitPostEntity", "SetupRenderBoundsOverride", function()
    local meta = FindMetaTable("Entity")
    if not meta then return end
    
    -- Store original function if it exists
    local originalSetupBones = meta.SetupBones
    if originalSetupBones then
        function meta:SetupBones()
            if cv_disable_culling:GetBool() and self:GetBoneCount() and self:GetBoneCount() > 0 then
                SetHugeRenderBounds(self)
            end
            return originalSetupBones(self)
        end
    end
end)

hook.Add("OnEntityCreated", "HandleRTXLightUpdaters", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if IsValid(ent) and IsRTXLightUpdater(ent) then
            SetHugeRenderBounds(ent)
        end
    end)
end)

-- Add command to refresh static props
concommand.Add("refresh_static_props", function()
    InitializeStaticProps()
    print("Static props refreshed")
end)

-- Update static props when map changes
hook.Add("OnReloaded", "RefreshStaticProps", InitializeStaticProps)

-- Debug command to print entity info
concommand.Add("debug_render_bounds", function()
    print("\nEntity Render Bounds Debug:")
    print("Current bounds size: " .. cv_bounds_size:GetFloat())
    print("Update frequency: " .. cv_update_frequency:GetFloat() .. " seconds")
    print("Batch size: " .. cv_process_batch_size:GetInt() .. " entities")
    print("Queue size: " .. #processing_queue .. " entities")
    print("\nEntity Details:")
    
    local total_entities = 0
    local processed_entities = 0
    local bone_entities = 0
    
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent.SetRenderBounds then
            total_entities = total_entities + 1
            local model = ent:GetModel() or "no model"
            local class = ent:GetClass()
            local pos = ent:GetPos()
            local has_bones = ent:GetBoneCount() and ent:GetBoneCount() > 0
            
            -- Check if entity is being processed (within distance)
            local should_process = false
            for _, ply in ipairs(player.GetAll()) do
                if ply:GetPos():DistToSqr(pos) <= 20000 * 20000 then
                    should_process = true
                    processed_entities = processed_entities + 1
                    break
                end
            end
            
            if has_bones then
                bone_entities = bone_entities + 1
            end
            
            print(string.format("Entity %s (Model: %s) - Distance processed: %s, Has bones: %s",
                class, model, should_process and "Yes" or "No", has_bones and "Yes" or "No"))
        end
    end
    
    print("\nStatistics:")
    print("Total entities: " .. total_entities)
    print("Entities in range: " .. processed_entities)
    print("Entities with bones: " .. bone_entities)
end)

concommand.Add("debug_static_props", function()
    print("\nStatic Props Debug Info:")
    print("Total cached props: " .. #cached_static_props)
    print("Props in process queue: " .. #static_prop_queue)
    print("Processing enabled: " .. tostring(cv_static_prop_enabled:GetBool()))
    print("Max process distance: " .. cv_static_prop_distance:GetFloat())
    print("Batch size: " .. cv_static_prop_batch:GetInt())
    
    local propsInRange = 0
    local range = cv_static_prop_distance:GetFloat()
    for _, prop in pairs(cached_static_props) do
        if IsValid(prop) and IsInRange(prop:GetPos(), range) then
            propsInRange = propsInRange + 1
        end
    end
    print("Props in range: " .. propsInRange)
end)

concommand.Add("set_light_render_distance", function(ply, cmd, args)
    if not args[1] then 
        print("Current light render distance: " .. cv_light_render_distance:GetFloat())
        return
    end
    
    local new_size = tonumber(args[1])
    if not new_size then
        print("Invalid distance value. Please use a number.")
        return
    end
    
    cv_light_render_distance:SetFloat(new_size)
    print("Set light render distance to: " .. new_size)
    
    -- Update all lights
    for _, ent in ipairs(ents.FindByClass("light*")) do
        if IsValid(ent) then
            SetHugeRenderBounds(ent)
        end
    end
end)