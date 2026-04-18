local require = GLOBAL.require
local Inv = require "widgets/inventorybar"

Assets =
{
    Asset("IMAGE", "images/char.tex"),
    Asset("ATLAS", "images/char.xml"),
}

-- Register the new equip slot into the global tables
GLOBAL.EQUIPSLOTS.CHAR = "char"

---------------------------------------------------------------------------
-- Character → items mapping
-- Only characters listed here get the CHAR slot
---------------------------------------------------------------------------
local CHAR_ITEMS_BY_CHARACTER = {
    wathgrithr = {
        "wathgrithr_shield",
    },
    wolfgang = {
        "dumbbell",
        "dumbbell_golden",
        "dumbbell_marble",
        "dumbbell_gem",
        "dumbbell_heat",
        "dumbbell_redgem",
        "dumbbell_bluegem"
    },
    waxwell = {
        "waxwelljournal",
    },
    wanda = {
        "pocketwatch_heal",
        "pocketwatch_warp",
    },
}

-- Flat list and lookup set (built from the mapping)
local CHAR_ITEMS = {}
local ALLOWED = {}
for _, items in pairs(CHAR_ITEMS_BY_CHARACTER) do
    for _, name in ipairs(items) do
        table.insert(CHAR_ITEMS, name)
        ALLOWED[name] = true
    end
end

-- Check whether a character prefab has CHAR-slot items
local function CharacterHasSlot(prefab)
    return CHAR_ITEMS_BY_CHARACTER[prefab] ~= nil
end

