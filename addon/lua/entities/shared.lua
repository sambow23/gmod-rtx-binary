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