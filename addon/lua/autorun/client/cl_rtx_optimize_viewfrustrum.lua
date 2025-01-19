if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable large render bounds for all entities")
local cv_bounds_size = CreateClientConVar("fr_bounds_size", "8000", true, false, "Size of render bounds")

-- Cache the bounds vectors
local boundsSize = cv_bounds_size:GetFloat()
local mins = Vector(-boundsSize, -boundsSize, -boundsSize)
local maxs = Vector(boundsSize, boundsSize, boundsSize)

-- RTX Light Updater model list
local RTX_UPDATER_MODELS = {
    ["models/hunter/plates/plate.mdl"] = true,
    ["models/hunter/blocks/cube025x025x025.mdl"] = true
}

-- Cache for static props
local staticProps = {}

-- Helper function to identify RTX updaters
local function IsRTXUpdater(ent)
    if not IsValid(ent) then return false end
    local class = ent:GetClass()
    return class == "rtx_lightupdater" or 
           class == "rtx_lightupdatermanager" or 
           (ent:GetModel() and RTX_UPDATER_MODELS[ent:GetModel()])
end

-- Set bounds for a single entity
local function SetEntityBounds(ent)
    if not IsValid(ent) or not cv_enabled:GetBool() then return end
    
    -- Set larger bounds for RTX updaters
    if IsRTXUpdater(ent) then
        local rtxBoundsSize = Vector(16384, 16384, 16384)
        ent:SetRenderBounds(-rtxBoundsSize, rtxBoundsSize)
        ent:DisableMatrix("RenderMultiply")
        ent:SetNoDraw(false)
    else
        -- Regular entities get standard large bounds
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

    -- Create new static props
    if NikNaks and NikNaks.CurrentMap then
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

-- Hook for new entities
hook.Add("OnEntityCreated", "SetLargeRenderBounds", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if IsValid(ent) then
            SetEntityBounds(ent)
        end
    end)
end)

-- Initial setup
hook.Add("InitPostEntity", "InitialBoundsSetup", function()
    timer.Simple(1, function()
        -- Set bounds for all existing entities
        for _, ent in ipairs(ents.GetAll()) do
            SetEntityBounds(ent)
        end
        
        -- Create static props
        CreateStaticProps()
    end)
end)

-- Map cleanup/reload handler
hook.Add("OnReloaded", "RefreshStaticProps", function()
    -- Remove existing static props
    for _, prop in pairs(staticProps) do
        if IsValid(prop) then
            prop:Remove()
        end
    end
    staticProps = {}
    
    -- Recreate static props
    timer.Simple(1, CreateStaticProps)
end)

-- ConCommand to refresh all entities' bounds
concommand.Add("fr_refresh", function()
    if not cv_enabled:GetBool() then return end
    
    boundsSize = cv_bounds_size:GetFloat()
    mins = Vector(-boundsSize, -boundsSize, -boundsSize)
    maxs = Vector(boundsSize, boundsSize, boundsSize)
    
    -- Update regular entities
    for _, ent in ipairs(ents.GetAll()) do
        SetEntityBounds(ent)
    end
    
    -- Refresh static props
    CreateStaticProps()
    
    print("Refreshed render bounds for all entities and static props")
end)

-- Debug command
concommand.Add("fr_debug", function()
    print("\nRTX Frustum Optimization Debug:")
    print("Enabled:", cv_enabled:GetBool())
    print("Bounds Size:", cv_bounds_size:GetFloat())
    print("Static Props Count:", #staticProps)
    
    local rtxCount = 0
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and IsRTXUpdater(ent) then
            rtxCount = rtxCount + 1
        end
    end
    print("RTX Updaters:", rtxCount)
end)