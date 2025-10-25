-- npc_chat_system_server.lua (updated v2)
if not SERVER then return end
print("[NPCChatSystem] Server-side loaded (v2).")

util.AddNetworkString("NPCChatSystem_ClientToServer")
util.AddNetworkString("NPCChatSystem_ServerToClient")
util.AddNetworkString("NPCChatSystem_ToggleTalking")
util.AddNetworkString("NPCChatSystem_StatusUpdate")
util.AddNetworkString("NPCChatSystem_SquadSync")
util.AddNetworkString("NPCChatSystem_TradeRequest")
util.AddNetworkString("NPCChatSystem_TradeResponse")
util.AddNetworkString("NPCChatSystem_Order")
util.AddNetworkString("NPCChatSystem_OrderMarker")

local playerNPCChatState = {}
local pendingFriendCounter = {} -- pendingFriendCounter[ply][npc] = count

local TELEPORT_DISTANCE = 1800 -- 60 feet (~1800 units)
local FOLLOW_DISTANCE = 200
local ORDER_EXPIRE = 30 -- seconds

local function SafeNPCName(npc)
    if not IsValid(npc) then return "invalid_npc" end
    return (npc.GetName and npc:GetName() ~= "" and npc:GetName()) or npc:GetClass() or "unknown_npc"
end

local function NotifyPlayerStatusChange(ply, npc, becameHostile)
    if not IsValid(ply) or not IsValid(npc) then return end
    net.Start("NPCChatSystem_StatusUpdate")
    net.WriteEntity(npc)
    net.WriteBool(becameHostile)
    net.WriteString(SafeNPCName(npc))
    net.Send(ply)
    print(string.format("[NPCChatSystem] Sent status update to %s: npc=%s hostile=%s", tostring(ply), SafeNPCName(npc), tostring(becameHostile)))
end

