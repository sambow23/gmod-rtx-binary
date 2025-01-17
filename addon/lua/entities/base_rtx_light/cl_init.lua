include("shared.lua")

local activeLights = {}
local lastUpdate = 0
local UPDATE_INTERVAL = 0.016 -- ~60fps

function ENT:Initialize()
    self:SetNoDraw(true)
    self:DrawShadow(false)
    
    -- Register this light in our tracking table
    activeLights[self:EntIndex()] = self
    
    -- Delay light creation to ensure networked values are received
    timer.Simple(0.1, function()
        if IsValid(self) then
            self:CreateRTXLight()
        end
    end)
end

function ENT:CreateRTXLight()
    -- Clean up any existing light for this entity
    if self.rtxLightHandle then
        pcall(function() 
            DestroyRTXLight(self.rtxLightHandle)
            print("[RTX Light] Destroyed existing light handle:", self.rtxLightHandle)
        end)
        self.rtxLightHandle = nil
    end

    local pos = self:GetPos()
    local size = self:GetLightSize()
    local brightness = self:GetLightBrightness()
    local r = self:GetLightR()
    local g = self:GetLightG()
    local b = self:GetLightB()

    -- Create new light
    local success, handle = pcall(function()
        return CreateRTXLight(
            pos.x, 
            pos.y, 
            pos.z,
            size,
            brightness,
            r,
            g,
            b
        )
    end)

    if success and handle then
        self.rtxLightHandle = handle
        self.lastUpdatePos = pos
        self.lastUpdateTime = CurTime()
        activeLights[self:EntIndex()] = self
        print("[RTX Light] Successfully created light with handle:", handle)
    else
        ErrorNoHalt("[RTX Light] Failed to create light: ", tostring(handle), "\n")
    end
end

function ENT:OnNetworkVarChanged(name, old, new)
    if IsValid(self) and self.rtxLightHandle then
        self:CreateRTXLight() -- Recreate light with new properties
    end
end

function ENT:Think()
    if not self.nextUpdate then self.nextUpdate = 0 end
    if CurTime() < self.nextUpdate then return end
    
    -- Only update if we have a valid light
    if self.rtxLightHandle then
        local pos = self:GetPos()
        
        -- Check if we actually need to update
        if not self.lastUpdatePos or pos:DistToSqr(self.lastUpdatePos) > 1 then
            local brightness = self:GetLightBrightness() / 100  -- Convert percentage to 0-1
            local size = self:GetLightSize() / 10  -- Scale down size
            local r = self:GetLightR()
            local g = self:GetLightG()
            local b = self:GetLightB()

            -- Queue update in RTX manager
            if UpdateRTXLight(
                self.rtxLightHandle,
                pos.x, pos.y, pos.z,
                size,
                brightness,
                r, g, b
            ) then
                self.lastUpdatePos = pos
                self.lastUpdateTime = CurTime()
            else
                -- If update failed, recreate light
                self:CreateRTXLight()
            end
        end
    else
        -- Try to recreate light if it's missing
        self:CreateRTXLight()
    end
    
    self.nextUpdate = CurTime() + UPDATE_INTERVAL
end

function ENT:OnRemove()
    -- Remove from tracking table
    activeLights[self:EntIndex()] = nil

    if self.rtxLightHandle then
        print("[RTX Light] Cleaning up light handle:", self.rtxLightHandle)
        pcall(function()
            DestroyRTXLight(self.rtxLightHandle)
        end)
        self.rtxLightHandle = nil
    end
end

net.Receive("RTXLight_Cleanup", function()
    local ent = net.ReadEntity()
    if IsValid(ent) then
        -- Remove from tracking table
        activeLights[ent:EntIndex()] = nil
        
        -- Cleanup RTX light
        if ent.rtxLightHandle then
            pcall(function()
                DestroyRTXLight(ent.rtxLightHandle)
            end)
            ent.rtxLightHandle = nil
        end
    end
end)

-- Simple property menu
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
    sizeSlider:SetMin(50)
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
    MenuIcon = "icon16/lightbulb.png",
    
    Filter = function(self, ent, ply)
        return IsValid(ent) and ent:GetClass() == "base_rtx_light"
    end,
    
    Action = function(self, ent)
        ent:OpenPropertyMenu()
    end
})

hook.Add("PreRender", "RTXLightFrameSync", function()
    RTXBeginFrame()
    
    -- Update all active lights
    for entIndex, light in pairs(activeLights) do
        if IsValid(light) then
            light:Think()
        else
            activeLights[entIndex] = nil
        end
    end
end)

hook.Add("PostRender", "RTXLightFrameSync", function()
    RTXEndFrame()
end)

hook.Add("ShutDown", "CleanupRTXLights", function()
    for _, ent in pairs(activeLights) do
        if IsValid(ent) then
            ent:OnRemove()
        end
    end
    table.Empty(activeLights)
end)

hook.Add("PreCleanupMap", "CleanupRTXLights", function()
    for _, ent in pairs(activeLights) do
        if IsValid(ent) then
            ent:OnRemove()
        end
    end
    table.Empty(activeLights)
end)