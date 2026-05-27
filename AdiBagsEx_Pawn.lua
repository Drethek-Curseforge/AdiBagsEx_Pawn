local addonName = ...
local AceAddon = LibStub('AceAddon-3.0')
local addon = AceAddon:GetAddon('AdiBagsEx', true)
if not addon then return end

local L = addon.L

local _G = _G
local C_Timer = _G.C_Timer
local GetItemInfo = _G.C_Item and _G.C_Item.GetItemInfo or _G.GetItemInfo
local next = _G.next
local pairs = _G.pairs
local PawnGetItemData = _G.PawnGetItemData
local PawnIsItemAnUpgrade = _G.PawnIsItemAnUpgrade
local PawnRegisterThirdPartyBag = _G.PawnRegisterThirdPartyBag
local PawnShouldItemLinkHaveUpgradeArrow = _G.PawnShouldItemLinkHaveUpgradeArrow
local IsEquippableItem = _G.C_Item and _G.C_Item.IsEquippableItem or _G.IsEquippableItem
local strfind = _G.string.find
local tostring = _G.tostring
local type = _G.type
local UnitLevel = _G.UnitLevel
local wipe = _G.wipe

local RETRY_DELAY = 0.25
local ITEM_LEVEL_UPGRADE_SCORE_FACTOR = 0.000001
local MODE_DEFAULT = 'default'
local MODE_MOST_VALUE = 'mostValue'

local DEFAULTS = {
	profile = {
		mode = MODE_DEFAULT,
		usableOnly = false,
	},
}

local filter = addon:RegisterFilter('Pawn', 93, 'ABEvent-1.0')
filter.uiName = 'Pawn'
filter.uiDesc = 'Put Pawn upgrades in their own section.'

local upgradeCache = {}
local topSlotIds = {}
local topByType = {}
local retryScheduled = false
local refreshScheduled = false
local registeredWithPawn = false
local topPrepared = false

local function EnsureDB()
	if not filter.db then
		filter.db = addon.db:RegisterNamespace(filter.moduleName, DEFAULTS)
		if filter.db.profile.onlyTopOne ~= nil then
			filter.db.profile.mode = filter.db.profile.onlyTopOne and MODE_MOST_VALUE or MODE_DEFAULT
			filter.db.profile.onlyTopOne = nil
		end
	end
	return filter.db
end

local function IsMostValueMode(db)
	return db.profile.mode == MODE_MOST_VALUE
end

local function RefreshAll()
	wipe(upgradeCache)
	wipe(topSlotIds)
	wipe(topByType)
	topPrepared = false
	if filter:IsEnabled() then
		filter:SendMessage('AdiBagsEx_FiltersChanged', true)
	end
end

local function ScheduleRefresh(delay)
	if refreshScheduled or not C_Timer then
		return
	end

	refreshScheduled = true
	C_Timer.After(delay or 0, function()
		refreshScheduled = false
		RefreshAll()
	end)
end

local function RegisterWithPawn()
	if registeredWithPawn or not PawnRegisterThirdPartyBag then
		return
	end

	PawnRegisterThirdPartyBag(addonName, {
		RefreshAll = RefreshAll,
	})
	registeredWithPawn = true
end

local function ScheduleRetry()
	if retryScheduled or not C_Timer then
		return
	end

	retryScheduled = true
	C_Timer.After(RETRY_DELAY, function()
		retryScheduled = false
		if filter:IsEnabled() then
			RefreshAll()
		end
	end)
end

local function GetBestPercentUpgrade(upgradeInfo)
	local bestPercent
	if not upgradeInfo then
		return
	end

	for _, upgrade in pairs(upgradeInfo) do
		local percent = upgrade.PercentUpgrade
		if type(percent) == 'number' and (not bestPercent or percent > bestPercent) then
			bestPercent = percent
		end
	end

	return bestPercent
end

local function GetSlotTypeKey(slotData)
	return tostring(slotData.classID or slotData.class or 'unknown')
		.. ':' .. tostring(slotData.subclassID or slotData.subclass or 'unknown')
		.. ':' .. tostring(slotData.equipSlot or 'unknown')
end

local function CacheResult(link, isUpgrade, score, hasScore)
	local cached = {
		isUpgrade = not not isUpgrade,
		score = score or 0,
		hasScore = not not hasScore,
	}
	upgradeCache[link] = cached
	return cached
end

