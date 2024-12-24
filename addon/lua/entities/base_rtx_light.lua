AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "RTX Light"
ENT.Author = "Your Name"
ENT.Spawnable = false
ENT.AdminSpawnable = false

function ENT:Initialize()
    if SERVER then
        self:SetModel("models/maxofs2d/light_tubular.mdl")
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:Wake()
        end

        -- Disable default dynamic light
        self:SetKeyValue("_light", "0 0 0 0")
        self:SetKeyValue("brightness", "0")
    end

    if CLIENT then
        -- Initialize with default values
        self.brightness = 100
        self.size = 200
        self.r = 255
        self.g = 255
        self.b = 255
        
        -- Delay RTX light creation to avoid conflicts with spawn effects
        timer.Simple(0.1, function()
            if IsValid(self) then
                self:CreateRTXLight()
            end
        end)
    end
end

if CLIENT then
    function ENT:CreateRTXLight()
        if self.rtxLightHandle then
            DestroyRTXLight(self.rtxLightHandle)
        end

        local pos = self:GetPos()
        self.rtxLightHandle = CreateRTXLight(
            pos.x, pos.y, pos.z,
            self.size,
            self.brightness,
            self.r / 255,
            self.g / 255,
            self.b / 255
        )
    end

    -- Network RTX light properties
    function ENT:SetRTXLight(brightness, size, r, g, b)
        self.brightness = brightness
        self.size = size
        self.r = r
        self.g = g
        self.b = b
        
        -- Delay light update to avoid conflicts
        timer.Simple(0.1, function()
            if IsValid(self) then
                self:CreateRTXLight()
            end
        end)
    end

    function ENT:GetRTXLightProperties()
        return self.brightness, self.size, self.r, self.g, self.b
    end

    local nextThink = 0
    function ENT:Think()
        -- Limit updates to every 0.1 seconds to reduce potential conflicts
        if CurTime() < nextThink then return end
        nextThink = CurTime() + 0.1

        if self.rtxLightHandle then
            local pos = self:GetPos()
            self.rtxLightHandle = UpdateRTXLight(
                self.rtxLightHandle,
                pos.x, pos.y, pos.z,
                self.size,
                self.brightness,
                self.r / 255,
                self.g / 255,
                self.b / 255
            )
        end
    end

    function ENT:OnRemove()
        if self.rtxLightHandle then
            DestroyRTXLight(self.rtxLightHandle)
            self.rtxLightHandle = nil
        end
    end
end

-- Networking
if SERVER then
    function ENT:SetRTXLight(brightness, size, r, g, b)
        self:SetNWFloat("RTXBrightness", brightness)
        self:SetNWFloat("RTXSize", size)
        self:SetNWInt("RTXR", r)
        self:SetNWInt("RTXG", g)
        self:SetNWInt("RTXB", b)
    end
end

if CLIENT then
    -- Network receivers
    function ENT:NetworkRTXLight()
        local brightness = self:GetNWFloat("RTXBrightness", 100)
        local size = self:GetNWFloat("RTXSize", 200)
        local r = self:GetNWInt("RTXR", 255)
        local g = self:GetNWInt("RTXG", 255)
        local b = self:GetNWInt("RTXB", 255)
        
        self:SetRTXLight(brightness, size, r, g, b)
    end
    
    -- Call NetworkRTXLight when network variables change
    function ENT:OnNetworkVarChanged(name, old, new)
        if string.StartWith(name, "RTX") then
            timer.Simple(0.1, function()
                if IsValid(self) then
                    self:NetworkRTXLight()
                end
            end)
        end
    end
end