require("niknaks")

local mapProps = {}

-- Initialize entity with required tables
local function InitP2MEntity(ent)
    ent.prop2mesh_controllers = ent.prop2mesh_controllers or {}
    ent.prop2mesh_partlists = ent.prop2mesh_partlists or {}
    
    -- Basic controller initialization
    function ent:AddController()
        table.insert(self.prop2mesh_controllers, {
            crc = "!none",
            uvs = 0,
            bump = false,
            col = Color(255, 255, 255, 255),
            mat = "hunter/myplastic",
            scale = Vector(1, 1, 1),
            clips = {}
        })
        return #self.prop2mesh_controllers
    end

    -- Add SetControllerData method
    function ent:SetControllerData(index, partlist, uvs, addTo)
        local info = self.prop2mesh_controllers[index]
        if not info or not partlist then
            return
        end

        if addTo and next(partlist) then
            local currentData = self:GetControllerData(index)
            if currentData then
                for i = 1, #currentData do
                    partlist[#partlist + 1] = currentData[i]
                end
                if currentData.custom then
                    if not partlist.custom then
                        partlist.custom = {}
                    end
                    for crc, data in pairs(currentData.custom) do
                        partlist.custom[crc] = data
                    end
                end
            end
        end

        if not next(partlist) then
            self:ResetControllerData(index)
            return
        end

        -- Sanitize custom data (from prop2mesh)
        if partlist.custom then
            local lookup = {}
            for crc, data in pairs(partlist.custom) do
                lookup[crc .. ""] = data
            end

            local custom = {}
            for index, part in ipairs(partlist) do
                if part.objd then
                    local crc = part.objd .. ""
                    if crc and lookup[crc] then
                        custom[crc] = lookup[crc]
                        lookup[crc] = nil
                    end
                end
                if not next(lookup) then
                    break
                end
            end

            partlist.custom = custom
        end

        local json = util.TableToJSON(partlist)
        if not json then
            return
        end

        local data = util.Compress(json)
        local dcrc = util.CRC(data)
        local icrc = info.crc

        if icrc == dcrc then
            return
        end

        self.prop2mesh_partlists[dcrc] = data
        info.crc = dcrc

        if uvs then
            info.uvs = uvs
        end

        local keepdata = false
        for k, v in pairs(self.prop2mesh_controllers) do
            if v.crc == icrc then
                keepdata = true
                break
            end
        end
        if not keepdata then
            self.prop2mesh_partlists[icrc] = nil
        end
    end

    -- Add GetControllerData method
    function ent:GetControllerData(index)
        if not self.prop2mesh_controllers[index] then
            return
        end
        local ret = self.prop2mesh_partlists[self.prop2mesh_controllers[index].crc]
        if not ret then
            return ret
        end
        return util.JSONToTable(util.Decompress(ret))
    end

    -- Add ResetControllerData method
    function ent:ResetControllerData(index)
        if self.prop2mesh_controllers[index] then
            self.prop2mesh_controllers[index].crc = "!none"
        end
    end
end

-- Wait for map to load and props to be available
hook.Add("InitPostEntity", "StaticProp2MeshInit", function()
    local mapData = NikNaks.CurrentMap
    if not mapData then 
        ErrorNoHalt("StaticProp2Mesh: Unable to load map data!")
        return 
    end

    -- Create single prop2mesh entity to handle all static props
    local p2m = ents.CreateClientside("sent_prop2mesh")
    if not IsValid(p2m) then
        ErrorNoHalt("StaticProp2Mesh: Failed to create prop2mesh entity!")
        return
    end

    InitP2MEntity(p2m)

    p2m:SetModel("models/hunter/plates/plate.mdl")
    -- Remove SetNoDraw since we want to render
    p2m:Spawn()
    p2m:Activate()

    -- Get all static props
    local props = mapData:GetStaticProps()
    if not props then
        ErrorNoHalt("StaticProp2Mesh: No static props found!")
        return
    end

    -- Group props by model for efficiency
    local propsByModel = {}
    for _, prop in pairs(props) do
        local model = prop:GetModel()
        propsByModel[model] = propsByModel[model] or {}
        table.insert(propsByModel[model], prop)
    end

    -- Create controllers for each model type
    for model, propsOfModel in pairs(propsByModel) do
        -- Create mesh data array
        local meshData = {}
        
        -- Add each prop instance
        for _, prop in ipairs(propsOfModel) do
            table.insert(meshData, {
                prop = model,
                pos = prop:GetPos(),
                ang = prop:GetAngles(),
                scale = Vector(prop:GetScale(), prop:GetScale(), prop:GetScale()),
                col = prop:GetColor()
            })
        end

        -- Add controller and set data
        local controllerIndex = p2m:AddController()
        p2m:SetControllerData(controllerIndex, meshData)
    end

    -- Store reference to prevent garbage collection
    mapProps.entity = p2m

    -- Debug info
    print("Static Prop2Mesh initialized with:")
    print("- Total models:", table.Count(propsByModel))
    print("- Total controllers:", #p2m.prop2mesh_controllers)
end)

-- Disable engine static prop rendering
local cvar = CreateClientConVar("r_drawstaticprops", "0", true, false)

-- Debug visualization
if ConVarExists("developer") and GetConVar("developer"):GetInt() > 0 then
    hook.Add("PostDrawTranslucentRenderables", "StaticProp2MeshDebug", function()
        if not IsValid(mapProps.entity) then return end
        
        -- Draw boxes around each prop location
        for _, controller in ipairs(mapProps.entity.prop2mesh_controllers) do
            local meshData = mapProps.entity:GetControllerData(controller)
            if meshData then
                for _, prop in ipairs(meshData) do
                    render.DrawWireframeBox(prop.pos, prop.ang, Vector(-5, -5, -5), Vector(5, 5, 5), Color(0, 255, 0), true)
                end
            end
        end
    end)
end

-- Optional debug command
concommand.Add("staticprop2mesh_debug", function()
    if IsValid(mapProps.entity) then
        print("Static Prop2Mesh Stats:")
        print("Controllers:", #mapProps.entity.prop2mesh_controllers)
        for i, controller in ipairs(mapProps.entity.prop2mesh_controllers) do
            local meshData = mapProps.entity:GetControllerData(i)
            print(string.format("Controller %d: %d props", i, meshData and #meshData or 0))
        end
    end
end)