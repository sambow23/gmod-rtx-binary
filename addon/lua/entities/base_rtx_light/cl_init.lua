include("shared.lua")

local activeRTXLights = {}

ENT.rtxEntityID = nil

local function HSVToRGB(h, s, v)
    local h_sector = h / 60
    local h_int = math.floor(h_sector)
    local f = h_sector - h_int
    local p = v * (1 - s)
    local q = v * (1 - s * f)
    local t = v * (1 - s * (1 - f))

    if h_int == 0 then return v * 255, t * 255, p * 255
    elseif h_int == 1 then return q * 255, v * 255, p * 255
    elseif h_int == 2 then return p * 255, v * 255, t * 255
    elseif h_int == 3 then return p * 255, q * 255, v * 255
    elseif h_int == 4 then return t * 255, p * 255, v * 255
    else return v * 255, p * 255, q * 255
    end
end

local function IsValidLightHandle(handle)
    return handle ~= nil 
        and type(handle) == "userdata" 
        and pcall(function() return handle ~= NULL end)
end

function ValidateEntityExists(entityID)
    local entIndex = entityID % 1000000
    local ent = Entity(entIndex)
    
    if not IsValid(ent) then 
        return false 
    end
    
    if ent:GetClass() ~= "base_rtx_light" then 
        return false 
    end
    
    if ent.rtxEntityID and ent.rtxEntityID ~= entityID then
        return false
    end
    
    return true
end

-- Register the validator with a delay to ensure module is loaded
timer.Simple(1, function()
    if RegisterRTXLightEntityValidator then
        RegisterRTXLightEntityValidator(ValidateEntityExists)
    end
end)

function ENT:AnimateColor()
    if not self.IsAnimating then return end
    
    self.AnimationHue = (self.AnimationHue + 1) % 360
    local r, g, b = HSVToRGB(self.AnimationHue, 1, 1)
    
    net.Start("RTXLight_UpdateProperty")
        net.WriteEntity(self)
        net.WriteString("color")
        net.WriteUInt(r, 8)
        net.WriteUInt(g, 8)
        net.WriteUInt(b, 8)
    net.SendToServer()
    
    if IsValid(self) and IsValidLightHandle(self.rtxLightHandle) then
        self:UpdateLight()
    end
end

function ENT:Initialize()
    self:SetNoDraw(true)
    self:DrawShadow(false)
    
    activeRTXLights[self:EntIndex()] = self
    
    timer.Simple(0.25, function()
        if IsValid(self) then
            self:CreateRTXLight()
        end
    end)
    self.IsAnimating = false
    self.AnimationHue = 0
end

function ENT:CreateRTXLight()
    if not self.rtxEntityID then
        local baseIndex = self:EntIndex()
        local timeComponent = math.floor(CurTime()) % 1000
        self.rtxEntityID = (timeComponent * 1000000) + baseIndex
    end

    if self.rtxLightHandle then
        pcall(function() 
            DestroyRTXLight(self.rtxLightHandle)
        end)
        self.rtxLightHandle = nil
    end

    local pos = self:GetPos()
    local size = self:GetLightSize()
    local brightness = self:GetLightBrightness()
    local r = self:GetLightR()
    local g = self:GetLightG()
    local b = self:GetLightB()

    local success, handle = pcall(function()
        return CreateRTXLight(
            pos.x, 
            pos.y, 
            pos.z,
            size,
            brightness,
            r,
            g,
            b,
            self.rtxEntityID
        )
    end)

    if success and IsValidLightHandle(handle) then
        self.rtxLightHandle = handle
        activeRTXLights[self:EntIndex()] = self
        DrawRTXLights()
    end
end

function ENT:OnNetworkVarChanged(name, old, new)
    if IsValid(self) and self.rtxLightHandle then
        self:UpdateLight()
    end
end

-- Replace Think with UpdateLight that only runs when needed
function ENT:UpdateLight()
    if not self.rtxLightHandle then
        self:CreateRTXLight()
        return
    end

    if not IsValidLightHandle(self.rtxLightHandle) then
        self.rtxLightHandle = nil
        self:CreateRTXLight()
        return
    end

    local pos = self:GetPos()
    local brightness = self:GetLightBrightness() / 100
    local size = self:GetLightSize() / 10
    local r = self:GetLightR()
    local g = self:GetLightG()
    local b = self:GetLightB()

    local success, err = pcall(function()
        local updateSuccess, newHandle = UpdateRTXLight(
            self.rtxLightHandle,
            pos.x, pos.y, pos.z,
            size,
            brightness,
            r, g, b
        )

        if updateSuccess then
            if newHandle and IsValidLightHandle(newHandle) and newHandle ~= self.rtxLightHandle then
                self.rtxLightHandle = newHandle
            end
            DrawRTXLights()
        else
            self:CreateRTXLight()
        end
    end)

    if not success then
        self.rtxLightHandle = nil
        self:CreateRTXLight()
    end
