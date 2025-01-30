if not CLIENT then return end

-- ConVars
local cv_enabled = CreateClientConVar("fr_enabled", "1", true, false, "Enable RTX frustum optimization")
local cv_static_props = CreateClientConVar("fr_static_props", "1", true, false, "Enable optimization for static props")

-- Special entities that should always be visible
local SPECIAL_ENTITIES = {
    ["hdri_cube_editor"] = true,
    ["rtx_lightupdater"] = true,
    ["rtx_lightupdatermanager"] = true
}

-- Cache for managed entities
local managedEntities = {}
local staticProps = {}

-- Helper function to identify RTX-related entities
local function IsRTXEntity(ent)
    if not IsValid(ent) then return end
    return SPECIAL_ENTITIES[ent:GetClass()]
end

-- Set entity visibility state
local function SetEntityVisibility(ent, enable)
    if not IsValid(ent) then return end
    
    if enable then
        -- Basic visibility flags that won't interfere with RTX
        ent:AddEFlags(EFL_FORCE_CHECK_TRANSMIT)
        ent:SetRenderMode(RENDERMODE_NORMAL)
        ent:DrawShadow(true)
    else
        ent:RemoveEFlags(EFL_FORCE_CHECK_TRANSMIT)
    end
end

-- Handle static props
local function SetupStaticProps()
    -- Clear existing static props
    for prop in pairs(staticProps) do
        if IsValid(prop) then
            prop:Remove()
        end
    end
    staticProps = {}

    -- Only proceed if enabled and NikNaks is available
    if not cv_enabled:GetBool() or not cv_static_props:GetBool() or not NikNaks or not NikNaks.CurrentMap then return end

    local props = NikNaks.CurrentMap:GetStaticProps()
    for _, propData in pairs(props) do
        local prop = ClientsideModel(propData:GetModel())
        if IsValid(prop) then
            prop:SetPos(propData:GetPos())
            prop:SetAngles(propData:GetAngles())
            prop:SetColor(propData:GetColor())
            prop:SetModelScale(propData:GetScale())
            
            -- Set large render bounds
            local bounds = Vector(8196, 8196, 16144)
            prop:SetRenderBounds(-bounds, bounds)
            
            staticProps[prop] = true
            managedEntities[prop] = true
        end
    end
end

-- Hook for new entities
hook.Add("OnEntityCreated", "RTX_PVS_Optimization", function(ent)
    if not IsValid(ent) then return end
    
    timer.Simple(0, function()
        if not IsValid(ent) or not cv_enabled:GetBool() then return end
        
        if IsRTXEntity(ent) then
            SetEntityVisibility(ent, true)
            managedEntities[ent] = true
        end
    end)
end)

-- Entity cleanup
hook.Add("EntityRemoved", "RTX_PVS_Cleanup", function(ent)
    managedEntities[ent] = nil
    staticProps[ent] = nil
end)

-- Map cleanup/reload handler
hook.Add("OnReloaded", "RefreshStaticProps", function()
    timer.Simple(1, SetupStaticProps)
end)

-- Initial setup
hook.Add("InitPostEntity", "InitialRTXSetup", function()
    timer.Simple(1, SetupStaticProps)
end)

-- ConVar change handlers
cvars.AddChangeCallback("fr_enabled", function(_, _, new)
    local enabled = tobool(new)
    for ent in pairs(managedEntities) do
        if IsValid(ent) then
            SetEntityVisibility(ent, enabled)
        end
    end
    
    if enabled and cv_static_props:GetBool() then
        SetupStaticProps()
    end
end)

cvars.AddChangeCallback("fr_static_props", function(_, _, new)
    local enabled = tobool(new)
    if enabled and cv_enabled:GetBool() then
        SetupStaticProps()
    else
        for prop in pairs(staticProps) do
            if IsValid(prop) then
                prop:Remove()
            end
        end
        staticProps = {}
    end
end)

-- Refresh command
concommand.Add("fr_refresh", function()
    if cv_enabled:GetBool() then
        for ent in pairs(managedEntities) do
            if IsValid(ent) then
                SetEntityVisibility(ent, true)
            end
        end
        if cv_static_props:GetBool() then
            SetupStaticProps()
        end
        print("Refreshed RTX optimization")
    end
end)

-- Settings panel
hook.Add("PopulateToolMenu", "RTXOptimizationMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_OPT", "#RTX Optimization", "", "", function(panel)
        panel:ClearControls()
        
        panel:CheckBox("Enable RTX Optimization", "fr_enabled")
        panel:ControlHelp("Optimize entity visibility for RTX")
        
        panel:Help("")
        
        panel:CheckBox("Enable Static Props Optimization", "fr_static_props")
        panel:ControlHelp("Apply optimization to map's static props")
        
        panel:Help("")
        
        local refreshBtn = panel:Button("Refresh")
        function refreshBtn.DoClick()
            RunConsoleCommand("fr_refresh")
            surface.PlaySound("buttons/button14.wav")
        end
        
        local debugBtn = panel:Button("Debug Info")
        function debugBtn.DoClick()
            local rtxCount = 0
            local propCount = 0
            
            for ent in pairs(managedEntities) do
                if IsValid(ent) then
                    if staticProps[ent] then
                        propCount = propCount + 1
                    else
                        rtxCount = rtxCount + 1
                    end
                end
            end
            
            print("\nRTX Optimization Status:")
            print("Enabled:", cv_enabled:GetBool())
            print("Static Props Enabled:", cv_static_props:GetBool())
            print("RTX Entities:", rtxCount)
            print("Static Props:", propCount)
        end
    end)
end)