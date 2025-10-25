-- npc_chat_system_client.lua (v2)
if not CLIENT then return end
print("[NPCChatSystem] Client-side loaded (v2).")

local MAX_UI_LINES = 200
local MAX_CLIENT_MSG_LEN = 400
local SEND_BUTTON_TIMEOUT = 10
local MAX_DISTANCE = 180

local orderMarkers = {}

local function SafeNPCName(npc)
    if not IsValid(npc) then return "invalid_npc" end
    return (npc.GetName and npc:GetName() ~= "" and npc:GetName()) or npc:GetClass() or "unknown_npc"
end

local function sanitizeIncoming(text, maxlen)
    if not text then return "" end
    text = tostring(text):gsub("\r", ""):gsub("\n\n\n+", "\n\n")
    if #text > maxlen then text = string.sub(text,1,maxlen).."..." end
    return text
end

local function TrimLayoutMessages(layout)
    if not IsValid(layout) then return end
    local children = layout:GetChildren()
    while #children > MAX_UI_LINES do
        if IsValid(children[1]) then children[1]:Remove() end
        children = layout:GetChildren()
    end
end

local function AddChatLine(frame, color, prefix, text)
    if not IsValid(frame) or not IsValid(frame.chatLayout) then return end
    text = sanitizeIncoming(text, 2000)
    local lbl = vgui.Create("DLabel")
    lbl:SetText(prefix .. text)
    lbl:SetWrap(true)
    lbl:SetAutoStretchVertical(true)
    lbl:SetTextColor(color)
    lbl:SetWide(frame:GetWide() - 40)
    lbl:SizeToContentsY()
    frame.chatLayout:Add(lbl)
    frame.chatLayout:InvalidateLayout(true)
    TrimLayoutMessages(frame.chatLayout)
    timer.Simple(0.05,function()
        if IsValid(frame.scrollPanel) then frame.scrollPanel:ScrollToChild(lbl) end
    end)
end

local function SafeRepositionElements(frame)
    if not IsValid(frame) then return end
    frame.textEntry:SetPos(10, frame:GetTall()-50)
    frame.sendButton:SetPos(340, frame:GetTall()-50)
    frame.textEntry:SetSize(320,25)
end

local function CreateChatFrame(npc)
    if not IsValid(npc) then return end
    print("[NPCChatSystem] Creating chat frame for NPC:\t"..SafeNPCName(npc))

    local frame = vgui.Create("DFrame")
    frame:SetSize(420,420)
    frame:Center()
    frame:SetTitle("NPC CHAT - "..SafeNPCName(npc))
    frame:MakePopup()
    frame:SetDeleteOnClose(true)
    frame.targetNPC = npc

    net.Start("NPCChatSystem_ToggleTalking")
    net.WriteEntity(npc)
    net.WriteBool(true)
    net.SendToServer()

    frame.OnClose = function()
        if IsValid(frame.targetNPC) then
            net.Start("NPCChatSystem_ToggleTalking")
            net.WriteEntity(frame.targetNPC)
            net.WriteBool(false)
            net.SendToServer()
        end
        if frame.sendTimerName then timer.Remove(frame.sendTimerName) end
    end

    local scrollPanel = vgui.Create("DScrollPanel", frame)
    scrollPanel:Dock(FILL)
    scrollPanel:DockMargin(5,30,5,60)
    frame.scrollPanel = scrollPanel

    local chatLayout = vgui.Create("DIconLayout", scrollPanel)
    chatLayout:Dock(FILL)
    chatLayout:SetSpaceY(5)
    chatLayout:SetSpaceX(0)
    frame.chatLayout = chatLayout

    local textEntry = vgui.Create("DTextEntry", frame)
    textEntry:SetPos(10, frame:GetTall()-50)
    textEntry:SetSize(320,25)
    textEntry:SetEnterAllowed(true)
    textEntry.OnEnter = function()
        if IsValid(frame.sendButton) then frame.sendButton:DoClick() end
    end
    textEntry:RequestFocus()
    frame.textEntry = textEntry

    local sendButton = vgui.Create("DButton", frame)
    sendButton:SetPos(340, frame:GetTall()-50)
    sendButton:SetSize(70,25)
    sendButton:SetText("Send")
    frame.sendButton = sendButton

    frame.OnSizeChanged = function()
        SafeRepositionElements(frame)
    end

    local function resetSendButton()
        if IsValid(frame) and IsValid(frame.sendButton) then
            frame.sendButton:SetDisabled(false)
            frame.sendButton:SetText("Send")
        end
        if frame.sendTimerName then timer.Remove(frame.sendTimerName) end
    end

    sendButton.DoClick = function()
        local userMessage = textEntry:GetValue() or ""
        userMessage = string.Trim(userMessage)
        if userMessage == "" or not IsValid(frame.targetNPC) then return end
        if #userMessage > MAX_CLIENT_MSG_LEN then
            userMessage = string.sub(userMessage, 1, MAX_CLIENT_MSG_LEN)
        end

        AddChatLine(frame, Color(0,255,0), "You: ", userMessage)
        textEntry:SetText("")
        sendButton:SetDisabled(true)
        sendButton:SetText("...")

        frame.sendTimerName = "NPCChat_SendTimeout_" .. tostring(frame)
        timer.Create(frame.sendTimerName, SEND_BUTTON_TIMEOUT, 1, resetSendButton)

        net.Start("NPCChatSystem_ClientToServer")
        net.WriteEntity(frame.targetNPC)
        net.WriteString(userMessage)
        net.SendToServer()
    end