end

function ENT:OnRemove()
    activeRTXLights[self:EntIndex()] = nil

    if self.rtxLightHandle then
        pcall(function()
            DestroyRTXLight(self.rtxLightHandle)
        end)
        self.rtxLightHandle = nil
    end
    if self.AnimationTimer then
        timer.Remove("RTXLight_ColorAnim_" .. self:EntIndex())
        self.AnimationTimer = nil
    end
end

-- Rest of the property menu and other functions remain the same...
-- ... existing code ...

hook.Add("ShutDown", "RTXLight_Emergency", function()
    for entIndex, ent in pairs(activeRTXLights) do
        if IsValid(ent) and ent.rtxLightHandle then
            pcall(function()
                DestroyRTXLight(ent.rtxLightHandle)
            end)
        end
    end
end)

net.Receive("RTXLight_Cleanup", function()
    local ent = net.ReadEntity()
    if IsValid(ent) then
        activeRTXLights[ent:EntIndex()] = nil
        
        if ent.rtxLightHandle then
            pcall(function()
                DestroyRTXLight(ent.rtxLightHandle)
            end)
            ent.rtxLightHandle = nil
        end
    end
end)

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
        
        if IsValid(self) and IsValidLightHandle(self.rtxLightHandle) then
            self:UpdateLight()
        end
    end
    
    -- Size Slider
    local sizeSlider = scroll:Add("DNumSlider")
    sizeSlider:Dock(TOP)
    sizeSlider:SetText("Size")
    sizeSlider:SetMin(1)
    sizeSlider:SetMax(1000)
    sizeSlider:SetDecimals(0)
    sizeSlider:SetValue(self:GetLightSize())
    sizeSlider.OnValueChanged = function(_, value)
        net.Start("RTXLight_UpdateProperty")
            net.WriteEntity(self)
            net.WriteString("size")
            net.WriteFloat(value)
        net.SendToServer()
        
        if IsValid(self) and IsValidLightHandle(self.rtxLightHandle) then
            self:UpdateLight()
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
        net.Start("RTXLight_UpdateProperty")
            net.WriteEntity(self)
            net.WriteString("color")
            net.WriteUInt(color.r, 8)
            net.WriteUInt(color.g, 8)
            net.WriteUInt(color.b, 8)
        net.SendToServer()
        
        if IsValid(self) and IsValidLightHandle(self.rtxLightHandle) then
            self:UpdateLight()
        end
    end

    local animateButton = scroll:Add("DButton")
    animateButton:Dock(TOP)
    animateButton:DockMargin(0, 10, 0, 0)
    animateButton:SetTall(30)
    animateButton:SetText(self.IsAnimating and "Stop Color Animation" or "Start Color Animation")
    
    local animSpeedSlider = scroll:Add("DNumSlider")
    animSpeedSlider:Dock(TOP)
    animSpeedSlider:SetText("Animation Speed")
    animSpeedSlider:SetMin(25)
    animSpeedSlider:SetMax(100)
    animSpeedSlider:SetDecimals(1)
    animSpeedSlider:SetValue(1)
    animSpeedSlider:SetEnabled(self.IsAnimating)
    
    local function UpdateAnimation()
        if self.IsAnimating then
            if not self.AnimationTimer then
                self.AnimationTimer = timer.Create("RTXLight_ColorAnim_" .. self:EntIndex(), 0.05, 0, function()
                    if IsValid(self) then
                        self:AnimateColor()
                    end
                end)
            end
        else
            if self.AnimationTimer then
                timer.Remove("RTXLight_ColorAnim_" .. self:EntIndex())
                self.AnimationTimer = nil
            end
        end
        
        animateButton:SetText(self.IsAnimating and "Stop Color Animation" or "Start Color Animation")
        animSpeedSlider:SetEnabled(self.IsAnimating)
    end
    
    animateButton.DoClick = function()
        self.IsAnimating = not self.IsAnimating
        UpdateAnimation()
    end
    
    animSpeedSlider.OnValueChanged = function(_, value)
        if self.AnimationTimer then
            timer.Adjust("RTXLight_ColorAnim_" .. self:EntIndex(), 0.1 / value, 0)
        end
    end
    
    frame.OnRemove = function()
        if self.AnimationTimer then
            timer.Remove("RTXLight_ColorAnim_" .. self:EntIndex())
            self.AnimationTimer = nil
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