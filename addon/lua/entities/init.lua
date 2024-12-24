AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

if SERVER then
    util.AddNetworkString("RTXLight_UpdateProperty")
end

function ENT:Initialize()
    self:SetModel("models/maxofs2d/light_tubular.mdl")
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    
    -- Set default values
    self:SetLightBrightness(100)
    self:SetLightSize(200)
    self:SetLightR(255)
    self:SetLightG(255)
    self:SetLightB(255)
    
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
    end

    -- Disable default dynamic light
    self:SetKeyValue("_light", "0 0 0 0")
    self:SetKeyValue("brightness", "0")
end

if SERVER then
    -- Handle property updates from clients
    net.Receive("RTXLight_UpdateProperty", function(len, ply)
        local ent = net.ReadEntity()
        if not IsValid(ent) or ent:GetClass() ~= "base_rtx_light" then return end
        
        -- Check if player can edit this entity
        if not hook.Run("CanTool", ply, { Entity = ent }, "rtx_light") then return end
        
        local property = net.ReadString()
        
        if property == "brightness" then
            local value = net.ReadFloat()
            ent:SetLightBrightness(value)
        
        elseif property == "size" then
            local value = net.ReadFloat()
            ent:SetLightSize(value)
        
        elseif property == "color" then
            local r = net.ReadUInt(8)
            local g = net.ReadUInt(8)
            local b = net.ReadUInt(8)
            ent:SetLightR(r)
            ent:SetLightG(g)
            ent:SetLightB(b)
        end
    end)
end