class 'sExp'

function sExp:__init()

    SQL:Execute("CREATE TABLE IF NOT EXISTS exp (steamID VARCHAR(20), level INTEGER, combat_exp INTEGER, explore_exp INTEGER)")

    self.recent_killers = {} -- Players who have been killed recently by another player

    Events:Subscribe("ClientModuleLoad", self, self.ClientModuleLoad)

    Events:Subscribe("PlayerOpenLootbox", self, self.PlayerOpenLootbox)
    Events:Subscribe("PlayerKilled", self, self.PlayerKilled)
    Events:Subscribe("ModulesLoad", self, self.ModulesLoad)

    Events:Subscribe("PlayerChat", self, self.PlayerChat)

end

function sExp:ModulesLoad()
    for p in Server:GetPlayers() do
        if p:GetValue("Exp") then
            Events:Fire("PlayerExpLoaded", {player = p})
        end
    end
end

function sExp:PlayerKilled(args)

    -- Give killer exp
    if args.killer then
        self:AwardExpToKillerOnKill(args)
    end

    -- Subtract exp from player who died
    local exp_data = args.player:GetValue("Exp")
    local exp_lost = GetExpLostOnDeath(exp_data.level)
    exp_data.combat_exp = math.max(0, exp_data.combat_exp - exp_lost)
    exp_data.explore_exp = math.max(0, exp_data.explore_exp - exp_lost)

    args.player:SetNetworkValue("Exp", exp_data)
    self:UpdateDB(tostring(args.player:GetSteamId()), exp_data)

    Events:Fire("Discord", {
        channel = "Experience",
        content = string.format("%s [%s] was killed and lost %d exp.", args.player:GetName(), tostring(args.player:GetSteamId()), exp_lost)
    })
    
end

function sExp:AwardExpToKillerOnKill(args)

    local player_id = tostring(args.player:GetSteamId())
    local killer_id = args.killer

    if player_id == killer_id then return end

    local exp_earned = Exp.Kill[args.reason]

    if not exp_earned or exp_earned == 0 then return end

    local killed_exp = args.player:GetValue("Exp")
    
    if not self.recent_killers[player_id] then
        self.recent_killers[player_id] = {}
    end

    local last_killed_ids = self.recent_killers[player_id]

    local expire_time = last_killed_ids[killer_id]

    if expire_time then
        -- If they have been killed recently, check the time
        local diff = Server:GetElapsedSeconds() - expire_time

        if diff > Exp.KillExpireTime then
            self.recent_killers[player_id][killer_id] = nil
        else
            exp_earned = 0
        end

    else
        -- If they have not been killed recently, add them to the list
        self.recent_killers[player_id][killer_id] = Server:GetElapsedSeconds()
    end

    if exp_earned == 0 then return end

    local killer = nil

    for p in Server:GetPlayers() do
        if killer_id == tostring(p:GetSteamId()) then
            killer = p
            break
        end
    end

    local killer_exp = {}

    if IsValid(killer) then
        -- Killer is online; add exp and set net val
        killer_exp = killer:GetValue("Exp")
    else
        -- Killer is offline; lookup in db to get level difference and update db
        
        local query = SQL:Query("SELECT * FROM exp WHERE steamID = (?) LIMIT 1")
        query:Bind(1, killer_id)
        
        local result = query:Execute()

        if #result > 0 then -- if already in DB
            
            killer_exp.level = tonumber(result[1].level)
            killer_exp.combat_exp = tonumber(result[1].combat_exp)
            killer_exp.explore_exp = tonumber(result[1].explore_exp)
            killer_exp.explore_max_exp = GetMaximumExp(killer_exp.level)
            killer_exp.combat_max_exp = GetMaximumExp(killer_exp.level)

        end

    end

    if count_table(killer_exp) > 0 and killed_exp then

        local exp_earned = math.ceil(exp_earned * GetKillLevelModifier(killer_exp.level, killed_exp.level))
        self:GivePlayerExp(exp_earned, ExpType.Combat, killer_id, killer_exp, killer)

        Events:Fire("Discord", {
            channel = "Experience",
            content = string.format("[%s] [Level %d] killed %s [%s] [Level %d] and gained %d exp.", 
                killer_id, killer_exp.level, args.player:GetName(), player_id, killed_exp.level, exp_earned)
        })
        
    end

end

