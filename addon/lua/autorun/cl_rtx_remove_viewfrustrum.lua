-- Constants
local HUGE_BOUNDS = 1e6 -- Large number for bounds

-- Helper function to safely set render bounds
local function SetHugeRenderBounds(ent)
    if not IsValid(ent) then return end
    if not ent.SetRenderBounds then return end
    
    -- Only set bounds for visible entities
    if ent:GetNoDraw() then return end
    
    -- Check if entity is renderable (has a model)
    local model = ent:GetModel()
    if not model or model == "" then return end
    
    local mins = Vector(-HUGE_BOUNDS, -HUGE_BOUNDS, -HUGE_BOUNDS)
    local maxs = Vector(HUGE_BOUNDS, HUGE_BOUNDS, HUGE_BOUNDS)
    
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

-- Add ConVar for enabling/disabling
local cv_disable_culling = CreateClientConVar("disable_frustum_culling", "1", true, false, "Disable frustum culling")

-- Add command to toggle
concommand.Add("toggle_frustum_culling", function()
    cv_disable_culling:SetBool(not cv_disable_culling:GetBool())
    print("Frustum culling: " .. (cv_disable_culling:GetBool() and "DISABLED" or "ENABLED"))
end)

-- Monitor convar changes
cvars.AddChangeCallback("disable_frustum_culling", function(name, old, new)
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

-- Debug command to print entity info
concommand.Add("debug_render_bounds", function()
    print("\nEntity Render Bounds Debug:")
    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and ent.SetRenderBounds then
            local model = ent:GetModel() or "no model"
            local class = ent:GetClass()
            print(string.format("Entity %s (Model: %s)", class, model))
        end
    end
end)