TOOL.Category = "Lighting"
TOOL.Name = "RTX Light"
TOOL.Command = nil
TOOL.ConfigName = ""

-- Default settings
TOOL.ClientConVar = {
    ["brightness"] = "100",
    ["size"] = "200",
    ["r"] = "255",
    ["g"] = "255",
    ["b"] = "255"
}

if CLIENT then
    language.Add("tool.rtx_light.name", "RTX Light")
    language.Add("tool.rtx_light.desc", "Create RTX-enabled lights")
    language.Add("tool.rtx_light.0", "Left click to create a light. Right click to remove. Reload to copy settings.")

    function TOOL.BuildCPanel(panel)
        panel:NumSlider("Brightness", "rtx_light_brightness", 1, 1000, 0)
        panel:NumSlider("Size", "rtx_light_size", 50, 1000, 0)
        panel:ColorPicker("Light Color", "rtx_light_r", "rtx_light_g", "rtx_light_b")
    end
end

-- Store light data
TOOL.Lights = TOOL.Lights or {}

function TOOL:LeftClick(trace)
    if CLIENT then return true end

    local ply = self:GetOwner()
    if not IsValid(ply) then return false end

    -- Get position from trace
    local pos = trace.HitPos
    
    -- Get tool settings
    local brightness = self:GetClientNumber("brightness", 100)
    local size = self:GetClientNumber("size", 200)
    local r = self:GetClientNumber("r", 255)
    local g = self:GetClientNumber("g", 255)
    local b = self:GetClientNumber("b", 255)

    -- Delay entity creation slightly to avoid effects conflict
    timer.Simple(0.05, function()
        -- Create an entity to represent the light position
        local ent = ents.Create("base_rtx_light")
        if not IsValid(ent) then return end

        ent:SetPos(pos)
        ent:SetAngles(angle_zero)
        ent:Spawn()
        
        -- Set the light properties
        ent:SetRTXLight(brightness, size, r, g, b)

        -- Undo setup
        undo.Create("RTX Light")
            undo.AddEntity(ent)
            undo.SetPlayer(ply)
        undo.Finish()
    end)

    return true
end

function TOOL:RightClick(trace)
    if CLIENT then return true end
    
    -- Remove RTX light if we click on one
    if IsValid(trace.Entity) and trace.Entity:GetClass() == "base_rtx_light" then
        trace.Entity:Remove()
        return true
    end
    
    return false
end

function TOOL:Reload(trace)
    if not IsValid(trace.Entity) or trace.Entity:GetClass() ~= "base_rtx_light" then return false end
    
    if CLIENT then return true end

    -- Copy settings from existing light
    local ply = self:GetOwner()
    if not IsValid(ply) then return false end

    local brightness, size, r, g, b = trace.Entity:GetRTXLightProperties()
    
    -- Update the client's tool settings
    ply:ConCommand("rtx_light_brightness " .. brightness)
    ply:ConCommand("rtx_light_size " .. size)
    ply:ConCommand("rtx_light_r " .. r)
    ply:ConCommand("rtx_light_g " .. g)
    ply:ConCommand("rtx_light_b " .. b)

    return true
end