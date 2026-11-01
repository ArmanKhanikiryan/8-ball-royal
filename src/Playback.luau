-- Ball positions between shot keyframes. A monotone cubic (Fritsch-Carlson) instead of straight
-- lines, so speed changes smoothly instead of in 30 Hz steps: the slope at a keyframe is 0 where the
-- motion turns or stops (a stopping ball never overshoots) and at most 3x the smaller neighbouring
-- slope. At a keyframe with a contact the curve takes the interval's own slope, so hits stay sharp.
local Playback = {}

local function slopeAt(d1, d2)
	if d1 * d2 <= 0 then
		return 0
	end
	local cap = 3 * math.min(math.abs(d1), math.abs(d2))
	return math.clamp((d1 + d2) / 2, -cap, cap)
end

-- frames[k][o + c]: coordinate c of the ball at offset o in keyframe k (times[k]); a: 0..1 through
-- interval k; isContact(j): keyframe j is a contact
function Playback.position(frames, times, isContact, k: number, a: number, o: number, c: number): number
	local f0, f1 = frames[k], frames[k + 1]
	local p0 = f0[o + c]
	if not f1 then
		return p0
	end
	local span = times[k + 1] - times[k]
	if span <= 1e-6 then
		return f1[o + c]
	end
	local p1 = f1[o + c]
	local d = (p1 - p0) / span
	local m0, m1 = d, d
	local fp, fn = frames[k - 1], frames[k + 2]
	if fp and times[k] - times[k - 1] > 1e-6 and not isContact(k) then
		m0 = slopeAt((p0 - fp[o + c]) / (times[k] - times[k - 1]), d)
	end
	if fn and times[k + 2] - times[k + 1] > 1e-6 and not isContact(k + 1) then
		m1 = slopeAt(d, (fn[o + c] - p1) / (times[k + 2] - times[k + 1]))
	end
	local a2 = a * a
	local a3 = a2 * a
	return (2 * a3 - 3 * a2 + 1) * p0 + (a3 - 2 * a2 + a) * span * m0 + (3 * a2 - 2 * a3) * p1 + (a3 - a2) * span * m1
end

return Playback
