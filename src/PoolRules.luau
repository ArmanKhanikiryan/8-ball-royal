-- 8-ball rules, simplified the way casual online pool plays them. Pure: the input is the game
-- state plus a shot's physics result, the output is the next state.
--
-- state = { turn = 1 | 2, groups = { [1] = "solids" | "stripes" | nil, [2] = ... },
--           ballInHand = bool, isBreak = bool, winner = nil | 1 | 2, calls = "none" | "eight" | "all" }
-- calls: which shots need a called pocket (never the break): "none" (the 8 may drop anywhere),
-- "eight" (only the 8) or "all" (every shot, as on high-stakes tables).
-- A state with game = "nine" plays 9-ball (shared/PoolRules9): every function here hands it over, so the
-- server, the bots, the aim guide and the HUD need no second path.
local Config = require("./Config")
local PoolRules9 = require("./PoolRules9")

local PoolRules = {}

function PoolRules.new(calls: string?, game: string?)
	if game == "nine" then
		return PoolRules9.new()
	end
	return { turn = 1, groups = {}, ballInHand = true, isBreak = true, winner = nil, calls = calls or "eight" }
end

function PoolRules.groupOf(id: number): string?
	return if id >= 1 and id <= 7 then "solids" elseif id >= 9 then "stripes" else nil
end

local function opposite(group)
	return if group == "solids" then "stripes" else "solids"
end

local function onTable(balls, group)
	local n = 0
	for _, b in balls do
		if not b.pocket and PoolRules.groupOf(b.id) == group then
			n += 1
		end
	end
	return n
end

-- Ids the shooter may hit first.
function PoolRules.targets(state, balls)
	if state.game == "nine" then
		return PoolRules9.targets(state, balls)
	end
	local group = state.groups[state.turn]
	local cleared = group ~= nil and onTable(balls, group) == 0
	local ids = {}
	for _, b in balls do
		if not b.pocket and b.id ~= 0 then
			local g = PoolRules.groupOf(b.id)
			if (group == nil and g ~= nil) or (group ~= nil and g == group) or (cleared and b.id == 8) then
				ids[b.id] = true
			end
		end
	end
	return ids
end

