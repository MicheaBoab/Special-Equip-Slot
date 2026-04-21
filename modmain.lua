local require = GLOBAL.require
local Inv = require "widgets/inventorybar"

Assets =
{
    Asset("IMAGE", "images/char.tex"),
    Asset("ATLAS", "images/char.xml"),
}

-- Register the new equip slot into the global tables.
-- 在全局装备槽表中注册新的 CHAR 槽位。
GLOBAL.EQUIPSLOTS.CHAR = "char"

---------------------------------------------------------------------------
-- Character -> items mapping.
-- 角色到物品的映射：只有这里列出的角色会启用 CHAR 槽。
---------------------------------------------------------------------------
local CHAR_ITEMS_BY_CHARACTER = {
    wathgrithr = {
        "wathgrithr_shield",
    },
    wendy = {
        "abigail_flower",
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

-- Flatten mapping for iteration and O(1) allow-check.
-- 将映射拍平为列表与哈希表：便于遍历与快速白名单判断。
local CHAR_ITEMS = {}
local ALLOWED = {}
for _, items in pairs(CHAR_ITEMS_BY_CHARACTER) do
    for _, name in ipairs(items) do
        table.insert(CHAR_ITEMS, name)
        ALLOWED[name] = true
    end
end

-- Whether this character should show CHAR slot.
-- 判断该角色是否应显示 CHAR 槽位。
local function CharacterHasSlot(prefab)
    return CHAR_ITEMS_BY_CHARACTER[prefab] ~= nil
end

-- InventoryBar hook: add CHAR slot for supported characters and resize BG.
-- 背包栏钩子：给支持角色添加 CHAR 槽，并按总宽度重算背景缩放。
local function EnsureCharSlot(self)
    if self.owner and CharacterHasSlot(self.owner.prefab) then
        if not self._charslot_added then
            self._charslot_added = true
            self:AddEquipSlot(GLOBAL.EQUIPSLOTS.CHAR, "images/char.xml", "char.tex")
        end
    end

    -- Auto-scale background using vanilla-like total width formula.
    -- 使用接近原版 total_w 的公式自动缩放背景。
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

    -- Vanilla baseline: 15 inv + 3 equip + 1 button.
    -- 原版基线：15 物品栏 + 3 装备栏 + 1 按钮。
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
-- Server-side equip guard for CHAR slot whitelist.
-- 服务端装备保护：仅允许白名单 prefab 进入 CHAR 槽。
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
-- Reassign allowed items to CHAR slot at prefab init.
-- 在 prefab 初始化时把白名单物品的装备槽改为 CHAR。
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

-- Mark dumbbells as special-action toss items.
-- 给哑铃打 special_action_toss，屏蔽原版 complexprojectile 的普通右键 TOSS 提示。
local DUMBBELL_PREFABS = {
    "dumbbell",
    "dumbbell_golden",
    "dumbbell_marble",
    "dumbbell_gem",
    "dumbbell_heat",
    "dumbbell_redgem",
    "dumbbell_bluegem",
}

local function EnsureSpecialActionTossTag(inst)
    -- Defensive guard: AddTag is idempotent; HasTag keeps intent explicit.
    -- 防御性保护：AddTag 本身幂等；保留 HasTag 用于明确语义并减少无效写入。
    if inst ~= nil and inst:IsValid() and not inst:HasTag("special_action_toss") then
        inst:AddTag("special_action_toss")
    end
end

local function CharSlotDumbbellOnEquip(inst, owner)
    -- CHAR-slot dumbbell equip visual only.
    -- CHAR 槽哑铃只做视觉切换，不执行原版 HAND 逻辑。
    if owner == nil or owner.AnimState == nil then
        return
    end
    owner.AnimState:OverrideSymbol("swap_object", inst.swap_dumbbell, inst.swap_dumbbell_symbol)
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function CharSlotDumbbellOnUnequip(inst, owner)
    -- CHAR-slot dumbbell unequip visual restore only.
    -- CHAR 槽哑铃卸下时仅恢复视觉，并中止 lifting 状态。
    if owner == nil or owner.AnimState == nil then
        return
    end
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")

    if inst:HasTag("lifting") then
        owner:PushEvent("stopliftingdumbbell", { instant = true })
    end
end

for _, prefab in ipairs(DUMBBELL_PREFABS) do
    AddPrefabPostInit(prefab, function(inst)
        EnsureSpecialActionTossTag(inst)

        -- Keep both immediate and next-tick re-apply as timing guard.
        -- 保留“当帧 + 下一帧”双重补标，规避拾取/预测与动作收集的瞬时竞态。
        inst:ListenForEvent("onputininventory", function(inst)
            EnsureSpecialActionTossTag(inst)
            inst:DoTaskInTime(0, EnsureSpecialActionTossTag)
        end)

        -- One-time wrapper marker: avoid repeated hook wrapping.
        -- 一次性包裹标记：避免在异常情况下重复包裹回调。
        if GLOBAL.TheWorld.ismastersim and inst.components.equippable ~= nil and not inst._charslot_dumbbell_wrapped then
            inst._charslot_dumbbell_wrapped = true

            local _old_onequip = inst.components.equippable.onequipfn
            local _old_onunequip = inst.components.equippable.onunequipfn

            inst.components.equippable:SetOnEquip(function(inst, owner)
                if inst.components.equippable ~= nil and inst.components.equippable.equipslot == GLOBAL.EQUIPSLOTS.CHAR then
                    CharSlotDumbbellOnEquip(inst, owner)
                    return
                end
                if _old_onequip ~= nil then
                    _old_onequip(inst, owner)
                end
            end)

            inst.components.equippable:SetOnUnequip(function(inst, owner)
                if inst.components.equippable ~= nil and inst.components.equippable.equipslot == GLOBAL.EQUIPSLOTS.CHAR then
                    CharSlotDumbbellOnUnequip(inst, owner)
                    return
                end
                if _old_onunequip ~= nil then
                    _old_onunequip(inst, owner)
                end
            end)
        end
    end)
end

---------------------------------------------------------------------------
-- Move shield parry bonus to player damagebonus so next hit consumes it.
-- 将盾反增伤临时转移到角色 damagebonus：下一次命中消耗，或到时失效。
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
-- Custom RPCs for hotkey-driven CHAR slot actions (server handlers).
-- 热键驱动的 CHAR 槽行为 RPC（服务端处理）。
---------------------------------------------------------------------------

-- Shield block (CASTAOE).
-- 盾牌格挡（CASTAOE）。
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

-- Dumbbell toss (TOSS via complexprojectile).
-- 哑铃投掷（通过 complexprojectile 执行 TOSS）。
AddModRPCHandler(modname, "CharSlotToss", function(player, x, z)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.complexprojectile == nil then return end
    -- Force CHAR visuals during toss so HAND visual does not override animation.
    -- 投掷时临时强制 CHAR 贴图，避免 HAND 贴图抢占动画显示。
    player:PushEvent("charslot_force_char_visual", { item = item, mode = "toss" })
    local pos = GLOBAL.Vector3(x, 0, z)
    local act = GLOBAL.BufferedAction(player, nil, GLOBAL.ACTIONS.TOSS, item, pos)
    player.components.locomotor:PushAction(act, true)
end)

-- Dumbbell lift (LIFT_DUMBBELL on self).
-- 哑铃举重（对自身执行 LIFT_DUMBBELL）。
AddModRPCHandler(modname, "CharSlotLift", function(player)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.mightydumbbell == nil then return end
    -- Force CHAR visuals during lift for consistent animation symbol.
    -- 举重期间临时强制 CHAR 贴图，保证动作符号一致。
    player:PushEvent("charslot_force_char_visual", { item = item, mode = "lift" })
    local act = GLOBAL.BufferedAction(player, player, GLOBAL.ACTIONS.LIFT_DUMBBELL, item)
    player.components.locomotor:PushAction(act, true)
end)

-- Pocketwatch use (CAST_POCKETWATCH on self).
-- 怀表施法（对自身执行 CAST_POCKETWATCH）。
AddModRPCHandler(modname, "CharSlotCastPocketwatch", function(player)
    if player == nil or not player:IsValid() then return end
    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.pocketwatch == nil then return end
    local act = GLOBAL.BufferedAction(player, player, GLOBAL.ACTIONS.CAST_POCKETWATCH, item)
    player.components.locomotor:PushAction(act, true)
end)

-- Abigail flower summon (CASTSUMMON).
-- 阿比盖尔花召唤（CASTSUMMON）。
AddModRPCHandler(modname, "CharSlotCastSummon", function(player)
    if player == nil or not player:IsValid() then return end
    if not player:HasTag("ghostfriend_notsummoned") then return end

    local item = player.components.inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if item == nil or item.components.summoningitem == nil then return end

    local act = GLOBAL.BufferedAction(player, nil, GLOBAL.ACTIONS.CASTSUMMON, item)
    player.components.locomotor:PushAction(act, true)
end)

---------------------------------------------------------------------------
-- Hotkey Z uses CHAR-slot item contextually; Shift+Z prefers lift for dumbbell.
-- 热键 Z 按 CHAR 槽物品类型执行动作；Shift+Z 对哑铃优先举重。
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

    -- Abigail flower (wendy): if Abigail is not summoned, summon first; otherwise open the spell wheel.
    if item:HasTag("abigail_flower") then
        if player:HasTag("ghostfriend_notsummoned") then
            GLOBAL.SendModRPCToServer(GLOBAL.MOD_RPC[modname]["CharSlotCastSummon"])
            return
        end

        if item.components.spellbook ~= nil then
            local hud = player.HUD
            if hud ~= nil then
                if hud:GetCurrentOpenSpellBook() == item then
                    hud:CloseSpellWheel()
                elseif item.components.spellbook:CanBeUsedBy(player) then
                    item.components.spellbook:OpenSpellBook(player)
                end
            end
        end
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
-- Visual priority policy:
-- 1) HANDS has highest priority, 2) fallback to CHAR when HANDS is empty.
-- 可视化优先级策略：
-- 1) HANDS 最高优先，2) HANDS 为空时回退显示 CHAR。
-- Server authoritative inventory state is used.
-- 以服务端库存状态为准。
-- Re-apply at 0f and 1f to avoid late onequip ordering issues.
-- 在 0 帧与 1 帧各重放一次，规避 onequip 时序覆盖。
---------------------------------------------------------------------------
local QueueApplyVisuals