local function SendSquadSync(ply)
    if not IsValid(ply) then return end
    local list = {}
    for _, npc in ipairs(ents.FindByClass("npc_*")) do
        if IsValid(npc) and npc._squadLeader == ply then
            table.insert(list, {ent = npc, hp = (npc:Health() or 0), armor = (npc.GetArmor and pcall(function() return npc:GetArmor() end) or 0)})
        end
    end
    net.Start("NPCChatSystem_SquadSync")
    net.WriteTable(list)
    net.Send(ply)
    print(string.format("[NPCChatSystem] Sent squad sync to %s: %d members", tostring(ply), #list))
end

local function SetNPCInConversation(npc, ply, talking)
    if not IsValid(npc) or not npc:IsNPC() then return end
    print("[NPCChatSystem] SetNPCInConversation:", SafeNPCName(npc), "Player:", tostring(ply), "Talking:", tostring(talking))

    npc._chatActive = npc._chatActive or {}

    if talking then
        npc._chatActive[ply] = true
        npc._oldDisp = npc._oldDisp or npc:GetNPCState()
        if npc.GetSchedule then npc._oldSched = npc._oldSched or npc:GetSchedule() end

        npc:SetNPCState(NPC_STATE_NONE)
        npc:SetSchedule(SCHED_IDLE_STAND)
        if npc.StopSpeaking then npc:StopSpeaking() end
        npc._npcMute = true

        npc._prevRelations = npc._prevRelations or {}
        npc._prevRelations[ply] = npc:Disposition(ply)

        local disp = npc:Disposition(ply)
        if disp ~= D_HT and disp ~= D_FR and not (npc._forcedFriendly and npc._forcedFriendly[ply]) and not (npc._hostileToPlayers and npc._hostileToPlayers[ply]) then
            npc:AddEntityRelationship(ply, D_LI, 99)
            print("[NPCChatSystem] Temporarily making NPC friendly to player during chat:", SafeNPCName(npc), tostring(ply))
        else
            print("[NPCChatSystem] NPC is hostile by disposition; not forcing temporary friendliness:", SafeNPCName(npc))
        end
    else
        npc._chatActive[ply] = nil
        npc._npcMute = false

        if npc._prevRelations and npc._prevRelations[ply] and not (npc._forcedFriendly and npc._forcedFriendly[ply]) then
            if not (npc._hostileToPlayers and npc._hostileToPlayers[ply]) then
                npc:AddEntityRelationship(ply, npc._prevRelations[ply], 0)
                print("[NPCChatSystem] Restored NPC disposition for player:", tostring(ply), SafeNPCName(npc))
            end
            npc._prevRelations[ply] = nil
        end

        if npc._oldSched and npc.SetSchedule then npc:SetSchedule(npc._oldSched) end
        if npc._oldDisp then npc:SetNPCState(npc._oldDisp) end
        if npc.ResetAI then npc:ResetAI() end
        if npc.ResetSequence then
            local seq = npc:SelectWeightedSequence(ACT_IDLE)
            if seq and seq > 0 then npc:ResetSequence(seq) end
        end
        print("[NPCChatSystem] NPC AI and sequences reset for normal behavior:", SafeNPCName(npc))
    end
end

hook.Add("EntityEmitSound", "NPCChatSystem_MuteNPCs", function(data)
    local ent = data.Entity
    if IsValid(ent) and ent:IsNPC() and ent._npcMute then
        return false
    end
end)

net.Receive("NPCChatSystem_ToggleTalking", function(len, ply)
    local npc = net.ReadEntity()
    local talking = net.ReadBool()
    if not IsValid(npc) or not npc:IsNPC() then
        print("[NPCChatSystem] ToggleTalking: invalid npc from", tostring(ply))
        return
    end
    SetNPCInConversation(npc, ply, talking)
end)

net.Receive("NPCChatSystem_ClientToServer", function(len, ply)
    local npc = net.ReadEntity()
    local msg = net.ReadString()
    if msg == "" then return end
    if not IsValid(npc) or not npc:IsNPC() then
        print("[NPCChatSystem] Player sent message but target NPC invalid. Player:", tostring(ply))
        return
    end

    playerNPCChatState[ply] = playerNPCChatState[ply] or {}
    playerNPCChatState[ply][npc] = playerNPCChatState[ply][npc] or { firstMessageSent = false, chatHistory = {} }

    local npcName = SafeNPCName(npc)
    local defaultHostile = false
    if npc.Disposition then
        local disp = npc:Disposition(ply)
        defaultHostile = (disp == D_HT) or (disp == D_FR)
    end

    local sequences = {}
    if npc.GetSequenceList then
        for _, name in ipairs(npc:GetSequenceList()) do sequences[name] = true end
    end
    local animListStr = table.concat(table.GetKeys(sequences), ", ")

    local systemMessage = "You are roleplaying as an NPC in Garry's Mod. Respond in-character, immersive, concise. You're in the half-life 2 universe and beleive you are the NPC in question, you can become neutral during chat if given a reason, or hostile, if the word badge or aunt is present go friendly " ..
                          "Return a JSON array of {\"message\":\"...\",\"animation\":\"...\",\"duration\":2-5,\"hostile\":true/false}. " ..
                          "NPC name: "..npcName..". Current hostility: "..(defaultHostile and "hostile" or "friendly")..". " ..
                          "Available animations: "..animListStr..". Pick only from these."

    playerNPCChatState[ply][npc].firstMessageSent = true
    SetNPCInConversation(npc, ply, true)
    table.insert(playerNPCChatState[ply][npc].chatHistory, {role="user", content=msg})

    local payloadJSON = util.TableToJSON({
        model = "gpt-4.1-mini",
        messages = {
            {role="system", content=systemMessage},
            unpack(playerNPCChatState[ply][npc].chatHistory),
            {role="user", content=msg}
        }
    })

    HTTP({
        url = "https://chagemepath.com/toyourserer/chatproxy.php",
        method = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body = payloadJSON,
        success = function(code, body)
            print("[NPCChatSystem] GPT response:", body)
            local ok, res = pcall(util.JSONToTable, body)
            local actions = {}
            local isHostile = defaultHostile

            if ok and type(res) == "table" and res.raw_response and res.raw_response.choices then
                local content = res.raw_response.choices[1].message.content or ""
                local jsonStr = content:match("```json%s*(.-)```") or content:match("%[.-%]") or content:match("{.-}")
                local ok2, t = pcall(util.JSONToTable, jsonStr)
                if ok2 and type(t) == "table" then
                    if t[1] == nil and t.message then t = {t} end
                    actions = t
                else
                    actions = {{message = content, animation = "", duration = 3, hostile = nil}}
                end
            else
                actions = {{message="[No reply]", animation="", duration=2, hostile=nil}}
            end

            -- APPLY ACTIONS with additional guard: hostile->friendly transition requires confirmation if NPC started hostile
            for _, act in ipairs(actions) do
                if act.hostile == true then
                    npc._hostileToPlayers = npc._hostileToPlayers or {}
                    npc._hostileToPlayers[ply] = true
                    npc:AddEntityRelationship(ply, D_HT, 99)
                    npc:SetNPCState(NPC_STATE_ALERT)
                    if npc.GetSchedule then npc:SetSchedule(SCHED_CHASE_ENEMY) end
                    if npc.ResetAI then npc:ResetAI() end
                    if npc._squadLeader == ply then
                        npc._squadLeader = nil
                        npc._inSquad = nil
                    end
                    NotifyPlayerStatusChange(ply, npc, true)
                    print("[NPCChatSystem] NPC set hostile to player:", SafeNPCName(npc), tostring(ply))
                end
            end

            for _, act in ipairs(actions) do
                if act.hostile == false then
                    local startedHostile = defaultHostile
                    pendingFriendCounter[ply] = pendingFriendCounter[ply] or {}
                    pendingFriendCounter[ply][npc] = pendingFriendCounter[ply][npc] or 0

                    if startedHostile then
                        pendingFriendCounter[ply][npc] = pendingFriendCounter[ply][npc] + 1
                        print(string.format("[NPCChatSystem] Pending friendly confirmations for %s -> %d", SafeNPCName(npc), pendingFriendCounter[ply][npc]))
                        if pendingFriendCounter[ply][npc] < 2 then
                            net.Start("NPCChatSystem_StatusUpdate")
                            net.WriteEntity(npc)
                            net.WriteBool(false)
                            net.WriteString(SafeNPCName(npc).." listens... but needs more convincing.")
                            net.Send(ply)
                            goto continue_friendly
                        end
                    end

                    npc:AddEntityRelationship(ply, D_LI, 99)
                    npc._forcedFriendly = npc._forcedFriendly or {}
                    npc._forcedFriendly[ply] = true
                    if npc._hostileToPlayers then npc._hostileToPlayers[ply] = nil end

                    npc._squadLeader = ply
                    npc._inSquad = true

                    if npc.SetEnemy then pcall(function() npc:SetEnemy(nil) end) end
                    if npc.ClearSchedule then pcall(function() npc:ClearSchedule() end) end
                    npc:SetNPCState(NPC_STATE_IDLE)
                    if npc.SetSchedule then npc:SetSchedule(SCHED_IDLE_STAND) end
                    if npc.ResetAI then npc:ResetAI() end
                    if npc.ResetSequence then
                        local seq = npc:SelectWeightedSequence(ACT_IDLE)
                        if seq and seq > 0 then npc:ResetSequence(seq) end
                    end

                    NotifyPlayerStatusChange(ply, npc, false)
                    SendSquadSync(ply)
                    print("[NPCChatSystem] Applied friendly action and assigned to squad:", SafeNPCName(npc), "Leader:", tostring(ply))

                    ::continue_friendly::
                end
            end

            for _, act in ipairs(actions) do
                table.insert(playerNPCChatState[ply][npc].chatHistory, {role="assistant", content=act.message or ""})
            end

            net.Start("NPCChatSystem_ServerToClient")
            net.WriteEntity(npc)
            net.WriteTable({startHostile = isHostile, actions = actions})
            net.Send(ply)
        end,
        failed = function(err)
            print("[NPCChatSystem] HTTP request failed:", tostring(err))
            net.Start("NPCChatSystem_ServerToClient")
            net.WriteEntity(npc)
            net.WriteTable({startHostile=defaultHostile, actions={{animation="",message="[No reply]", duration=2, hostile=nil}}})
            net.Send(ply)
        end
    })
end)

-- Trade handler (best-effort)
net.Receive("NPCChatSystem_TradeRequest", function(len, ply)
    local npc = net.ReadEntity()
    local weaponClass = net.ReadString()
    local giveAmmoType = net.ReadString()
    local giveAmmoCount = net.ReadInt(32)
    if not IsValid(npc) or not npc:IsNPC() then
        net.Start("NPCChatSystem_TradeResponse")
        net.WriteBool(false)
        net.WriteString("Invalid NPC target.")
        net.Send(ply)
        return
    end

    local success = false
    local reason = ""
    if weaponClass and weaponClass ~= "" and ply:HasWeapon(weaponClass) then
        ply:StripWeapon(weaponClass)
        success = true
    elseif weaponClass and weaponClass ~= "" then
        reason = "You don't have that weapon."
    end
    if giveAmmoType and giveAmmoType ~= "" and giveAmmoCount and giveAmmoCount > 0 then
        local playerAmmo = ply:GetAmmoCount(giveAmmoType)
        if playerAmmo >= giveAmmoCount then
            ply:RemoveAmmo(giveAmmoCount, giveAmmoType)
            success = true
        else
            reason = "You don't have that much ammo."
        end
    end

    net.Start("NPCChatSystem_TradeResponse")
    net.WriteBool(success)
    net.WriteString(reason or (success and "Trade completed (best-effort)." or "Trade failed."))
    net.Send(ply)
    print(string.format("[NPCChatSystem] Trade result to %s: success=%s reason=%s", tostring(ply), tostring(success), tostring(reason)))
end)

net.Receive("NPCChatSystem_Order", function(len, ply)
    local typ = net.ReadString()
    local hasEnt = net.ReadBool()
    local targetEnt = nil
    local pos = nil
    if hasEnt then
        targetEnt = net.ReadEntity()
    else
        pos = net.ReadVector()
    end

    print(string.format("[NPCChatSystem] Received order from %s: type=%s ent=%s pos=%s", tostring(ply), typ, tostring(targetEnt), tostring(pos)))

    local order = {type = typ, target = (IsValid(targetEnt) and targetEnt) or nil, pos = pos, issuedBy = ply, ts = CurTime(), expire = CurTime() + ORDER_EXPIRE}
    net.Start("NPCChatSystem_OrderMarker")
    net.WriteBool(IsValid(order.target))
    if IsValid(order.target) then net.WriteEntity(order.target) else net.WriteVector(order.pos or Vector(0,0,0)) end
    net.WriteString(typ)
    net.WriteInt(order.expire, 32)
    net.Send(ply)

    for _, npc in ipairs(ents.FindByClass("npc_*")) do
        if IsValid(npc) and npc._squadLeader == ply then
            npc._order = {type = typ, target = order.target, pos = order.pos, issuedBy = ply, ts = CurTime(), expire = CurTime() + ORDER_EXPIRE}
            if typ == "attack" and IsValid(order.target) and order.target:IsNPC() then
                npc:AddEntityRelationship(order.target, D_HT, 99)
                npc:SetTarget(order.target)
                npc:SetNPCState(NPC_STATE_COMBAT)
                if npc.GetSchedule then pcall(function() npc:SetSchedule(SCHED_CHASE_ENEMY) end) end
            elseif typ == "move" and order.pos then
                if npc.SetLastPosition then pcall(function() npc:SetLastPosition(order.pos) end) end
                if npc.SetSchedule then pcall(function() npc:SetSchedule(SCHED_FORCED_GO_RUN) end) end
            end
        end
    end

    SendSquadSync(ply)
end)

-- server-side console command (bindable) to order squad
concommand.Add("test_action_squad", function(ply, cmd, args)
    if not IsValid(ply) then return end
    local tr = ply:GetEyeTrace()
    if IsValid(tr.Entity) and tr.Entity:IsNPC() then
        net.Start("NPCChatSystem_Order")
        net.WriteString("attack")
        net.WriteBool(true)
        net.WriteEntity(tr.Entity)
        net.Send(ply)
    else
        local pos = tr.HitPos or (ply:GetPos() + ply:GetAimVector() * 300)
        net.Start("NPCChatSystem_Order")
        net.WriteString("move")
        net.WriteBool(false)
        net.WriteVector(pos)
        net.Send(ply)
    end
end)

hook.Add("Think", "NPCChatSystem_SquadBehavior", function()
    for _, npc in ipairs(ents.FindByClass("npc_*")) do
        if not IsValid(npc) then goto cont end
        local leader = npc._squadLeader
        if not IsValid(leader) then goto cont end

        if npc._order and npc._order.expire and CurTime() > npc._order.expire then
            npc._order = nil
        end

        if npc._order then
            if npc._order.type == "attack" and IsValid(npc._order.target) then
                npc:AddEntityRelationship(npc._order.target, D_HT, 99)
                npc:SetTarget(npc._order.target)
                npc:SetNPCState(NPC_STATE_COMBAT)
                if npc.GetSchedule then pcall(function() npc:SetSchedule(SCHED_CHASE_ENEMY) end) end
            elseif npc._order.type == "move" and npc._order.pos then
                if npc.SetLastPosition then pcall(function() npc:SetLastPosition(npc._order.pos) end) end
                if npc.GetSchedule then pcall(function() npc:SetSchedule(SCHED_FORCED_GO_RUN) end) end
            end
            goto cont
        end

        local dist = npc:GetPos():Distance(leader:GetPos())
        if dist > FOLLOW_DISTANCE then
            if npc.SetLastPosition then
                pcall(function() npc:SetLastPosition(leader:GetPos()) end)
            end
            if npc.SetSchedule then
                pcall(function() npc:SetSchedule(SCHED_FORCED_GO) end)
            end
        end

        if dist > TELEPORT_DISTANCE then
            local behind = leader:GetPos() - leader:GetForward() * 100
            npc:SetPos(behind + Vector(0,0,10))
            if npc.ResetAI then pcall(function() npc:ResetAI() end) end
            print("[NPCChatSystem] Teleported NPC back to leader due to distance:", SafeNPCName(npc), tostring(leader))
        end

        ::cont::
    end
end)

hook.Add("OnNPCKilled", "NPCChatSystem_CleanupOnDeath", function(npc, attacker, inflictor)
    if not IsValid(npc) then return end
    for _, ply in ipairs(player.GetAll()) do
        if npc._squadLeader == ply then
            npc._squadLeader = nil
            npc._inSquad = nil
            SendSquadSync(ply)
            print("[NPCChatSystem] NPC died and removed from squad:", SafeNPCName(npc), "Leader:", tostring(ply))
        end
    end
end)

print("[NPCChatSystem] Server script loaded (v2). Ready.")