end

net.Receive("NPCChatSystem_ServerToClient", function()
    local npc = net.ReadEntity()
    local tbl = net.ReadTable()
    if not IsValid(npc) or not tbl then return end

    for _, frame in pairs(vgui.GetWorldPanel():GetChildren()) do
        if IsValid(frame) and frame.chatLayout and frame.targetNPC == npc then
            for _, act in ipairs(tbl.actions or {}) do
                AddChatLine(frame, Color(255,255,255), "NPC: ", act.message or "")

                if IsValid(npc) then
                    if act.animation and act.animation ~= "" then
                        local seq = npc:LookupSequence(act.animation)
                        if seq and seq > 0 then npc:ResetSequence(seq) end
                    end

                    if npc.MouthMove then
                        npc:MouthMove(1)
                        timer.Simple(math.min(act.duration or 2, 2), function()
                            if IsValid(npc) then npc:MouthMove(0) end
                        end)
                    end
                end
            end

            if IsValid(frame.sendButton) then
                frame.sendButton:SetDisabled(false)
                frame.sendButton:SetText("Send")
                if frame.sendTimerName then timer.Remove(frame.sendTimerName) end
            end
        end
    end
end)

net.Receive("NPCChatSystem_StatusUpdate", function()
    local npc = net.ReadEntity()
    local becameHostile = net.ReadBool()
    local msg = net.ReadString()
    if not IsValid(LocalPlayer()) then return end
    if becameHostile then
        chat.AddText(Color(255,100,100), "[NPCChatSystem] ", Color(255,255,255), msg or (IsValid(npc) and SafeNPCName(npc).." became hostile to you!" or "An NPC became hostile."))
        print("[NPCChatSystem] Received status update: hostile:", tostring(msg))
    else
        chat.AddText(Color(100,255,100), "[NPCChatSystem] ", Color(255,255,255), msg or (IsValid(npc) and SafeNPCName(npc).." is now friendly and joined your squad!" or "An NPC is now friendly."))
        print("[NPCChatSystem] Received status update: friendly:", tostring(msg))
    end
end)

net.Receive("NPCChatSystem_SquadSync", function()
    local list = net.ReadTable() or {}
    print(string.format("[NPCChatSystem] Squad sync received: %d members", #list))
    LocalPlayer()._npcSquadCached = list
end)

net.Receive("NPCChatSystem_OrderMarker", function()
    local hasEnt = net.ReadBool()
    if hasEnt then
        local ent = net.ReadEntity()
        local typ = net.ReadString()
        local expire = net.ReadInt(32)
        if IsValid(ent) then
            table.insert(orderMarkers, {ent = ent, pos = ent:GetPos(), type = typ, expire = expire})
        end
    else
        local pos = net.ReadVector()
        local typ = net.ReadString()
        local expire = net.ReadInt(32)
        table.insert(orderMarkers, {ent = nil, pos = pos, type = typ, expire = expire})
    end
end)

hook.Add("HUDPaint", "NPCChatSystem_OrderMarkers", function()
    local now = CurTime()
    local remove = {}
    for i, mk in ipairs(orderMarkers) do
        if mk.expire and now > mk.expire then table.insert(remove, i) goto cont end
        local pos = (IsValid(mk.ent) and mk.ent:GetPos()) or mk.pos
        if not pos then table.insert(remove, i) goto cont end
        local screen = pos:ToScreen()
        surface.SetDrawColor(255,255,255,200)
        surface.DrawOutlinedRect(screen.x-12, screen.y-12, 24, 24)
        draw.SimpleText(mk.type == "attack" and "Attack" or "Move", "DermaDefaultBold", screen.x, screen.y - 18, Color(255,255,255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if IsValid(mk.ent) and LocalPlayer():GetPos():Distance(pos) < 200 then table.insert(remove, i) end
        ::cont::
    end
    for i = #remove,1,-1 do table.remove(orderMarkers, remove[i]) end
end)

net.Receive("NPCChatSystem_TradeResponse", function()
    local ok = net.ReadBool()
    local msg = net.ReadString()
    if ok then
        chat.AddText(Color(100,255,100), "[NPCChatSystem] ", Color(255,255,255), msg)
    else
        chat.AddText(Color(255,100,100), "[NPCChatSystem] Trade failed: ", Color(255,255,255), msg)
    end
end)

concommand.Add("test_chat", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
    local tr = util.TraceLine({
        start = ply:GetShootPos(),
        endpos = ply:GetShootPos() + ply:GetAimVector()*MAX_DISTANCE,
        filter = ply
    })
    if IsValid(tr.Entity) and tr.Entity:IsNPC() then
        CreateChatFrame(tr.Entity)
    else
        chat.AddText(Color(255,100,100), "You are not looking at a valid NPC.")
    end
end)

concommand.Add("test_action_squad", function()
    local ply = LocalPlayer()
    if not IsValid(ply) then return end
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
end)

hook.Add("Think", "NPCChatSystem_CloseDeadOrFarChats_Client", function()
    for _, f in pairs(vgui.GetWorldPanel():GetChildren()) do
        if IsValid(f) and f.targetNPC then
            local npc = f.targetNPC
            local close = IsValid(npc) and npc:GetPos():Distance(LocalPlayer():GetPos()) <= MAX_DISTANCE
            if not IsValid(npc) or not close then
                f:Close()
            end
        end
    end
end)

print("[NPCChatSystem] Client script loaded (v2). Ready.")
