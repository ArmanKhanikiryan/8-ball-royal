-- 9-ball rules, the way online 9-ball plays them, simplified. Pure: PoolRules hands a
-- state with game = "nine" here, so every caller of PoolRules plays 9-ball without knowing it.
--
-- state = { game = "nine", turn = 1 | 2, groups = {} (unused), ballInHand, isBreak, winner, calls = "none" }
-- - Balls 1-9, the 1 at the apex on the foot spot, the 9 in the middle (PoolPhysics.rack9).
-- - Every shot must first hit the lowest numbered ball on the table; any ball potted after a legal hit
--   keeps the turn. No pocket calls.
-- - The 9 potted on a legal shot wins: a combination, a carom or on the break. Potted on a foul it
--   goes back to the foot spot and the opponent has ball in hand.
-- - Fouls (ball in hand anywhere for the opponent): cue ball potted, nothing hit, the lowest ball not
--   hit first, no ball to a cushion or pocket after contact.
-- - Break: legal if a ball drops or at least four object balls reach a cushion; else a foul (the
--   opponent has ball in hand: the simplification chosen over a re-break). 3 fouls in a row: off.
local Config = require("./Config")

local PoolRules9 = {}

function PoolRules9.new()
	return { game = "nine", turn = 1, groups = {}, ballInHand = true, isBreak = true, winner = nil, calls = "none" }
end

-- the lowest numbered object ball on the table, or nil
function PoolRules9.lowest(balls): number?
	local low
	for _, b in balls do
		if not b.pocket and b.id ~= 0 and (low == nil or b.id < low) then
			low = b.id
		end
	end
	return low
end

-- ids the shooter may hit first: the lowest ball only
function PoolRules9.targets(_state, balls)
	local low = PoolRules9.lowest(balls)
	return if low then { [low] = true } else {}
end

function PoolRules9.mustCall(_state, _balls): boolean
	return false
end

-- before: balls at the start of the shot; result: PoolPhysics.simulate output. Returns the next state
-- and { foul, pocketed, continues, respot9, rerack = false, assigned = nil, wrongPocket = false,
-- missedCall = false } (PoolRules.apply's outcome shape).
function PoolRules9.apply(state, before, result)
	local s = table.clone(state)
	local shooter, other = s.turn, 3 - s.turn
	local low = PoolRules9.lowest(before)
	local pocketed, first, firstT = {}, nil, nil
	for _, e in result.events do
		if e.type == "pocket" then
			table.insert(pocketed, e.ball)
		elseif e.type == "ball" and not first and (e.a == 0 or e.b == 0) then
			first, firstT = if e.a == 0 then e.b else e.a, e.t
		end
	end
	local rail, railed, railedCount = false, {}, 0
	for _, e in result.events do
		if firstT and e.t >= firstT and (e.type == "cushion" or (e.type == "pocket" and e.ball ~= 0)) then
			rail = true
		end
		if e.type == "cushion" and e.ball ~= 0 and not railed[e.ball] then
			railed[e.ball] = true
			railedCount += 1
		end
	end
	local scratched, nine, pottedObject = false, false, false
	for _, id in pocketed do
		scratched = scratched or id == 0
		nine = nine or id == 9
		pottedObject = pottedObject or id ~= 0
	end
	local foul
	if scratched then
		foul = "scratch"
	elseif not first then
		foul = "no hit"
	elseif first ~= low then
		foul = "wrong ball"
	elseif state.isBreak and not pottedObject and railedCount < 4 then
		foul = "bad break"
	elseif not rail then
		foul = "no rail"
	end
	local outcome = { foul = foul, pocketed = pocketed, assigned = nil, continues = false, rerack = false, wrongPocket = false, missedCall = false, respot9 = nine and foul ~= nil, game = "nine" }
	if nine and not foul then
		s.winner = shooter
	end
	outcome.continues = not foul and not s.winner and pottedObject
	s.isBreak = false
	s.ballInHand = foul ~= nil and not s.winner
	if not s.winner and not outcome.continues then
		s.turn = other
	end
	return s, outcome
end

-- the first free spot for ball `id` from (x, 0) along the long axis by dir
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

-- Balls for the next shot: a potted cue ball back on the head spot (the next shooter has ball in hand),
-- a 9 potted on a foul back on the foot spot (or the nearest free point behind it).
function PoolRules9.nextTable(final, outcome)
	local balls = table.create(#final)
	for i, b in final do
		balls[i] = table.clone(b)
	end
	for _, b in balls do
		if b.pocket and b.id == 0 then
			b.pocket = nil
			b.x, b.y = freeSpot(balls, 0, -Config.TableLength / 4, -1)
		elseif b.pocket and b.id == 9 and outcome and outcome.respot9 then
			b.pocket = nil
			b.x, b.y = freeSpot(balls, 9, Config.TableLength / 4, 1)
		end
	end
	return balls
end

return PoolRules9
