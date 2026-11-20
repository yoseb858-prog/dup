--[[
	TradeServer (Script) → ServerScriptService 에 넣기

	흐름: 요청 → 수락 → 아이템 올리기 → 1차 확인(둘 다) → 카운트다운 → 2차 확인(둘 다)
	      → 상태 "Trading"(로딩 화면 표시) → 아이템 교환 → 완료("Done") / 취소("Cancelled")

	끊김 테스트 모드:
	  DISCONNECT_TEST.Enabled = true 이면, "Trading(로딩)" 화면이 뜨는 순간
	  MyUserIds 에 있는 내 계정만 서버에서 Kick 합니다. (상대는 그대로)
	  → 거래가 취소되고 양쪽 인벤토리가 원래대로인지 확인하는 용도.
	  테스트가 끝나면 Enabled = false 로 꺼 두세요.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

----------------------------------------------------------------
-- 설정
----------------------------------------------------------------
local DISCONNECT_TEST = {
	Enabled = true,
	StudioOnly = true,         -- true면 Studio 테스트에서만 작동
	-- 내 계정 UserId (여러 개 가능). 거래에 이 계정이 있으면 이 계정만 나가짐.
	-- 비워 두면 게임 제작자(game.CreatorId) 계정을 "내 계정"으로 봄.
	-- Studio 로컬 서버 테스트(Player1/Player2)에서는 거래를 "요청한 쪽"이 내 계정.
	MyUserIds = {},
	DelayBeforeKick = 0.2,     -- "로딩" 화면이 뜬 뒤 몇 초 후 끊을지 (화면이 보이도록 살짝 대기)
	KickMessage = "거래 진행중 연결이 끊어졌습니다",
}

-- 로딩/렉 흉내: "Trading(로딩)" 화면이 뜬 뒤 실제 교환까지 걸리는 시간(초). 0이면 바로 교환.
-- 이 사이에 나가거나 버튼을 연타해서 아이템이 복사되지 않는지 확인하는 용도.
local SIMULATE_LAG = 2
local FINAL_COUNTDOWN = 3      -- 2차 확인 전 대기(바꿔치기 방지)
local MAX_ITEMS_PER_SIDE = 8

----------------------------------------------------------------
-- 리모트
----------------------------------------------------------------
local remote = ReplicatedStorage:FindFirstChild("TradeEvent")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "TradeEvent"
	remote.Parent = ReplicatedStorage
end

----------------------------------------------------------------
-- 인벤토리 (예시: 메모리. 실제로는 DataStore/ProfileStore 연결)
-- inventories[userId] = { [itemId] = { name = "칼", locked = false } }
----------------------------------------------------------------
local inventories = {}

local function giveStarterItems(player)
	local inv = {}
	for i = 1, 3 do
		local id = HttpService:GenerateGUID(false)
		inv[id] = { name = player.Name .. "의 칼 #" .. i, locked = false }
	end
	inventories[player.UserId] = inv
end

local function inventorySnapshot(player)
	local list = {}
	for id, item in pairs(inventories[player.UserId] or {}) do
		table.insert(list, { id = id, name = item.name, locked = item.locked })
	end
	return list
end

----------------------------------------------------------------
-- 거래 상태
----------------------------------------------------------------
-- State: "Offering" | "Confirm1" | "Countdown" | "Confirm2" | "Trading" | "Done" | "Cancelled"
local trades = {}          -- tradeId -> trade
local playerTrade = {}     -- userId -> tradeId
local pendingRequests = {} -- targetUserId -> fromUserId

local function other(trade, player)
	return trade.a == player and trade.b or trade.a
end

local function sideOf(trade, player)
	return trade.a == player and "a" or "b"
end

local function broadcast(trade, loadingInfo)
	local function view(p)
		return {
			tradeId = trade.id,
			state = trade.state,
			partner = other(trade, p).Name,
			myOffer = trade.offer[sideOf(trade, p)],
			theirOffer = trade.offer[sideOf(trade, other(trade, p))],
			myConfirm = trade.confirm[sideOf(trade, p)],
			theirConfirm = trade.confirm[sideOf(trade, other(trade, p))],
			inventory = inventorySnapshot(p),
			-- 로딩 화면용 정보 (state == "Trading" 일 때 활용)
			loading = loadingInfo,
		}
	end
	for _, p in ipairs({ trade.a, trade.b }) do
		if p and p.Parent then
			remote:FireClient(p, "Update", view(p))
		end
	end
end

local function unlockOffers(trade)
	for side, offer in pairs(trade.offer) do
		local owner = trade[side]
		local inv = owner and inventories[owner.UserId]
		if inv then
			for itemId in pairs(offer) do
				if inv[itemId] then inv[itemId].locked = false end
			end
		end
	end
end

local function endTrade(trade, state, reason)
	if trade.state == "Done" or trade.state == "Cancelled" then return end
	trade.state = state
	if state == "Cancelled" then
		unlockOffers(trade) -- 롤백: 아이템은 이동하지 않았으므로 잠금만 해제
	end
	if trade.a then playerTrade[trade.a.UserId] = nil end
	if trade.b then playerTrade[trade.b.UserId] = nil end
	for _, p in ipairs({ trade.a, trade.b }) do
		if p and p.Parent then
			remote:FireClient(p, "Ended", {
				state = state,
				reason = reason,
				inventory = inventorySnapshot(p),
			})
		end
	end
	trades[trade.id] = nil
	print(("[Trade %s] %s (%s)"):format(trade.id, state, reason or ""))
end

local function resetConfirms(trade)
	trade.confirm.a, trade.confirm.b = false, false
	if trade.state ~= "Offering" then
		trade.state = "Offering"
	end
end

----------------------------------------------------------------
-- 실제 교환 (yield 없음 → 중간에 끊겨도 절반만 바뀌지 않음)
----------------------------------------------------------------
local function commit(trade)
	local invA = trade.a and inventories[trade.a.UserId]
	local invB = trade.b and inventories[trade.b.UserId]
	if not (invA and invB and trade.a.Parent and trade.b.Parent) then
		return false, "참가자 없음"
	end
	-- 검증
	for itemId in pairs(trade.offer.a) do
		if not invA[itemId] then return false, "A 아이템 없음" end
	end
	for itemId in pairs(trade.offer.b) do
		if not invB[itemId] then return false, "B 아이템 없음" end
	end
	-- 교환
	for itemId in pairs(trade.offer.a) do
		local item = invA[itemId]
		invA[itemId] = nil
		item.locked = false
		invB[itemId] = item
	end
	for itemId in pairs(trade.offer.b) do
		local item = invB[itemId]
		invB[itemId] = nil
		item.locked = false
		invA[itemId] = item
	end
	-- TODO: 여기서 두 플레이어 데이터를 저장 (tradeId 를 기록해 중복 처리 방지)
	return true
end

----------------------------------------------------------------
-- 끊김 테스트
----------------------------------------------------------------
local function testModeActive()
	if not DISCONNECT_TEST.Enabled then return false end
	if DISCONNECT_TEST.StudioOnly and not RunService:IsStudio() then return false end
	return true
end

-- 거래 참가자 중 "내 계정"을 찾음 (상대 유저는 절대 내보내지 않음)
local function findMyAccount(trade)
	local myIds = DISCONNECT_TEST.MyUserIds
	if #myIds == 0 then
		myIds = { game.CreatorId }
	end
	for _, p in ipairs({ trade.a, trade.b }) do
		if p and table.find(myIds, p.UserId) then
			return p
		end
	end
	-- Studio 로컬 테스트(UserId 가 음수인 가짜 계정)에서는 요청한 쪽 = 내 계정
	if RunService:IsStudio() and trade.a and trade.a.UserId <= 0 then
		return trade.a
	end
	return nil
end

----------------------------------------------------------------
-- 2차 확인 완료 → 로딩("Trading") → 교환 처리
----------------------------------------------------------------
local function startTrading(trade)
	if trade.state ~= "Confirm2" then return end -- 연타로 두 번 들어와도 한 번만 실행
	trade.state = "Trading"

	-- 1단계 로딩 알림: 클라이언트에 로딩 UI 표시
	broadcast(trade, {
		step = 1,
		totalSteps = 3,
		message = "아이템 검증 중...",
	})
	print(("[Trade %s] 로딩 시작 (대기/렉 흉내 %.1f초)"):format(trade.id, SIMULATE_LAG))

	-- 끊김 테스트: 로딩 도중에 내 계정을 내보냄
	if testModeActive() then
		local me = findMyAccount(trade)
		if me then
			task.delay(DISCONNECT_TEST.DelayBeforeKick, function()
				if trade.state == "Trading" and me.Parent then
					warn(("[끊김 테스트] 로딩 화면에서 내 계정(%s) 강제 종료"):format(me.Name))
					me:Kick(DISCONNECT_TEST.KickMessage)
					-- PlayerRemoving 에서 거래가 취소되고 양쪽 아이템 롤백됨
				end
			end)
		end
	end

	-- 렉/로딩 흉내: 교환 처리 지연
	if SIMULATE_LAG > 0 then
		local half = SIMULATE_LAG * 0.5
		task.wait(half)
		if trade.state ~= "Trading" then
			print(("[Trade %s] 로딩 중 취소됨 → 교환 안 함"):format(trade.id))
			return
		end

		broadcast(trade, {
			step = 2,
			totalSteps = 3,
			message = "아이템 교환 처리 중...",
		})
		task.wait(SIMULATE_LAG - half)
	end

	-- 기다리는 동안 누가 나갔으면 이미 Cancelled 상태 → 교환 안 함
	if trade.state ~= "Trading" then
		print(("[Trade %s] 로딩 중 취소됨 → 교환 안 함"):format(trade.id))
		return
	end

	broadcast(trade, {
		step = 3,
		totalSteps = 3,
		message = "거래 결과 반영 중...",
	})

	local ok, err = commit(trade)
	if ok then
		endTrade(trade, "Done", "거래 완료")
	else
		endTrade(trade, "Cancelled", err)
	end
end

----------------------------------------------------------------
-- 요청 처리
----------------------------------------------------------------
local handlers = {}

function handlers.Request(player, targetName)
	local target = Players:FindFirstChild(tostring(targetName))
	if not target or target == player then return end
	if playerTrade[player.UserId] or playerTrade[target.UserId] then return end
	pendingRequests[target.UserId] = player.UserId
	remote:FireClient(target, "Incoming", { from = player.Name })
end

function handlers.Accept(player, fromName)
	local from = Players:FindFirstChild(tostring(fromName))
	if not from or pendingRequests[player.UserId] ~= from.UserId then return end
	pendingRequests[player.UserId] = nil
	if playerTrade[player.UserId] or playerTrade[from.UserId] then return end

	local trade = {
		id = HttpService:GenerateGUID(false),
		a = from, b = player,
		state = "Offering",
		offer = { a = {}, b = {} },
		confirm = { a = false, b = false },
	}
	trades[trade.id] = trade
	playerTrade[from.UserId] = trade.id
	playerTrade[player.UserId] = trade.id
	broadcast(trade)
end

local function getTrade(player)
	local id = playerTrade[player.UserId]
	return id and trades[id]
end

function handlers.AddItem(player, itemId)
	local trade = getTrade(player)
	if not trade or (trade.state ~= "Offering" and trade.state ~= "Confirm1") then return end
	local inv = inventories[player.UserId]
	local item = inv and inv[itemId]
	if not item or item.locked then return end
	local offer = trade.offer[sideOf(trade, player)]
	local count = 0
	for _ in pairs(offer) do count += 1 end
	if count >= MAX_ITEMS_PER_SIDE then return end

	item.locked = true
	offer[itemId] = item.name
	resetConfirms(trade) -- 내용 바뀌면 확인 초기화
	broadcast(trade)
end

function handlers.RemoveItem(player, itemId)
	local trade = getTrade(player)
	if not trade or (trade.state ~= "Offering" and trade.state ~= "Confirm1") then return end
	local offer = trade.offer[sideOf(trade, player)]
	if not offer[itemId] then return end
	offer[itemId] = nil
	local inv = inventories[player.UserId]
	if inv and inv[itemId] then inv[itemId].locked = false end
	resetConfirms(trade)
	broadcast(trade)
end

function handlers.Confirm(player)
	local trade = getTrade(player)
	if not trade then return end
	local side = sideOf(trade, player)

	if trade.state == "Offering" or trade.state == "Confirm1" then
		-- 1차 확인
		trade.confirm[side] = true
		trade.state = "Confirm1"
		if trade.confirm.a and trade.confirm.b then
			trade.state = "Countdown"
			trade.confirm.a, trade.confirm.b = false, false
			broadcast(trade)
			local id = trade.id
			task.delay(FINAL_COUNTDOWN, function()
				if trades[id] and trade.state == "Countdown" then
					trade.state = "Confirm2"
					broadcast(trade)
				end
			end)
			return
		end
	elseif trade.state == "Confirm2" then
		-- 2차 확인
		trade.confirm[side] = true
		if trade.confirm.a and trade.confirm.b then
			task.spawn(startTrading, trade)
			return
		end
	else
		-- Countdown / Trading 중 연타는 무시
		return
	end
	broadcast(trade)
end

function handlers.Cancel(player)
	local trade = getTrade(player)
	if trade and trade.state ~= "Trading" then
		endTrade(trade, "Cancelled", player.Name .. " 님이 취소")
	end
end

remote.OnServerEvent:Connect(function(player, action, arg)
	local fn = typeof(action) == "string" and handlers[action]
	if fn then fn(player, arg) end
end)

----------------------------------------------------------------
-- 접속 / 종료
----------------------------------------------------------------
Players.PlayerAdded:Connect(function(player)
	giveStarterItems(player)
end)

Players.PlayerRemoving:Connect(function(player)
	local trade = getTrade(player)
	if trade then
		-- 로딩(Trading) 중이어도 commit 전이면 취소 → 양쪽 아이템 그대로
		endTrade(trade, "Cancelled", player.Name .. " 님 연결 끊김")
	end
	pendingRequests[player.UserId] = nil
	inventories[player.UserId] = nil
end)