function sExp:PlayerChat(args)

    if not IsAdmin(args.player) then return end

    local words = args.text:split(" ")

    if words[1] == "/expe" and words[2] then
        self:GivePlayerExp(tonumber(words[2]), ExpType.Exploration, tostring(args.player:GetSteamId()), args.player:GetValue("Exp"), args.player)
    elseif words[1] == "/expc" and words[2] then
        self:GivePlayerExp(tonumber(words[2]), ExpType.Combat, tostring(args.player:GetSteamId()), args.player:GetValue("Exp"), args.player)
    end

end

function sExp:PlayerOpenLootbox(args)

    if args.has_been_opened then return end

    local exp_earned = Exp.Lootbox[args.tier]
    if not exp_earned then return end

    self:GivePlayerExp(exp_earned, ExpType.Exploration, tostring(args.player:GetSteamId()), args.player:GetValue("Exp"), args.player)

    Events:Fire("Discord", {
        channel = "Experience",
        content = string.format("%s [%s] opened a tier %d lootbox and gained %d exp.", 
            args.player:GetName(), tostring(args.player:GetSteamId()), args.tier, exp_earned)
    })
    
end

function sExp:GivePlayerExp(exp, type, steamID, exp_data, player)

    if not exp_data then return end
    if exp <= 0 then return end
    print(string.format("[%s] got %d exp (Source: %d)", steamID, exp, type))

    if type == ExpType.Combat then

        exp_data.combat_exp = math.min(exp_data.combat_exp + exp, exp_data.combat_max_exp)

    elseif type == ExpType.Exploration then

        exp_data.explore_exp = math.min(exp_data.explore_exp + exp, exp_data.explore_max_exp)

    end

    local gained_level = false

    if exp_data.combat_exp == exp_data.combat_max_exp
    and exp_data.explore_exp == exp_data.explore_max_exp then
        exp_data = self:PlayerGainLevel(exp_data)

        Events:Fire("SendPlayerPersistentMessage", {
            steam_id = steamID,
            message = string.format("Level up! You are now level %d!", exp_data.level),
            color = Color.Yellow
        })

        Events:Fire("Discord", {
            channel = "Experience",
            content = string.format("[%s] gained a new level! They are now level %d.", steamID, exp_data.level)
        })
        
        gained_level = true
    end

    self:UpdateDB(steamID, exp_data)

    if IsValid(player) then
        player:SetNetworkValue("Exp", exp_data)
        Events:Fire("PlayerExpUpdated", {player = player})

        if gained_level then
            Events:Fire("PlayerLevelUpdated", {player = player})
        end
    end

end

function sExp:PlayerGainLevel(exp_data)

    exp_data.level = math.min(exp_data.level + 1, Exp.Max_Level)
    exp_data.combat_exp = 0
    exp_data.explore_exp = 0
    exp_data.combat_max_exp = GetMaximumExp(exp_data.level)
    exp_data.explore_max_exp = GetMaximumExp(exp_data.level)

    return exp_data

end

function sExp:UpdateDB(steamID, exp_data)
    
    local update = SQL:Command("UPDATE exp SET level = ?, combat_exp = ?, explore_exp = ? WHERE steamID = (?)")
	update:Bind(1, exp_data.level)
	update:Bind(2, exp_data.combat_exp)
	update:Bind(3, exp_data.explore_exp)
	update:Bind(4, steamID)
    update:Execute()
    
end

function sExp:ClientModuleLoad(args)

    local steamID = tostring(args.player:GetSteamId())
    
	local query = SQL:Query("SELECT * FROM exp WHERE steamID = (?) LIMIT 1")
    query:Bind(1, steamID)
    
    local result = query:Execute()

    local exp_data = {}
    
    if #result > 0 then -- if already in DB
        
        exp_data.level = tonumber(result[1].level)
        exp_data.combat_exp = tonumber(result[1].combat_exp)
        exp_data.explore_exp = tonumber(result[1].explore_exp)

    else
        
		local command = SQL:Command("INSERT INTO exp (steamID, level, combat_exp, explore_exp) VALUES (?, ?, ?, ?)")
		command:Bind(1, steamID)
		command:Bind(2, Exp.Starting_Level)
		command:Bind(3, 0)
		command:Bind(4, 0)
        command:Execute()

        exp_data.level = Exp.Starting_Level
        exp_data.combat_exp = 0
        exp_data.explore_exp = 0

    end
    
    exp_data.combat_max_exp = GetMaximumExp(exp_data.level) -- TODO: divide by two
    exp_data.explore_max_exp = GetMaximumExp(exp_data.level)

    args.player:SetNetworkValue("Exp", exp_data)
    Events:Fire("PlayerExpLoaded", {player = args.player})

end

sExp = sExp()