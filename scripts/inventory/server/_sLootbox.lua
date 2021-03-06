class 'sLootbox'

-- tier, position, angle, contents
function sLootbox:__init(args)

    if not args.tier 
    or not args.position 
    or not args.angle 
    or not args.contents then
        error("sLootbox:__init failed: a key argument is missing from the constructor")
    end

    self.uid = GetLootboxUID()
    self.active = args.active == true
    self.tier = args.tier
    self.position = args.position
    self.cell = GetCell(self.position, Lootbox.Cell_Size)
    self.angle = args.angle
    self.contents = args.contents
    self.model_data = Lootbox.Models[args.tier]
    self.is_dropbox = args.tier == Lootbox.Types.Dropbox
    self.is_vending_machine = args.tier == Lootbox.Types.VendingMachineFood or args.tier == Lootbox.Types.VendingMachineDrink
    self.is_stash = Lootbox.Stashes[args.tier] ~= nil
    self.has_been_opened = false
    -- Eventually add support for world specification

    self.players_opened = {}

    -- Dropboxes despawn after a while
    if self.is_dropbox then

        self.despawn_timer = Timer.SetTimeout(Lootbox.Dropbox_Despawn_Time, function()
            self:Remove()
        end)

    end

    self.network_subs = {}

    table.insert(self.network_subs, Network:Subscribe("Inventory/TryOpenBox" .. tostring(self.uid), self, self.TryOpenBox))
    table.insert(self.network_subs, Network:Subscribe("Inventory/TakeLootStack" .. tostring(self.uid), self, self.TakeLootStack))
    table.insert(self.network_subs, Network:Subscribe("Inventory/CloseBox" .. tostring(self.uid), self, self.CloseBox))

    Events:Subscribe("ModuleUnload", function()
        self:Remove()
    end)

    if self.is_dropbox then
        for index, stack in pairs(self.contents) do
            for item_index, item in pairs(stack.contents) do
                if item.durability and item.durability <= 0 then
                    stack:RemoveItem(item, item_index)
                end
            end

            if count_table(stack.contents) == 0 then
                table.remove(self.contents, index)
            end
        end

        if count_table(self.contents) == 0 then
            self:Remove()
            return
        end
    end

end

-- Called when a player tries to drag to swap two items in a stash
function sLootbox:PlayerSwapStack(args, player)

    if not self.players_opened[tostring(player:GetSteamId())] then return end
    if not self.active then return end
    if player:GetHealth() <= 0 then return end

    -- If it's a stash and they aren't allowed to open it, then prevent them from doing so
    if self.is_stash then
        if not self.stash:CanPlayerOpen(player) then return end
    end

    local inv = InventoryManager.inventories[tostring(player:GetSteamId().id)]
    if not inv:CanPlayerPerformOperations(player) then return end


end

-- Called when a player tries to add a stack to a stash
function sLootbox:PlayerAddStack(stack, player)

    if not self.active then return end
    if player:GetHealth() <= 0 then return end

    -- If it's a stash and they aren't allowed to open it, then prevent them from doing so
    if self.is_stash then
        if not self.stash:CanPlayerOpen(player) then return stack end
    end

    Events:Fire("Discord", {
        channel = "Stashes",
        content = string.format("%s [%s] added stack to stash %d [Tier %d]. \nStack: %s", 
            player:GetName(), player:GetSteamId(), self.stash.id, self.tier, stack:ToString())
    })

    local return_stack = self:AddStack(stack)

    if return_stack then
        Events:Fire("Discord", {
            channel = "Stashes",
            content = string.format("%s [%s] was not able to add the entire stack. \nRemaining stack: %s", 
                player:GetName(), player:GetSteamId(), return_stack:ToString())
        })
    end

    if self.is_stash then
        for p in Server:GetPlayers() do
            if self.stash:IsPlayerOwner(p) then
                self.stash:Sync(p)
                break
            end
        end
    end

    return return_stack

end

