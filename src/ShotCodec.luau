-- Packs simulation frames into a buffer for a RemoteEvent. Each frame lists only the balls that
-- changed since the previous one; positions and spins are 16-bit integers.
local POS = 20000 -- units per meter: 0.05 mm steps, +-1.6 m
local SPIN = 50 -- units per rad/s: +-655 rad/s

local ShotCodec = {}

local function q(v, scale)
	return math.clamp(math.round(v * scale), -32768, 32767)
end

function ShotCodec.encode(times, frames, ballCount: number): buffer
	local buf = buffer.create(3 + #frames * (5 + ballCount * 11))
	buffer.writeu16(buf, 0, #frames)
	buffer.writeu8(buf, 2, ballCount)
	local at = 3
	local last = {}
	for k, f in frames do
		buffer.writef32(buf, at, times[k])
		local countAt = at + 4
		at += 5
		local changed = 0
		for i = 1, ballCount do
			local o = (i - 1) * 5
			local vals = { q(f[o + 1], POS), q(f[o + 2], POS), q(f[o + 3], SPIN), q(f[o + 4], SPIN), q(f[o + 5], SPIN) }
			local prev = last[i]
			if not prev or prev[1] ~= vals[1] or prev[2] ~= vals[2] or prev[3] ~= vals[3] or prev[4] ~= vals[4] or prev[5] ~= vals[5] then
				last[i] = vals
				changed += 1
				buffer.writeu8(buf, at, i)
				for v = 1, 5 do
					buffer.writei16(buf, at + 1 + (v - 1) * 2, vals[v])
				end
				at += 11
			end
		end
		buffer.writeu8(buf, countAt, changed)
	end
	local out = buffer.create(at)
	buffer.copy(out, 0, buf, 0, at)
	return out
end

-- Returns times, frames in the same layout as PoolPhysics.simulate.
function ShotCodec.decode(buf: buffer)
	local count, balls = buffer.readu16(buf, 0), buffer.readu8(buf, 2)
	local times, frames = table.create(count), table.create(count)
	local at = 3
	local cur = table.create(balls * 5, 0)
	for k = 1, count do
		times[k] = buffer.readf32(buf, at)
		local changed = buffer.readu8(buf, at + 4)
		at += 5
		for _ = 1, changed do
			local o = (buffer.readu8(buf, at) - 1) * 5
			cur[o + 1] = buffer.readi16(buf, at + 1) / POS
			cur[o + 2] = buffer.readi16(buf, at + 3) / POS
			cur[o + 3] = buffer.readi16(buf, at + 5) / SPIN
			cur[o + 4] = buffer.readi16(buf, at + 7) / SPIN
			cur[o + 5] = buffer.readi16(buf, at + 9) / SPIN
			at += 11
		end
		frames[k] = table.clone(cur)
	end
	return times, frames
end

return ShotCodec