local function StopShieldParryVisual(inst)
    -- Stop temporary shield-visual forcing and restore normal priority.
    -- 结束盾反期间的强制贴图，恢复常规优先级。
    if inst._charslot_force_shield_task ~= nil then
        inst._charslot_force_shield_task:Cancel()
        inst._charslot_force_shield_task = nil
    end
    inst._charslot_force_shield = nil
    if QueueApplyVisuals ~= nil then
        QueueApplyVisuals(inst)
    end
end

local function StopActionForceVisual(inst)
    -- Stop temporary force-visual during toss/lift actions.
    -- 结束投掷/举重动作期间的临时强制贴图。
    if inst._charslot_force_action_task ~= nil then
        inst._charslot_force_action_task:Cancel()
        inst._charslot_force_action_task = nil
    end
    inst._charslot_force_action_item = nil
    inst._charslot_force_action_mode = nil
    if QueueApplyVisuals ~= nil then
        QueueApplyVisuals(inst)
    end
end

local function StartActionForceVisual(inst, item, mode)
    -- Temporarily force CHAR item visuals during action animation window.
    -- 在动作动画窗口内临时锁定 CHAR 物品贴图。
    if inst == nil or not inst:IsValid() or item == nil or not item:IsValid() then
        return
    end

    local inventory = inst.components.inventory
    if inventory == nil then return end
    if inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR) ~= item then return end

    inst._charslot_force_action_item = item
    inst._charslot_force_action_mode = mode

    if inst._charslot_force_action_task ~= nil then
        inst._charslot_force_action_task:Cancel()
        inst._charslot_force_action_task = nil
    end

    if mode == "toss" then
        -- Throw animation is short; keep force for a small fixed window.
        -- 投掷动画较短，使用固定短窗口强制贴图。
        inst._charslot_force_action_task = inst:DoTaskInTime(14 * GLOBAL.FRAMES, function(inst)
            StopActionForceVisual(inst)
        end)
        if QueueApplyVisuals ~= nil then
            QueueApplyVisuals(inst)
        end
        return
    end

    -- Lift state may start/finish asynchronously; poll while active.
    -- 举重状态进入/退出可能异步，使用逐帧轮询保持贴图正确。
    local deadline = GLOBAL.GetTime() + 1.0
    local function PollLift(inst)
        inst._charslot_force_action_task = nil
        local forceitem = inst._charslot_force_action_item
        if forceitem == nil or not forceitem:IsValid() then
            StopActionForceVisual(inst)
            return
        end

        local inv = inst.components.inventory
        if inv == nil or inv:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR) ~= forceitem then
            StopActionForceVisual(inst)
            return
        end

        local lifting = forceitem:HasTag("lifting")
        if lifting or GLOBAL.GetTime() < deadline then
            if QueueApplyVisuals ~= nil then
                QueueApplyVisuals(inst)
            end
            inst._charslot_force_action_task = inst:DoTaskInTime(GLOBAL.FRAMES, PollLift)
        else
            StopActionForceVisual(inst)
        end
    end

    inst._charslot_force_action_task = inst:DoTaskInTime(0, PollLift)
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
    -- Central visual resolver for HANDS/CHAR with temporary force states.
    -- HANDS/CHAR 可视化统一决策点（含临时强制状态）。
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

    if inst._charslot_force_action_item ~= nil and inst._charslot_force_action_item:IsValid() then
        if charitem == inst._charslot_force_action_item and charitem.components.equippable ~= nil then
            local forcefn = charitem.components.equippable.onequipfn
            if forcefn then forcefn(charitem, inst) end
            return
        else
            inst._charslot_force_action_item = nil
            inst._charslot_force_action_mode = nil
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