-- Hook the inventory bar to display the extra slot (only for supported characters)
local function EnsureCharSlot(self)
    if self.owner and CharacterHasSlot(self.owner.prefab) then
        if not self._charslot_added then
            self._charslot_added = true
            self:AddEquipSlot(GLOBAL.EQUIPSLOTS.CHAR, "images/char.xml", "char.tex")
        end
    end

    -- Auto-scale bg to fit actual slot count (mirrors vanilla's total_w formula)
    local W = 68
    local SEP = 12
    local INTERSEP = 28
    local inventory = self.owner.replica.inventory
    local num_slots = inventory:GetNumSlots()
    local num_equip = #self.equipslotinfo
    local has_inspect = self.inspectcontrol ~= nil or not self.controller_build
    local num_buttons = has_inspect and 1 or 0
    local num_slotintersep = math.ceil(num_slots / 5)
    local num_equipintersep = num_buttons > 0 and 1 or 0
    local total_w = (num_slots + num_equip + num_buttons) * W
                  + (num_slots + num_equip + num_buttons - num_slotintersep - num_equipintersep - 1) * SEP
                  + (num_slotintersep + num_equipintersep) * INTERSEP

    -- Vanilla baseline: 15 inv + 3 equip + 1 button → total_w = 1560, scale = 1.22
    local BASE_TOTAL_W = 1560
    local BASE_SCALE   = 1.22
    local scale_x = (total_w / BASE_TOTAL_W) * BASE_SCALE
    self.bg:SetScale(scale_x, 1, 1.25)
    self.bgcover:SetScale(scale_x, 1, 1.25)

    if self.inspectcontrol then
        self.inspectcontrol.icon:SetPosition(-4, 6)
        self.inspectcontrol:SetPosition((total_w - W) * .5 + 3, -6, 0)
    end
end

---------------------------------------------------------------------------
-- Guard: only whitelisted prefabs may occupy the CHAR slot
---------------------------------------------------------------------------
AddComponentPostInit("inventory", function(self)
    local _Equip = self.Equip
    self.Equip = function(self, item, old_to_active)
        if item and item.components and item.components.equippable then
            local eslot = item.components.equippable.equipslot
            if eslot == GLOBAL.EQUIPSLOTS.CHAR and not ALLOWED[item.prefab] then
                return false
            end
        end
        return _Equip(self, item, old_to_active)
    end
end)

---------------------------------------------------------------------------
-- Reassign every whitelisted prefab into the CHAR equip slot
---------------------------------------------------------------------------
for _, prefab in ipairs(CHAR_ITEMS) do
    AddPrefabPostInit(prefab, function(inst)
        if not GLOBAL.TheWorld.ismastersim then return end
        if inst.components.equippable == nil then
            inst:AddComponent("equippable")
        end
        inst.components.equippable.equipslot = GLOBAL.EQUIPSLOTS.CHAR
    end)
end

---------------------------------------------------------------------------
-- Transfer the shield's post-parry bonus damage to the player so it
-- applies to the NEXT attack with any weapon (or fists), not just the
-- shield.  The bonus is consumed after one hit or expires after duration.
---------------------------------------------------------------------------
AddPrefabPostInit("wathgrithr_shield", function(inst)
    if not GLOBAL.TheWorld.ismastersim then return end

    inst:DoTaskInTime(0, function(inst)
        if inst.components.aoespell ~= nil and inst.components.aoespell.spellfn ~= nil then
            local _spellfn = inst.components.aoespell.spellfn
            inst.components.aoespell:SetSpellFn(function(inst, doer, pos)
                local ok = _spellfn(inst, doer, pos)
                if doer ~= nil and doer:IsValid() then
                    doer:PushEvent("charslot_shield_parry_start", { shield = inst })
                end
                return ok
            end)
        end

        if inst.components.parryweapon == nil then return end

        local _onparryfn = inst.components.parryweapon.onparryfn

        inst.components.parryweapon:SetOnParryFn(function(inst, doer, attacker, damage)
            if _onparryfn then
                _onparryfn(inst, doer, attacker, damage)
            end

            if doer and doer.components.combat and doer.components.skilltreeupdater
                and doer.components.skilltreeupdater:IsActivated("wathgrithr_arsenal_shield_3") then

                local tuning = GLOBAL.TUNING.SKILLS.WATHGRITHR.SHIELD_PARRY_BONUS_DAMAGE
                local scale  = GLOBAL.TUNING.SKILLS.WATHGRITHR.SHIELD_PARRY_BONUS_DAMAGE_SCALE
                local bonus  = math.clamp(damage * scale, tuning.min, tuning.max)
                local duration = GLOBAL.TUNING.SKILLS.WATHGRITHR.SHIELD_PARRY_BONUS_DAMAGE_DURATION

                local prev = doer.components.combat.damagebonus or 0
                doer.components.combat.damagebonus = prev + bonus

                -- Remove bonus: subtract from damagebonus, cancel timer, unhook listener
                local function ClearParryBonus(doer, onhit_fn)
                    doer:RemoveEventCallback("onhitother", onhit_fn)
                    if doer.components.combat then
                        doer.components.combat.damagebonus = (doer.components.combat.damagebonus or 0) - bonus
                        if doer.components.combat.damagebonus == 0 then
                            doer.components.combat.damagebonus = nil
                        end
                    end
                    if doer._parry_bonus_task then
                        doer._parry_bonus_task:Cancel()
                        doer._parry_bonus_task = nil
                    end
                end

                local function onhit(doer)
                    ClearParryBonus(doer, onhit)
                end
                doer:ListenForEvent("onhitother", onhit)

                if doer._parry_bonus_task then
                    doer._parry_bonus_task:Cancel()
                end
                doer._parry_bonus_task = doer:DoTaskInTime(duration, function()
                    ClearParryBonus(doer, onhit)
                end)
            end
        end)
    end)
end)

---------------------------------------------------------------------------
-- Custom RPCs: use CHAR-slot item from hotkey (server-side handlers)
---------------------------------------------------------------------------

-- Shield block (CASTAOE)
AddModRPCHandler(modname, "CharSlotCastAOE", function(player, x, z)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.aoespell == nil then return end
    if item.components.rechargeable ~= nil and not item.components.rechargeable:IsCharged() then
        return
    end
    local pos = GLOBAL.Vector3(x, 0, z)
    local act = GLOBAL.BufferedAction(player, nil, GLOBAL.ACTIONS.CASTAOE, item, pos)
    player.components.locomotor:PushAction(act, true)
end)

-- Dumbbell toss (TOSS via complexprojectile)
AddModRPCHandler(modname, "CharSlotToss", function(player, x, z)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.complexprojectile == nil then return end
    local pos = GLOBAL.Vector3(x, 0, z)
    local act = GLOBAL.BufferedAction(player, nil, GLOBAL.ACTIONS.TOSS, item, pos)
    player.components.locomotor:PushAction(act, true)
end)

-- Dumbbell lift (LIFT_DUMBBELL on self)
AddModRPCHandler(modname, "CharSlotLift", function(player)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.mightydumbbell == nil then return end
    local act = GLOBAL.BufferedAction(player, player, GLOBAL.ACTIONS.LIFT_DUMBBELL, item)
    player.components.locomotor:PushAction(act, true)
end)

-- Pocketwatch use (CAST_POCKETWATCH on self)
AddModRPCHandler(modname, "CharSlotCastPocketwatch", function(player)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.pocketwatch == nil then return end
    local act = GLOBAL.BufferedAction(player, player, GLOBAL.ACTIONS.CAST_POCKETWATCH, item)
    player.components.locomotor:PushAction(act, true)
end)

---------------------------------------------------------------------------
-- Hotkey "Z" — use CHAR-slot item (block / toss / lift depending on item)
-- Hold Shift+Z to lift dumbbell instead of toss
---------------------------------------------------------------------------
local KEY_Z = GLOBAL.KEY_Z or 122

GLOBAL.TheInput:AddKeyDownHandler(KEY_Z, function()
    local player = GLOBAL.ThePlayer
    if player == nil then return end
    -- Don't trigger if a text field is focused (chat, console, etc.)
    if GLOBAL.TheFrontEnd then
        local screen = GLOBAL.TheFrontEnd:GetActiveScreen()
        if screen and screen.name == "ConsoleScreen" then
            return
        end
    end
    local item = player.replica.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil then return end

    -- Pocketwatch (wanda): cast on self
    if item:HasTag("pocketwatch") then
        GLOBAL.SendModRPCToServer(GLOBAL.MOD_RPC[modname]["CharSlotCastPocketwatch"])
        return
    end

    -- Spellbook (waxwelljournal): toggle spell wheel UI only; AOE targeting/casting uses default game controls.
    if item.components.spellbook ~= nil then
        local hud = player.HUD
        if hud ~= nil then
            if hud:GetCurrentOpenSpellBook() == item then
                hud:CloseSpellWheel()
            elseif item.components.spellbook:CanBeUsedBy(player) then
                item.components.spellbook:OpenSpellBook(player)
            end
        end
        return
    end

    -- Shield: instant block (CASTAOE)
    if item.components.aoetargeting ~= nil and item.components.aoetargeting:IsEnabled() then
        local pos = GLOBAL.TheInput:GetWorldPosition()
        GLOBAL.SendModRPCToServer(GLOBAL.MOD_RPC[modname]["CharSlotCastAOE"], pos.x, pos.z)
        return
    end

    -- Dumbbell: Shift+Z = lift, Z = toss (if mighty)
    if item.replica.inventoryitem ~= nil then
        local shift = GLOBAL.TheInput:IsKeyDown(GLOBAL.KEY_SHIFT)
        if shift then
            GLOBAL.SendModRPCToServer(GLOBAL.MOD_RPC[modname]["CharSlotLift"])
        else
            local pos = GLOBAL.TheInput:GetWorldPosition()
            GLOBAL.SendModRPCToServer(GLOBAL.MOD_RPC[modname]["CharSlotToss"], pos.x, pos.z)
        end
    end
end)

---------------------------------------------------------------------------
-- Visual priority: HANDS item always shown. If HANDS is empty, show CHAR
-- item visuals instead.
-- This mod runs on server side; use server inventory state as source of truth.
-- Re-apply twice (0 frame and 1 frame) to avoid late onequip override order.
---------------------------------------------------------------------------
local QueueApplyVisuals

local function StopShieldParryVisual(inst)
    if inst._charslot_force_shield_task ~= nil then
        inst._charslot_force_shield_task:Cancel()
        inst._charslot_force_shield_task = nil
    end
    inst._charslot_force_shield = nil
    if QueueApplyVisuals ~= nil then
        QueueApplyVisuals(inst)
    end
end

local function StartShieldParryVisual(inst, shield)
    if inst == nil or not inst:IsValid() or shield == nil or not shield:IsValid() then
        return
    end

    local inventory = inst.components.inventory
    if inventory == nil then return end

    if inst.prefab ~= "wathgrithr" then return end

    if inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR) ~= shield then return end

    inst._charslot_force_shield = shield

    if inst._charslot_force_shield_task ~= nil then
        inst._charslot_force_shield_task:Cancel()
        inst._charslot_force_shield_task = nil
    end

    -- Show shield visuals immediately
    if shield.components.equippable ~= nil then
        local fn = shield.components.equippable.onequipfn
        if fn then fn(shield, inst) end
    end

    -- Poll every frame until the "parrying" stategraph tag disappears.
    -- Covers all three ways parry can end:
    --   1. Timer runs out naturally
    --   2. Player moves before timer (parry cancelled)
    --   3. Successful parry hit (parry_hit short stun → idle)
    local function CheckParryEnd(inst)
        inst._charslot_force_shield_task = nil
        if inst._charslot_force_shield == nil then return end
        if inst.sg ~= nil and inst.sg:HasStateTag("parrying") then
            -- Still parrying: check again next frame
            inst._charslot_force_shield_task = inst:DoTaskInTime(GLOBAL.FRAMES, CheckParryEnd)
        else
            -- Parry ended: restore normal hand/char priority visuals immediately
            StopShieldParryVisual(inst)
        end
    end

    -- Wait a few frames for stategraph to enter parry_pre and set the "parrying" tag
    inst._charslot_force_shield_task = inst:DoTaskInTime(4 * GLOBAL.FRAMES, CheckParryEnd)
