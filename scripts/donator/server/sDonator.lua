class 'sDonator'

function sDonator:__init()

    SQL:Execute("CREATE TABLE IF NOT EXISTS donators (steamID VARCHAR UNIQUE, level INTEGER, DonatorTagEnabled INTEGER, NameColor VARCHAR(11), DonatorTagColor VARCHAR(11), DonatorTagName VARCHAR(10), ColorStreakEnabled INTEGER, GhostRiderHeadEnabled INTEGER, ShadowWingsEnabled INTEGER)")

    Events:Subscribe("ClientModuleLoad", self, self.ClientModuleLoad)
end

function sDonator:ClientModuleLoad(args)
    
    local steamID = tostring(args.player:GetSteamId())
	local query = SQL:Query("SELECT * FROM donators WHERE steamID = (?) LIMIT 1")
    query:Bind(1, steamID)
    
    local result = query:Execute()
    local donator_data = Donators[steamID]

    if not donator_data then return end

    local donator_benefits = self:GetDefaultBenefits(donator_data.level)
    donator_benefits.NameColor = args.player:GetColor()
    donator_benefits.level = donator_data.level

    if #result > 0 and donator_data.level == result[1].level then -- if already in DB and level did not change

        for benefit_name, benefit_value in pairs(result[1]) do
            donator_benefits[benefit_name] = self:Deserialize(benefit_value)
        end

    elseif #result == 0 then

        local command = SQL:Command("INSERT INTO donators (steamID, level, DonatorTagEnabled, NameColor, DonatorTagColor, DonatorTagName, ColorStreakEnabled, GhostRiderHeadEnabled, ShadowWingsEnabled) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        command:Bind(1, steamID) -- Steam id
        command:Bind(2, donator_data.level) -- Donator level
        command:Bind(3, self:Serialize(DonatorBenefits[DonatorLevel.Donator].DonatorTagEnabled)) -- DonatorTagEnabled
        command:Bind(4, self:Serialize(args.player:GetColor())) -- NameColor
        command:Bind(5, self:Serialize(DonatorBenefits[DonatorLevel.Colorful].DonatorTagColor)) -- DonatorTagColor
        command:Bind(6, self:Serialize(DonatorBenefits[DonatorLevel.GhostRider].DonatorTagName)) -- DonatorTagName
        command:Bind(7, self:Serialize(DonatorBenefits[DonatorLevel.Colorful].ColorStreakEnabled)) -- ColorStreakEnabled
        command:Bind(8, self:Serialize(DonatorBenefits[DonatorLevel.GhostRider].GhostRiderHeadEnabled)) -- GhostRiderHeadEnabled
        command:Bind(9, self:Serialize(DonatorBenefits[DonatorLevel.ShadowWings].ShadowWingsEnabled)) -- ShadowWingsEnabled
        command:Execute()

    end

    if #result > 0 and donator_data.level ~= result[1].level then
        donator_benefits.level = donator_data.level
    end

    self:UpdatePlayer(args.player, donator_benefits)
    self:UpdateDB(args.player) -- Update in case player donator level changed

    Chat:Send(args.player, 
        "Hey there! Thanks for supporting the project. You can access your Patreon benefits with /donator", 
        DonatorBenefits[DonatorLevel.Colorful].DonatorTagColor)

end

function sDonator:UpdatePlayer(player, donator_benefits)

    player:SetColor(donator_benefits.NameColor)
    player:SetNetworkValue("DonatorBenefits", donator_benefits)

    player:SetNetworkValue("NameTag", donator_benefits.DonatorTagEnabled and
    {
        name = donator_benefits.DonatorTagName,
        color =donator_benefits.DonatorTagColor
    })

end

function sDonator:UpdateDB(player)

    local donator_data = player:GetValue("DonatorBenefits")
    
    local command = SQL:Command("UPDATE donators set level = ?, DonatorTagEnabled = ?, NameColor = ?, DonatorTagColor = ?, DonatorTagName = ?, ColorStreakEnabled = ?, GhostRiderHeadEnabled = ?, ShadowWingsEnabled = ? WHERE steamID = (?)")
    command:Bind(1, donator_data.level) -- Donator level
    command:Bind(2, self:Serialize(donator_data.DonatorTagEnabled)) -- DonatorTagEnabled
    command:Bind(3, self:Serialize(donator_data.NameColor)) -- NameColor
    command:Bind(4, self:Serialize(donator_data.DonatorTagColor)) -- DonatorTagColor
    command:Bind(5, self:Serialize(donator_data.DonatorTagName)) -- DonatorTagName
    command:Bind(6, self:Serialize(donator_data.ColorStreakEnabled)) -- ColorStreakEnabled
    command:Bind(7, self:Serialize(donator_data.GhostRiderHeadEnabled)) -- GhostRiderHeadEnabled
    command:Bind(8, self:Serialize(donator_data.ShadowWingsEnabled)) -- ShadowWingsEnabled
    command:Bind(9, tostring(player:GetSteamId())) -- Steam id
    command:Execute()

end

function sDonator:GetDefaultBenefits(level)
    local benefits = {}

    for benefit_level, benefit in pairs(DonatorBenefits) do
        for benefit_name, b in pairs(benefit) do
            benefits[benefit_name] = b
        end
    end

    return benefits
end

function sDonator:Deserialize(type, data)
    if type:find("enabled") then
        return data == 1 and true or false
    elseif type == "NameColor" or type == "DonatorTagColor" then
        local split = data:split(",")
        return Color(tonumber(split[1]), tonumber(split[2]), tonumber(split[3]))
    end
    return data
end

function sDonator:Serialize(data)
    if type(data) == "boolean" then
        return data == true and 1 or 0
    elseif data.r and data.g and data.b then
        return string.format("%i,%i,%i", data.r, data.g, data.b)
    end
    return data
end

sDonator = sDonator()