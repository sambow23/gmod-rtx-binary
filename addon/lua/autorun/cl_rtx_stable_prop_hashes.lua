if not CLIENT then return end
CreateClientConVar(	"rtx_disablevertexlighting", 1,  true, false) 

local function DrawFix( self, flags )
    if (GetConVar( "mat_fullbright" ):GetBool()) then return end
    render.SuppressEngineLighting( GetConVar( "rtx_disablevertexlighting" ):GetBool() )

	if (self:GetMaterial() != "") then -- Fixes material tool and lua SetMaterial
		render.MaterialOverride(Material(self:GetMaterial()))
	end

	for k, v in pairs(self:GetMaterials()) do -- Fixes submaterial tool and lua SetSubMaterial
		if (self:GetSubMaterial( k-1 ) != "") then
			render.MaterialOverrideByIndex(k-1, Material(self:GetSubMaterial( k-1 )))
		end
	end

	self:DrawModel(flags + STUDIO_STATIC_LIGHTING) -- Fix hash instability
	render.MaterialOverride(nil)
    render.SuppressEngineLighting( false )

end
local function ApplyRenderOverride(ent)
	ent.RenderOverride = DrawFix 
end
local function FixupEntity(ent) 
	if (ent:GetClass() != "procedural_shard") then ApplyRenderOverride(ent) end
end
local function FixupEntities() 

	hook.Add( "OnEntityCreated", "RTXEntityFixups", FixupEntity)
	for k, v in pairs(ents.GetAll()) do
		FixupEntity(v)
	end

end

local function RTXLoadPropHashFixer()
    FixupEntities()
end
hook.Add( "InitPostEntity", "RTXReady_PropHashFixer", RTXLoadPropHashFixer)  