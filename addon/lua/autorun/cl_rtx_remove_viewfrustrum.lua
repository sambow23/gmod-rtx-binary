local cv_disable_culling = CreateClientConVar("disable_frustum_culling", "1", true, false, "Disable frustum culling")
local cv_bounds_size = CreateClientConVar("frustum_bounds_size", "10000", true, false, "Size of render bounds when culling is disabled (default: 1000)")

-- Helper function to safely set render bounds
local function SetHugeRenderBounds(ent)
    if not IsValid(ent) then return end
    if not ent.SetRenderBounds then return end
    
    -- Only set bounds for visible entities
    if ent:GetNoDraw() then return end
    
    -- Check if entity is renderable (has a model)
    local model = ent:GetModel()
    if not model or model == "" then return end
    
    local bounds_size = cv_bounds_size:GetFloat()
    local mins = Vector(-bounds_size, -bounds_size, -bounds_size)
    local maxs = Vector(bounds_size, bounds_size, bounds_size)
    
    ent:SetRenderBounds(mins, maxs)
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
    
    -- Force refresh of all entity bounds
    for _, ent in ipairs(ents.GetAll()) do
        SetHugeRenderBounds(ent)
    end
end)

-- Monitor convar changes
cvars.AddChangeCallback("disable_frustum_culling", function(name, old, new)
    -- Force refresh of all entity bounds
    for _, ent in ipairs(ents.GetAll()) do
        SetHugeRenderBounds(ent)
    end
end)

cvars.AddChangeCallback("frustum_bounds_size", function(name, old, new)
    -- Force refresh of all entity bounds
    for _, ent in ipairs(ents.GetAll()) do
        SetHugeRenderBounds(ent)
    end
end)

-- Hook think to continuously update bounds
hook.Add("Think", "UpdateRenderBounds", function()
    if not cv_disable_culling:GetBool() then return end
    
    -- Update bounds periodically for dynamic entities
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent:GetMoveType() != MOVETYPE_NONE then
            SetHugeRenderBounds(ent)
        end
    end
end)

-- Hook entity setup
hook.Add("InitPostEntity", "SetupRenderBoundsOverride", function()
    local meta = FindMetaTable("Entity")
    if not meta then return end
    
    -- Store original function if it exists
    local originalSetupBones = meta.SetupBones
    if originalSetupBones then
        function meta:SetupBones()
            if cv_disable_culling:GetBool() then
                SetHugeRenderBounds(self)
            end
            return originalSetupBones(self)
        end
    end
end)

-- Debug command to print entity info (removed duplicate declaration)
concommand.Add("debug_render_bounds", function()
    print("\nEntity Render Bounds Debug:")
    print("Current bounds size: " .. cv_bounds_size:GetFloat())
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent.SetRenderBounds then
            local model = ent:GetModel() or "no model"
            local class = ent:GetClass()
            print(string.format("Entity %s (Model: %s)", class, model))
        end
    end
end)