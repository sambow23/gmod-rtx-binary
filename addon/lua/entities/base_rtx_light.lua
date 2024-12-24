AddCSLuaFile()

if SERVER then
    util.AddNetworkString("RTXLight_UpdateProperty")
end

ENT.Type = "anim"
ENT.Base = "base_gmodentity"
ENT.PrintName = "RTX Light"
ENT.Author = "Your Name"
ENT.Spawnable = false
ENT.AdminSpawnable = false

function ENT:SetupDataTables()
    self:NetworkVar("Float", 0, "LightBrightness")
    self:NetworkVar("Float", 1, "LightSize")
    self:NetworkVar("Int", 0, "LightR")
    self:NetworkVar("Int", 1, "LightG")
    self:NetworkVar("Int", 2, "LightB")
end

function ENT:Initialize()
    if SERVER then
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

    if CLIENT then
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
            self:GetLightSize(),
            self:GetLightBrightness(),
            self:GetLightR() / 255,
            self:GetLightG() / 255,
            self:GetLightB() / 255
        )
        
        print("[RTX Light] Created light with properties:", 
            self:GetLightSize(),
            self:GetLightBrightness(),
            self:GetLightR(),
            self:GetLightG(),
            self:GetLightB()
        )
    end

    function ENT:OpenPropertyMenu()
        if IsValid(self.PropertyPanel) then
            self.PropertyPanel:Remove()
        end

        local frame = vgui.Create("DFrame")
        frame:SetSize(300, 400)
        frame:SetTitle("RTX Light Properties")
        frame:MakePopup()
        frame:Center()
        
        local scroll = vgui.Create("DScrollPanel", frame)
        scroll:Dock(FILL)
        
        -- Brightness Slider
        local brightnessSlider = scroll:Add("DNumSlider")
        brightnessSlider:Dock(TOP)
        brightnessSlider:SetText("Brightness")
        brightnessSlider:SetMin(1)
        brightnessSlider:SetMax(1000)
        brightnessSlider:SetDecimals(0)
        brightnessSlider:SetValue(self:GetLightBrightness())
        brightnessSlider.OnValueChanged = function(_, value)
            net.Start("RTXLight_UpdateProperty")
                net.WriteEntity(self)
                net.WriteString("brightness")
                net.WriteFloat(value)
            net.SendToServer()
        end
        
        -- Size Slider
        local sizeSlider = scroll:Add("DNumSlider")
        sizeSlider:Dock(TOP)
        sizeSlider:SetText("Size")
        sizeSlider:SetMin(0.1)
        sizeSlider:SetMax(1000)
        sizeSlider:SetDecimals(0)
        sizeSlider:SetValue(self:GetLightSize())
        sizeSlider.OnValueChanged = function(_, value)
            net.Start("RTXLight_UpdateProperty")
                net.WriteEntity(self)
                net.WriteString("size")
                net.WriteFloat(value)
            net.SendToServer()
        end
        
        -- Color Mixer
        local colorMixer = scroll:Add("DColorMixer")
        colorMixer:Dock(TOP)
        colorMixer:SetTall(200)
        colorMixer:SetPalette(false)
        colorMixer:SetAlphaBar(false)
        colorMixer:SetColor(Color(self:GetLightR(), self:GetLightG(), self:GetLightB()))
        colorMixer.ValueChanged = function(_, color)
            net.Start("RTXLight_UpdateProperty")
                net.WriteEntity(self)
                net.WriteString("color")
                net.WriteUInt(color.r, 8)
                net.WriteUInt(color.g, 8)
                net.WriteUInt(color.b, 8)
            net.SendToServer()
        end
        
        self.PropertyPanel = frame
    end

    properties.Add("rtx_light_properties", {
        MenuLabel = "Edit RTX Light",
        Order = 1,
        MenuIcon = "icon16/lightbulb_add.png",
        
        Filter = function(self, ent, ply)
            return IsValid(ent) and ent:GetClass() == "base_rtx_light"
        end,
        
        Action = function(self, ent)
            ent:OpenPropertyMenu()
        end
    })

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
                self:GetLightSize(),
                self:GetLightBrightness(),
                self:GetLightR() / 255,
                self:GetLightG() / 255,
                self:GetLightB() / 255
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
            print("[RTX Light] Updated brightness to:", value)
        
        elseif property == "size" then
            local value = net.ReadFloat()
            ent:SetLightSize(value)
            print("[RTX Light] Updated size to:", value)
        
        elseif property == "color" then
            local r = net.ReadUInt(8)
            local g = net.ReadUInt(8)
            local b = net.ReadUInt(8)
            ent:SetLightR(r)
            ent:SetLightG(g)
            ent:SetLightB(b)
            print("[RTX Light] Updated color to:", r, g, b)
        end
    end)
end