-- before: balls at the start of the shot. result: PoolPhysics.simulate output. call: the pocket
-- index the shooter named (when PoolRules.mustCall asks for one; nil = not named).
-- Returns the next state and an outcome:
--   { foul = nil | "scratch" | "no hit" | "wrong ball" | "no rail" | "bad break" | "wrong pocket",
--     pocketed = { ids }, assigned = group?, continues = bool, rerack = bool, wrongPocket = bool }
-- Rules (WPA 8-ball, as online 8-ball plays it; calling per state.calls):
-- - Break: legal if a ball drops or at least four object balls reach a cushion. The table stays
--   open after the break; the breaker keeps shooting if any object ball dropped. 8 on the
--   break: re-rack, the breaker breaks again unless they fouled.
-- - Open table: any ball but the 8 may be hit first; the first ball legally potted sets groups.
-- - Fouls (ball in hand anywhere for the opponent): cue ball potted, nothing hit, wrong ball
--   first, no ball to a cushion or pocket after contact, illegal break.
-- - 8-ball: wins when potted legally after clearing the group (in the called pocket unless calls
--   is "none"); potted early, on a foul, uncalled or in another pocket loses.
-- - calls "all": only balls in the called pocket score or set the groups; the others stay down. Nothing
--   legal in the called pocket but one of the shooter's balls (any group ball on an open table) in another:
--   foul "wrong pocket", ball in hand (outcome.missedCall too). A plain miss is no foul.
function PoolRules.apply(state, before, result, call: number?)
	if state.game == "nine" then
		return PoolRules9.apply(state, before, result)
	end
	local s = table.clone(state)
	s.groups = table.clone(state.groups)
	local shooter, other = s.turn, 3 - s.turn
	local group = s.groups[shooter]
	local targets = PoolRules.targets(state, before)
	local cleared = group ~= nil and onTable(before, group) == 0
	local needCall = PoolRules.mustCall(state, before)

	-- counted: pocketed object balls that may score (with every shot called, the called pocket's)
	local pocketed, counted, first, firstT, eightPocket = {}, {}, nil, nil, nil
	for _, e in result.events do
		if e.type == "pocket" then
			table.insert(pocketed, e.ball)
			if e.ball ~= 0 and not (needCall and state.calls == "all" and e.pocket ~= call) then
				table.insert(counted, e.ball)
			end
			if e.ball == 8 then
				eightPocket = e.pocket
			end
		elseif e.type == "ball" and not first and (e.a == 0 or e.b == 0) then
			first, firstT = if e.a == 0 then e.b else e.a, e.t
		end
	end
	local rail = false
	local railed, railedCount = {}, 0
	for _, e in result.events do
		if firstT and e.t >= firstT and (e.type == "cushion" or (e.type == "pocket" and e.ball ~= 0)) then
			rail = true
		end
		if e.type == "cushion" and e.ball ~= 0 and not railed[e.ball] then
			railed[e.ball] = true
			railedCount += 1
		end
	end
	local scratched, eight = table.find(pocketed, 0) ~= nil, table.find(pocketed, 8) ~= nil
	local pottedObject = false
	for _, id in pocketed do
		if id ~= 0 then
			pottedObject = true
		end
	end

	local foul
	if scratched then
		foul = "scratch"
	elseif not first then
		foul = "no hit"
	elseif not (targets[first] or (state.isBreak and first == 8)) then
		foul = "wrong ball"
	elseif state.isBreak and not pottedObject and railedCount < 4 then
		foul = "bad break"
	elseif not rail then
		foul = "no rail"
	end

	local outcome = { foul = foul, pocketed = pocketed, assigned = nil, continues = false, rerack = false, wrongPocket = false, missedCall = false }
	if eight and state.isBreak then
		outcome.rerack = true
		local fresh = PoolRules.new(state.calls)
		fresh.turn = if foul then other else shooter
		return fresh, outcome
	end
	if eight then
		outcome.wrongPocket = cleared and needCall and call ~= eightPocket
		s.winner = if cleared and not foul and not outcome.wrongPocket then shooter else other
	end

	if not group and not foul and not s.winner and not state.isBreak then
		for _, id in counted do
			local g = PoolRules.groupOf(id)
			if g then
				s.groups[shooter], s.groups[other] = g, opposite(g)
				outcome.assigned = g
				break
			end
		end
	end

	local scored = false
	for _, id in counted do
		local g = PoolRules.groupOf(id)
		if g and (g == s.groups[shooter] or (state.isBreak and not foul)) then
			scored = true
		end
	end
	outcome.continues = not foul and not s.winner and scored
	-- a ball that would have scored went into a pocket that wasn't called
	for _, id in pocketed do
		local g = PoolRules.groupOf(id)
		if not foul and not s.winner and not scored and g and (g == s.groups[shooter] or not s.groups[shooter]) then
			outcome.missedCall = true
		end
	end
	if outcome.missedCall and state.calls == "all" then
		foul = "wrong pocket"
		outcome.foul = foul
	end

	s.isBreak = false
	s.ballInHand = foul ~= nil and not s.winner
	if not s.winner and not outcome.continues then
		s.turn = other
	end
	return s, outcome
end

-- Must the shooter name a pocket? Never on the break; with calls "all" every other shot, with
-- "eight" (or unset) the shot at the 8, with "none" never.
function PoolRules.mustCall(state, balls): boolean
	if state.game == "nine" then
		return false
	end
	if state.isBreak or state.calls == "none" then
		return false
	end
	local group = state.groups[state.turn]
	return state.calls == "all" or (group ~= nil and onTable(balls, group) == 0)
end

-- First free spot for ball `id` starting at (x, 0) and stepping along the long axis by dir.
local function freeSpot(balls, id, x, dir)
	local R = Config.BallRadius
	for _ = 1, 400 do
		local free = math.abs(x) < Config.TableLength / 2 - R
		for _, b in balls do
			if free and not b.pocket and b.id ~= id and (b.x - x) ^ 2 + b.y ^ 2 < (2 * R) ^ 2 then
				free = false
			end
		end
		if free then
			return x, 0
		end
		x += dir * R / 4
	end
	return x, 0
end

-- Where a pocketed 8 goes back: the foot spot, or the nearest free point behind it.
function PoolRules.respot(balls)
	return freeSpot(balls, 8, Config.TableLength / 4, 1)
end

-- Balls ready for the next shot: a pocketed cue ball returns to the head spot (the next
-- shooter has ball in hand and can move it). A re-rack (outcome.rerack) is up to the caller.
function PoolRules.nextTable(final, outcome)
	if outcome and outcome.game == "nine" then
		return PoolRules9.nextTable(final, outcome)
	end
	local balls = table.create(#final)
	for i, b in final do
		balls[i] = table.clone(b)
	end
	for _, b in balls do
		if b.pocket and b.id == 0 then
			b.pocket = nil
			b.x, b.y = freeSpot(balls, 0, -Config.TableLength / 4, -1)
		end
	end
	return balls
end

-- Is (x, y) a legal place for the cue ball? Inside the cushions, touching no ball, and behind
-- the head string for the break.
function PoolRules.canPlace(state, balls, x: number, y: number): boolean
	local R = Config.BallRadius
	if x ~= x or y ~= y or math.abs(x) > Config.TableLength / 2 - R or math.abs(y) > Config.TableWidth / 2 - R then
		return false
	end
	if state.isBreak and x > -Config.TableLength / 4 then
		return false
	end
	for _, b in balls do
		if b.id ~= 0 and not b.pocket and (b.x - x) ^ 2 + (b.y - y) ^ 2 < (2 * R) ^ 2 then
			return false
		end
	end
	return true
end

return PoolRules