end

local function ApplyVisuals(inst)
    local inventory = inst.components.inventory
    if inventory == nil then return end
    local handsitem = inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.HANDS)
    local charitem  = inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)

    if inst._charslot_force_shield ~= nil and inst._charslot_force_shield:IsValid() then
        if charitem == inst._charslot_force_shield and charitem.components.equippable ~= nil then
            local forcefn = charitem.components.equippable.onequipfn
            if forcefn then forcefn(charitem, inst) end
            return
        else
            inst._charslot_force_shield = nil
        end
    end

    if handsitem ~= nil and handsitem.components.equippable ~= nil then
        -- HAND has something -> CHAR visuals must be removed first.
        if charitem ~= nil and charitem.components.equippable ~= nil then
            local unfn = charitem.components.equippable.onunequipfn
            if unfn then unfn(charitem, inst) end
        end

        -- Then (re)apply hand visuals when available.
        local handsfn = handsitem.components.equippable.onequipfn
        if handsfn then handsfn(handsitem, inst) end
    elseif charitem ~= nil and charitem.components.equippable ~= nil then
        -- HAND is empty → fall back to CHAR item visuals
        local charfn = charitem.components.equippable.onequipfn
        if charfn then charfn(charitem, inst) end
    end
end

QueueApplyVisuals = function(inst)
    if inst._charslot_visual_task0 ~= nil then
        inst._charslot_visual_task0:Cancel()
    end
    if inst._charslot_visual_task1 ~= nil then
        inst._charslot_visual_task1:Cancel()
    end

    inst._charslot_visual_task0 = inst:DoTaskInTime(0, function(inst)
        inst._charslot_visual_task0 = nil
        ApplyVisuals(inst)
    end)
    inst._charslot_visual_task1 = inst:DoTaskInTime(GLOBAL.FRAMES, function(inst)
        inst._charslot_visual_task1 = nil
        ApplyVisuals(inst)
    end)
