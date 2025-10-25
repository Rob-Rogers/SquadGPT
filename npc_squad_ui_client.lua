-- npc_squad_ui_client.lua (v2)
if not CLIENT then return end
print("[NPCChatSystem] Client-side Squad UI loaded (v2).")

local PANEL_WIDTH = 420
local PANEL_HEIGHT = 380

local function SafeNPCName(npc)
    if not IsValid(npc) then return "invalid_npc" end
    return (npc.GetName and npc:GetName() ~= "" and npc:GetName()) or npc:GetClass() or "unknown_npc"
end

local function CreateSquadUI()
    local frame = vgui.Create("DFrame")
    frame:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    frame:Center()
    frame:SetTitle("NPC Squad Manager")
    frame:MakePopup()

    local infoLabel = vgui.Create("DLabel", frame)
    infoLabel:SetPos(10, 25)
    infoLabel:SetSize(PANEL_WIDTH-20, 20)
    infoLabel:SetTextColor(Color(255,255,255))
    infoLabel:SetFont("DermaDefaultBold")
    infoLabel:SetWrap(true)

    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:Dock(FILL)
    scroll:DockMargin(5, 50, 5, 35)

    local layout = vgui.Create("DIconLayout", scroll)
    layout:Dock(FILL)
    layout:SetSpaceY(5)
    frame.layout = layout

    local function RefreshSquad()
        if not IsValid(frame) or not IsValid(frame.layout) then
            if timer.Exists("NPCChatSystem_SquadUI_Refresh") then
                timer.Remove("NPCChatSystem_SquadUI_Refresh")
            end
            return
        end

        frame.layout:Clear()
        local cached = LocalPlayer()._npcSquadCached or {}
        local squad = {}
        for _, ent in ipairs(cached) do
            if type(ent) == "table" and IsValid(ent.ent) then
                table.insert(squad, ent.ent)
            elseif IsValid(ent) then
                table.insert(squad, ent)
            end
        end

        if #squad == 0 then
            infoLabel:SetText("Your squad is empty. Talk to NPCs to convince them to join you!")
        else
            infoLabel:SetText("Squad Members: "..#squad)
        end

        table.sort(squad, function(a,b)
            return (a:Health() or 0) < (b:Health() or 0)
        end)

        for _, npc in ipairs(squad) do
            local npcPanel = vgui.Create("DPanel")
            npcPanel:SetSize(PANEL_WIDTH - 25, 90)

            local nameLabel = vgui.Create("DLabel", npcPanel)
            nameLabel:SetText(SafeNPCName(npc))
            nameLabel:SetPos(5, 5)
            nameLabel:SizeToContents()

            local hp = IsValid(npc) and npc:Health() or 0
            local maxhp = IsValid(npc) and (npc:GetMaxHealth() or 100) or 100
            local armor = 0
            if IsValid(npc) then
                armor = (npc.GetArmor and pcall(function() return npc:GetArmor() end) or 0) or 0
            end

            local infoLabel2 = vgui.Create("DLabel", npcPanel)
            infoLabel2:SetText(string.format("HP: %d / %d   Armor: %d", hp, maxhp, armor))
            infoLabel2:SetPos(5, 25)
            infoLabel2:SizeToContents()

            local healthBar = vgui.Create("DPanel", npcPanel)
            healthBar:SetPos(5, 45)
            healthBar:SetSize(PANEL_WIDTH - 220, 18)
            healthBar.Paint = function(pnl, w, h)
                local hpv = IsValid(npc) and npc:Health() or 0
                local maxhpv = IsValid(npc) and (npc:GetMaxHealth() or 100) or 100
                local frac = math.Clamp((hpv or 0)/(maxhpv or 100), 0, 1)
                local color = Color(0,255,0)
                if frac < 0.5 then color = Color(255,255,0) end
                if frac < 0.25 then color = Color(255,0,0) end
                surface.SetDrawColor(50,50,50)
                surface.DrawRect(0,0,w,h)
                surface.SetDrawColor(color)
                surface.DrawRect(0,0,w*frac,h)
            end

            local dismissBtn = vgui.Create("DButton", npcPanel)
            dismissBtn:SetText("Dismiss")
            dismissBtn:SetSize(70, 28)
            dismissBtn:SetPos(PANEL_WIDTH - 130, 50)
            dismissBtn.DoClick = function()
                RunConsoleCommand("npc_squad_dismiss", SafeNPCName(npc))
                timer.Simple(0.2, function() if IsValid(frame) then frame:Close() end end)
            end

            local orderBtn = vgui.Create("DButton", npcPanel)
            orderBtn:SetText("Order (Attack/Move)")
            orderBtn:SetSize(150, 28)
            orderBtn:SetPos(PANEL_WIDTH - 290, 50)
            orderBtn.DoClick = function()
                local ply = LocalPlayer()
                local tr = util.TraceLine({
                    start = ply:GetShootPos(),
                    endpos = ply:GetShootPos() + ply:GetAimVector()*4000,
                    filter = ply
                })
                if IsValid(tr.Entity) and tr.Entity:IsNPC() then
                    net.Start("NPCChatSystem_Order")
                    net.WriteString("attack")
                    net.WriteBool(true)
                    net.WriteEntity(tr.Entity)
                    net.SendToServer()
                else
                    local pos = tr.HitPos or (ply:GetPos() + ply:GetAimVector()*300)
                    net.Start("NPCChatSystem_Order")
                    net.WriteString("move")
                    net.WriteBool(false)
                    net.WriteVector(pos)
                    net.SendToServer()
                end
            end

            local tradeBtn = vgui.Create("DButton", npcPanel)
            tradeBtn:SetText("Trade")
            tradeBtn:SetSize(70,28)
            tradeBtn:SetPos(PANEL_WIDTH - 70, 50)
            tradeBtn.DoClick = function()
                local tradeFrame = vgui.Create("DFrame")
                tradeFrame:SetSize(360,220)
                tradeFrame:Center()
                tradeFrame:SetTitle("Trade with "..SafeNPCName(npc))
                tradeFrame:MakePopup()

                local wepList = vgui.Create("DPanelList", tradeFrame)
                wepList:Dock(FILL)
                wepList:EnableHorizontal(false)
                wepList:EnableVerticalScrollbar(true)

                for _, wep in ipairs(LocalPlayer():GetWeapons()) do
                    local wpnClass = wep:GetClass()
                    local entry = vgui.Create("DPanel")
                    entry:SetTall(30)
                    local label = vgui.Create("DLabel", entry)
                    label:SetText(wpnClass)
                    label:SetPos(5,5)
                    label:SizeToContents()
                    local giveBtn = vgui.Create("DButton", entry)
                    giveBtn:SetText("Give Weapon")
                    giveBtn:SetPos(200,2)
                    giveBtn:SetSize(120,24)
                    giveBtn.DoClick = function()
                        net.Start("NPCChatSystem_TradeRequest")
                        net.WriteEntity(npc)
                        net.WriteString(wpnClass)
                        net.WriteString("")
                        net.WriteInt(0,32)
                        net.SendToServer()
                        tradeFrame:Close()
                    end
                    wepList:AddItem(entry)
                end

                local ammoTypes = {"AR2","SMG1","357","Pistol","Buckshot","XBowBolt","Grenade"}
                local ammoPanel = vgui.Create("DPanel")
                ammoPanel:SetTall(90)
                local ammoLabel = vgui.Create("DLabel", ammoPanel)
                ammoLabel:SetText("Give Ammo (choose type and amount):")
                ammoLabel:SetPos(5,5)
                ammoLabel:SizeToContents()
                local ammoTypeCombo = vgui.Create("DComboBox", ammoPanel)
                ammoTypeCombo:SetPos(5,25)
                ammoTypeCombo:SetSize(150,20)
                for _, at in ipairs(ammoTypes) do ammoTypeCombo:AddChoice(at) end
                ammoTypeCombo:ChooseOptionID(1)
                local ammoAmount = vgui.Create("DTextEntry", ammoPanel)
                ammoAmount:SetPos(170,25)
                ammoAmount:SetSize(60,20)
                ammoAmount:SetText("10")
                local giveAmmoBtn = vgui.Create("DButton", ammoPanel)
                giveAmmoBtn:SetText("Give Ammo")
                giveAmmoBtn:SetPos(240,24)
                giveAmmoBtn:SetSize(100,22)
                giveAmmoBtn.DoClick = function()
                    local atype = ammoTypeCombo:GetValue()
                    local amount = tonumber(ammoAmount:GetValue()) or 0
                    if amount <= 0 then return end
                    net.Start("NPCChatSystem_TradeRequest")
                    net.WriteEntity(npc)
                    net.WriteString("")
                    net.WriteString(atype)
                    net.WriteInt(amount,32)
                    net.SendToServer()
                    tradeFrame:Close()
                end
                wepList:AddItem(ammoPanel)

                local closeBtn = vgui.Create("DButton", tradeFrame)
                closeBtn:Dock(BOTTOM)
                closeBtn:SetText("Close")
            end

            layout:Add(npcPanel)
        end
    end

    RefreshSquad()
    timer.Create("NPCChatSystem_SquadUI_Refresh", 1, 0, RefreshSquad)

    frame.OnClose = function()
        if timer.Exists("NPCChatSystem_SquadUI_Refresh") then
            timer.Remove("NPCChatSystem_SquadUI_Refresh")
        end
    end
end

concommand.Add("npc_squad_ui", function()
    CreateSquadUI()
end)

net.Receive("NPCChatSystem_SquadSync", function()
    local list = net.ReadTable() or {}
    print(string.format("[SquadUI] Received squad sync: %d entries", #list))
    LocalPlayer()._npcSquadCached = list
end)