function sLootbox:AddStack(_stack)

    if not _stack then
        error("sLootbox:AddStack failed: _stack does not exist")
    end

    if not _stack.contents or not _stack.contents[1] then
        error("sLootbox:AddStack failed: _stack does have valid contents")
    end

    for k, stack in pairs(self.contents) do

        if _stack and stack:CanStack(_stack.contents[1]) then
            _stack = stack:AddStack(_stack)
        end

    end

    if _stack and _stack:GetAmount() > 0 then
        if not self.is_stash then
            table.insert(self.contents, _stack)
            _stack = nil
        else
            -- This is a stash, check its capacity
            if count_table(self.contents) < self.stash.capacity then
                table.insert(self.contents, _stack)
                _stack = nil
            end
        end
    else
        _stack = nil
    end

    self:UpdateToPlayers()

    if self.is_stash then
        self.stash:UpdateToDB()
    end

    return _stack -- Return stack in case we were not able to add them all
end

function sLootbox:TakeLootStack(args, player)

    if not self.players_opened[tostring(player:GetSteamId())] then return end
    if not args.index or args.index < 1 then return end
    if not self.active then return end
    if player:GetHealth() <= 0 then return end

    -- If it's a stash and they aren't allowed to open it, then prevent them from doing so
    if self.is_stash then
        if not self.stash:CanPlayerOpen(player) then return end
    end

    local stack = self.contents[args.index]

    if not stack then return end

    local inv = InventoryManager.inventories[tostring(player:GetSteamId().id)]

    if not inv then return end

    if not inv:CanPlayerPerformOperations(player) then return end

    local channel = self.is_stash and "Stashes" or "Inventory"
    local id = self.is_stash and self.stash.id or self.uid
    Events:Fire("Discord", {
        channel = channel,
        content = string.format("%s [%s] took stack from lootbox %d [Tier %d]. \nStack: %s", 
            player:GetName(), player:GetSteamId(), id, self.tier, stack:ToString())
    })

    local return_stack = inv:AddStack({stack = stack})

    if self.is_stash and not IsAFriend(player, self.stash.owner_id) and not self.stash:IsPlayerOwner(player) then
        Events:Fire("Discord", {
            channel = "Stashes",
            content = string.format("**__RAID__**: %s [%s] is raiding [%s].", 
                player:GetName(), player:GetSteamId(), self.stash.owner_id)
        })
    end

    if return_stack then
        self.contents[args.index] = return_stack
        
        local channel = self.is_stash and "Stashes" or "Inventory"
        Events:Fire("Discord", {
            channel = channel,
            content = string.format("%s [%s] was not able to take the entire stack. \nRemaining stack: %s", 
                player:GetName(), player:GetSteamId(), return_stack:ToString())
        })

    else
        table.remove(self.contents, args.index)
    end

    self:UpdateToPlayers()

    if #self.contents == 0 then

        if self.tier == Lootbox.Types.Dropbox then
            self:Remove()
        elseif not self.is_stash then
            self:HideBox()
        end

    end

    if self.is_stash then
        self.stash:UpdateToDB()
    end
end

function sLootbox:TryOpenBox(args, player)

    if not IsValid(player) then return end
    if count_table(self.contents) == 0 and not self.is_stash then return end
    if player:GetHealth() <= 0 then return end
    if player:GetPosition():Distance(self.position) > Lootbox.Distances.Can_Open + 1 then return end

    -- If it's a stash and they aren't allowed to open it, then prevent them from doing so
    if self.is_stash then
        if not self.stash:CanPlayerOpen(player) then return end
    end

    self:Open(player)

end

function sLootbox:GetContentsSyncData()
    local data = {contents = self:GetContentsData()}
    if self.is_stash then
        data.stash = self.stash:GetSyncData()
    end
    return data
end

function sLootbox:Open(player)
    
    self.players_opened[tostring(player:GetSteamId())] = player
    player:SetValue("CurrentLootbox", {uid = self.uid, cell = self.cell})
    Network:Send(player, "Inventory/LootboxOpen", self:GetContentsSyncData())

    Events:Fire("PlayerOpenLootbox", {player = player, has_been_opened = self.has_been_opened, tier = self.tier})

    self:StartDespawnTimer()

    self.has_been_opened = true

end

function sLootbox:StartDespawnTimer()

    -- No despawn timer for stashes
    if self.is_stash then return end

    if not self.despawn_timer then

        self.despawn_timer = Timer.SetTimeout(Lootbox.Loot_Despawn_Time, function()
            if count_table(self.players_opened) == 0 then
                -- Don't hide if there is someone looting it
                self:HideBox()
            else
                self:StartDespawnTimer()
            end
        end)

    end