end

AddPlayerPostInit(function(inst)
    if not GLOBAL.TheWorld.ismastersim then
        return
    end

    inst:ListenForEvent("charslot_shield_parry_start", function(inst, data)
        if data ~= nil and data.shield ~= nil then
            StartShieldParryVisual(inst, data.shield)
        end
    end)

    local function OnEquipChanged(inst, data)
        if data ~= nil and (data.eslot == GLOBAL.EQUIPSLOTS.HANDS or data.eslot == GLOBAL.EQUIPSLOTS.CHAR) then
            QueueApplyVisuals(inst)
        end
    end

    inst:ListenForEvent("equip", OnEquipChanged)
    inst:ListenForEvent("unequip", OnEquipChanged)

    inst:ListenForEvent("onremove", function(inst)
        if inst._charslot_visual_task0 ~= nil then
            inst._charslot_visual_task0:Cancel()
            inst._charslot_visual_task0 = nil
        end
        if inst._charslot_visual_task1 ~= nil then
            inst._charslot_visual_task1:Cancel()
            inst._charslot_visual_task1 = nil
        end
        if inst._charslot_force_shield_task ~= nil then
            inst._charslot_force_shield_task:Cancel()
            inst._charslot_force_shield_task = nil
        end
        inst._charslot_force_shield = nil
    end)
end)

AddGlobalClassPostConstruct("widgets/inventorybar", "Inv", function()
    local _Rebuild = Inv.Rebuild
    local _Refresh = Inv.Refresh

    function Inv:Rebuild()
        _Rebuild(self)
        EnsureCharSlot(self)
    end

    function Inv:Refresh()
        _Refresh(self)
        EnsureCharSlot(self)
    end
end)
