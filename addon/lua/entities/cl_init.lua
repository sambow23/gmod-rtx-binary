include("shared.lua")

local RTXUpdateQueue = include("rtx_light/queue_system.lua")

function ENT:Initialize()
    -- Delay RTX light creation to avoid conflicts with spawn effects
    timer.Simple(0.1, function()
        if IsValid(self) then
            self:CreateRTXLight()
        end
    end)
end

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
end

function ENT:Think()
    -- Queue position updates with low priority
    RTXUpdateQueue:Add(self, {}, 0)
end

function ENT:OnRemove()
    if self.rtxLightHandle then
        DestroyRTXLight(self.rtxLightHandle)
        self.rtxLightHandle = nil
    end
end

-- Property menu with queued updates
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
        -- Queue update with high priority for direct user interaction
        RTXUpdateQueue:Add(self, {brightness = value}, 2)
        
        -- Throttle server updates
        if not self.nextServerUpdate or CurTime() > self.nextServerUpdate then
            net.Start("RTXLight_UpdateProperty")
                net.WriteEntity(self)
                net.WriteString("brightness")
                net.WriteFloat(value)
            net.SendToServer()
            self.nextServerUpdate = CurTime() + 0.1
        end
    end
    
    -- Size Slider
    local sizeSlider = scroll:Add("DNumSlider")
    sizeSlider:Dock(TOP)
    sizeSlider:SetText("Size")
    sizeSlider:SetMin(50)
    sizeSlider:SetMax(1000)
    sizeSlider:SetDecimals(0)
    sizeSlider:SetValue(self:GetLightSize())
    sizeSlider.OnValueChanged = function(_, value)
        RTXUpdateQueue:Add(self, {size = value}, 2)
        
        if not self.nextServerUpdate or CurTime() > self.nextServerUpdate then
            net.Start("RTXLight_UpdateProperty")
                net.WriteEntity(self)
                net.WriteString("size")
                net.WriteFloat(value)
            net.SendToServer()
            self.nextServerUpdate = CurTime() + 0.1
        end
    end
    
    -- Color Mixer
    local colorMixer = scroll:Add("DColorMixer")
    colorMixer:Dock(TOP)
    colorMixer:SetTall(200)
    colorMixer:SetPalette(false)
    colorMixer:SetAlphaBar(false)
    colorMixer:SetColor(Color(self:GetLightR(), self:GetLightG(), self:GetLightB()))
    colorMixer.ValueChanged = function(_, color)
        RTXUpdateQueue:Add(self, {
            r = color.r,
            g = color.g,
            b = color.b
        }, 2)
        
        if not self.nextServerUpdate or CurTime() > self.nextServerUpdate then
            net.Start("RTXLight_UpdateProperty")
                net.WriteEntity(self)
                net.WriteString("color")
                net.WriteUInt(color.r, 8)
                net.WriteUInt(color.g, 8)
                net.WriteUInt(color.b, 8)
            net.SendToServer()
            self.nextServerUpdate = CurTime() + 0.1
        end
    end
    
    self.PropertyPanel = frame
end

properties.Add("rtx_light_properties", {
    MenuLabel = "Edit RTX Light",
    Order = 1,
    MenuIcon = "icon16/lightbulb.png",
    
    Filter = function(self, ent, ply)
        return IsValid(ent) and ent:GetClass() == "base_rtx_light"
    end,
    
    Action = function(self, ent)
        ent:OpenPropertyMenu()
    end
})