end

function sLootbox:CloseBox(args, player)
    player:SetValue("CurrentLootbox", nil)
    self.players_opened[tostring(player:GetSteamId())] = nil
end

-- Refreshes loot if not all items were taken
function sLootbox:RefreshBox()
    self.despawn_timer = nil
    self:RespawnBox()
end

-- Hides the lootbox until it's ready to respawn
function sLootbox:HideBox()

    self:ForceClose()

    if self.despawn_timer then
        Timer.Clear(self.despawn_timer)
        self.despawn_timer = nil
    end

    Network:SendToPlayers(GetNearbyPlayersInCell(self.cell), "Inventory/RemoveLootbox", {cell = self.cell, uid = self.uid})
    self.active = false
    self.players_opened = {}

    LootManager:DespawnBox(self)

    Timer.SetTimeout(self:GetRespawnTime(), function()
        -- Respawn random box from the same tier
        LootManager:RespawnBox(self.tier)
    end)

end

-- Gets a dynamic respawn time based on how many players are nearby
function sLootbox:GetRespawnTime()

    local adjacent = GetAdjacentCells(self.cell)
    local num_nearby_players = 0

    for _, cell in pairs(adjacent) do
        num_nearby_players = num_nearby_players + #LootCells.Player[cell.x][cell.y]
    end

    local base = Lootbox.GeneratorConfig.box[self.tier].respawn * 60 * 1000

    return math.max(math.ceil(base / 2), base - num_nearby_players) -- Maximum half of normal time

end

function sLootbox:ForceClose(player)
    
    if IsValid(player) then
        Network:Send(player, "Inventory/ForceCloseLootbox")
        player:SetValue("CurrentLootbox", nil)
    elseif self.players_opened and count_table(self.players_opened) > 0 then
        Network:SendToPlayers(self.players_opened, "Inventory/ForceCloseLootbox")

        for id, p in pairs(self.players_opened) do
            if IsValid(p) then
                p:SetValue("CurrentLootbox", nil)
            end
        end

    end
end

-- Respawns the lootbox
function sLootbox:RespawnBox()

    -- Don't respawn box if someone is looting it
    --[[if count_table(self.players_opened) > 0 then
        self.despawn_timer = Timer.SetTimeout(Lootbox.Loot_Despawn_Time, function()
            self:RefreshBox()
        end)
        return
    end]]

    self:ForceClose()

    self.contents = ItemGenerator:GetLoot(self.tier)
    self.players_opened = {}

    self.active = true
    Network:SendToPlayers(GetNearbyPlayersInCell(self.cell), "Inventory/OneLootboxCellSync", self:GetSyncData())

end

-- Removes completely, never to respawn again
function sLootbox:Remove()

    self:ForceClose()

    if not self.cell then
        output_table(self)
        return
    end

    self.active = false
    Network:SendToPlayers(GetNearbyPlayersInCell(self.cell), "Inventory/RemoveLootbox", {cell = self.cell, uid = self.uid})

    if self.despawn_timer then Timer.Clear(self.despawn_timer) end

    LootCells.Loot[self.cell.x][self.cell.y][self.uid] = nil

    if self.network_subs then
        for k,v in pairs(self.network_subs) do
            Network:Unsubscribe(v)
        end
    end

    self.network_subs = nil
    self = nil

end

-- Syncs the single lootbox to all nearby players, used for dropboxes to make them instantly appear
function sLootbox:Sync()
    Network:SendToPlayers(GetNearbyPlayersInCell(self.cell), "Inventory/OneLootboxCellSync", self:GetSyncData())
end

-- Update contents to anyone who has it open
function sLootbox:UpdateToPlayers()
    Network:SendToPlayers(self.players_opened, "Inventory/LootboxSync", self:GetContentsSyncData())
end

function sLootbox:GetContentsData()

    local data = {}

    for k,v in pairs(self.contents) do
        data[k] = v:GetSyncObject()
    end

    return data

end

function sLootbox:GetSyncData()

    local data = {
        tier = self.tier,
        position = self.position,
        angle = self.angle,
        active = self.active,
        model_data = self.model_data,
        cell = self.cell,
        uid = self.uid
    }

    if self.is_stash then
        data.stash = self.stash:GetSyncData()
    end

    return data

end