-- Vanilla updates dumbbell tossability via onputininventory in HAND flow.
-- 原版只在 HAND 流程里通过 onputininventory 刷新哑铃可投掷状态；
-- CHAR 槽需要手动补触发以保持状态一致。
local function RefreshCharDumbbellState(inst)
    local inventory = inst.components.inventory
    if inventory == nil then return end

    local charitem = inventory:GetEquippedItem(GLOBAL.EQUIPSLOTS.CHAR)
    if charitem ~= nil and charitem:HasTag("dumbbell") then
        charitem:PushEvent("onputininventory", inst)
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

    -- Shield parry visual force trigger.
    -- 盾反可视强制触发入口。
    inst:ListenForEvent("charslot_shield_parry_start", function(inst, data)
        if data ~= nil and data.shield ~= nil then
            StartShieldParryVisual(inst, data.shield)
        end
    end)

    -- Toss/lift visual force trigger.
    -- 投掷/举重可视强制触发入口。
    inst:ListenForEvent("charslot_force_char_visual", function(inst, data)
        if data ~= nil and data.item ~= nil then
            StartActionForceVisual(inst, data.item, data.mode)
        end
    end)

    local function OnEquipChanged(inst, data)
        if data ~= nil and (data.eslot == GLOBAL.EQUIPSLOTS.HANDS or data.eslot == GLOBAL.EQUIPSLOTS.CHAR) then
            QueueApplyVisuals(inst)
            if data.eslot == GLOBAL.EQUIPSLOTS.CHAR then
                -- Defer one tick to ensure equipped item state is fully updated first.
                inst:DoTaskInTime(0, RefreshCharDumbbellState)
            end
        end
    end

    inst:ListenForEvent("equip", OnEquipChanged)
    inst:ListenForEvent("unequip", OnEquipChanged)
    inst:ListenForEvent("mightiness_statechange", RefreshCharDumbbellState)

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
        if inst._charslot_force_action_task ~= nil then
            inst._charslot_force_action_task:Cancel()
            inst._charslot_force_action_task = nil
        end
        inst._charslot_force_action_item = nil
        inst._charslot_force_action_mode = nil
    end)
end)

AddGlobalClassPostConstruct("widgets/inventorybar", "Inv", function()
    -- Ensure CHAR slot is present after both rebuild and refresh paths.
    -- 在 Rebuild/Refresh 两条路径都确保 CHAR 槽存在。
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
