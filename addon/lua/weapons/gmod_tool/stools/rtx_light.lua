TOOL.Category = "Lighting"
TOOL.Name = "RTX Light"
TOOL.Command = nil
TOOL.ConfigName = ""

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

function TOOL:LeftClick(trace)
    if CLIENT then return true end

    local ply = self:GetOwner()
    if not IsValid(ply) then return false end

    local pos = trace.HitPos
    
    -- Get tool settings
    local brightness = self:GetClientNumber("brightness", 100)
    local size = self:GetClientNumber("size", 200)
    local r = self:GetClientNumber("r", 255)
    local g = self:GetClientNumber("g", 255)
    local b = self:GetClientNumber("b", 255)

    -- Create entity
    local ent = ents.Create("base_rtx_light")
    if not IsValid(ent) then return false end

    ent:SetPos(pos)
    ent:SetAngles(angle_zero)
    ent:Spawn()
    
    -- Set the light properties directly
    ent:SetLightBrightness(brightness)
    ent:SetLightSize(size)
    ent:SetLightR(r)
    ent:SetLightG(g)
    ent:SetLightB(b)

    print("[RTX Light Tool] Created light with properties:", brightness, size, r, g, b)

    undo.Create("RTX Light")
        undo.AddEntity(ent)
        undo.SetPlayer(ply)
    undo.Finish()

    return true
end

function TOOL:RightClick(trace)
    if CLIENT then return true end
    
    if IsValid(trace.Entity) and trace.Entity:GetClass() == "base_rtx_light" then
        trace.Entity:Remove()
        return true
    end
    
    return false
end

function TOOL:Reload(trace)
    if not IsValid(trace.Entity) or trace.Entity:GetClass() ~= "base_rtx_light" then return false end
    
    if CLIENT then return true end

    local ply = self:GetOwner()
    if not IsValid(ply) then return false end

    -- Copy settings from existing light
    ply:ConCommand("rtx_light_brightness " .. trace.Entity:GetLightBrightness())
    ply:ConCommand("rtx_light_size " .. trace.Entity:GetLightSize())
    ply:ConCommand("rtx_light_r " .. trace.Entity:GetLightR())
    ply:ConCommand("rtx_light_g " .. trace.Entity:GetLightG())
    ply:ConCommand("rtx_light_b " .. trace.Entity:GetLightB())

    return true
end