local function EvaluateUpgrade(link, needScore, usableOnly)
	local cached = upgradeCache[link]
	if cached ~= nil and (cached.hasScore or not needScore or not cached.isUpgrade) then
		return cached
	end

	if needScore and PawnGetItemData and PawnIsItemAnUpgrade then
		if usableOnly then
			local _, _, _, _, minLevel = GetItemInfo(link)
			if minLevel == nil then
				ScheduleRetry()
				return
			elseif UnitLevel('player') < minLevel then
				return CacheResult(link, false, 0, true)
			end
		end

		local item = PawnGetItemData(link)
		if item and not item.Link then
			ScheduleRetry()
			return
		elseif item then
			local upgradeInfo, itemLevelIncrease = PawnIsItemAnUpgrade(item)
			local score = GetBestPercentUpgrade(upgradeInfo)
			local isUpgrade = upgradeInfo ~= nil

			if not isUpgrade and _G.PawnCommon and _G.PawnCommon.ShowItemLevelUpgrades and itemLevelIncrease ~= nil then
				isUpgrade = true
				score = (itemLevelIncrease or 0) * ITEM_LEVEL_UPGRADE_SCORE_FACTOR
			end

			return CacheResult(link, isUpgrade, score, true)
		end
	end

	if PawnShouldItemLinkHaveUpgradeArrow then
		local isUpgrade = PawnShouldItemLinkHaveUpgradeArrow(link, usableOnly)
		if isUpgrade == nil then
			ScheduleRetry()
			return
		end

		return CacheResult(link, isUpgrade, 0, false)
	end
end

local function EvaluateSlot(slotData, needScore, usableOnly)
	local link = slotData.link
	if not link or not strfind(link, '|Hitem:', 1, true) then
		return
	elseif usableOnly and IsEquippableItem and not IsEquippableItem(link) then
		return
	end

	return EvaluateUpgrade(link, needScore, usableOnly)
end

function filter:AdiBags_PreContentUpdate(event, container, added, removed, changed)
	local db = EnsureDB()
	if IsMostValueMode(db)
		and ((added and next(added)) or (removed and next(removed)) or (changed and next(changed)))
	then
		ScheduleRefresh()
	end
end

function filter:AdiBags_PreFilter(event, container)
	wipe(topSlotIds)
	wipe(topByType)
	topPrepared = false

	local db = EnsureDB()
	if not IsMostValueMode(db) or not container or not container.content then
		return
	end

	local usableOnly = db.profile.usableOnly

	for _, content in pairs(container.content) do
		for slot = 1, content.size or 0 do
			local slotData = content[slot]
			if slotData then
				local result = EvaluateSlot(slotData, true, usableOnly)
				if result and result.isUpgrade then
					local score = result.score or 0
					local typeKey = GetSlotTypeKey(slotData)
					local top = topByType[typeKey]
					if not top or score > top.score or (score == top.score and slotData.slotId < top.slotId) then
						topByType[typeKey] = {
							slotId = slotData.slotId,
							score = score,
						}
					end
				end
			end
		end
	end

	for _, top in pairs(topByType) do
		topSlotIds[top.slotId] = true
	end
	topPrepared = true
end

function filter:OnEnable()
	EnsureDB()
	RegisterWithPawn()
	wipe(upgradeCache)
	self:RegisterMessage('AdiBags_PreContentUpdate')
	self:RegisterMessage('AdiBags_PreFilter')
	addon:UpdateFilters()
end

function filter:OnDisable()
	wipe(upgradeCache)
	wipe(topSlotIds)
	wipe(topByType)
	topPrepared = false
	self:UnregisterMessage('AdiBags_PreContentUpdate')
	self:UnregisterMessage('AdiBags_PreFilter')
	addon:UpdateFilters()
end

function filter:Filter(slotData)
	local db = EnsureDB()
	local mostValue = IsMostValueMode(db)
	local result = EvaluateSlot(slotData, mostValue, db.profile.usableOnly)
	if not result or not result.isUpgrade then
		return
	end

	if mostValue and topPrepared and not topSlotIds[slotData.slotId] then
		return
	end

	return L['Pawn']
end

local function SetOptionAndUpdate(info, value)
	EnsureDB().profile[info[#info]] = value
	RefreshAll()
end

function filter:GetOptions()
	EnsureDB()
	return {
		mode = {
			name = 'Mode',
			desc = 'Select how Pawn upgrades are shown in the Pawn section.',
			type = 'select',
			width = 'double',
			values = {
				[MODE_DEFAULT] = 'Default',
				[MODE_MOST_VALUE] = 'Highest Upgrade',
			},
			order = 10,
			set = SetOptionAndUpdate,
		},
		usableOnly = {
			name = 'Usable only',
			desc = 'Ignore items that are not equippable before asking Pawn to evaluate them.',
			type = 'toggle',
			width = 'normal',
			order = 20,
			set = SetOptionAndUpdate,
		},
	}, addon:GetOptionHandler(self, true)
end
