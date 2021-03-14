--[[

script to peek at the subtitles while they're hidden (press v to toggle that)

recommendation:
- lower your osd-font-size from the default if the text is huge (i use 20)

usage:
- press ctrl+e to show the last subtitle line in the corner of you're screen
- press ctrl+w to rewind to the last line

]]

local show_key = 'ctrl+e'
local show_min_age = 0.8
local show_count = 1
local show_sec = 2
local show_dbl_time = 0.5

local prev_key = 'ctrl+w'
local prev_min_age = 0.8
-- todo: make this show the subtitle seeked to again

--local dump_key = 'ctrl+d'

local Debug = function (fmt, ...) return print(string.format(fmt, ...)) end
local Debug = function (fmt, ...) end

--------------------------------------------------------------------------------

-- collected subtitles go here
-- a "streak" is a continuous range of subtitles with a start and end time
-- new subtitles will be added to the end of the current streak
-- the current streak is the one the playback position is in the range of
--   it may have an end time of "false" to mean "whatever the current playback position is"
-- when seeking, a new streak will be created if the position isn't in the range of any existing one
-- if the playback position reaches the start time of the next streak, it's automatically merged into the current one
local streaks = {}
local streakidx = nil

local reset_state = function ()
	streaks = {}
	streakidx = nil
end

local selected_subtitle_track = 1
local get_selected_subtitle_track = function (track_list)
	track_list = (track_list or mp.get_property_native('track-list'))
	local rv = nil
	for i, t in ipairs(track_list) do
		if t.type == 'sub' and t.selected then
			rv = i
			break
		end
	end
	return rv
end

-- reset it on file change
mp.add_hook('on_load', 50, function ()
	reset_state()
	selected_subtitle_track = get_selected_subtitle_track()
	Debug('file loaded')
end)

-- reset it on subtitle track change
mp.observe_property('track-list', 'native', function (_, track_list)
	local subi = get_selected_subtitle_track()
	if subi ~= selected_subtitle_track then
		reset_state()
		selected_subtitle_track = subi
		Debug('active subtitle track changed')
	end
end)

--------------------------------------------------------------------------------

local streak_should_append_subtitle = function (streak, sub)
	if #streak > 0 then
		-- is it too old?
		if sub.startpos < streak[#streak].startpos then
			return false, 'too old'
		end
		-- do we already have this exact line?
		for i = #streak, 1, -1 do
			if streak[i].startpos == sub.startpos then
				if streak[i].text == sub.text then
					return false, 'already have that one'
				end
			else
				break
			end
		end
	end
	return true
end

local figure_out_streak = function (time_pos)
	for i, streak in ipairs(streaks) do
		if (
			time_pos >= streak.startpos and
			(false == streak.endpos or time_pos <= streak.endpos)
		) then
			return i
		end
	end
	return nil
end

local streak_add_subtitle = function (sub)
	local time_pos = sub.startpos

	Debug('got a subtitle for %.2f-%.2f', sub.startpos, sub.endpos)

	-- don't know which streak we're in?
	if not streakidx then
		Debug(' looking for streakidx...')
		-- index of the streak we would insert a new one after
		local previdx = nil
		for i, streak in ipairs(streaks) do
			-- are we in the range of this one?
			if time_pos >= streak.startpos and time_pos <= streak.endpos then
				streakidx = i
				Debug(' it\'s in range of streak %d (%.2f-%.2f)',
				    streakidx, streak.startpos, streak.endpos)
				break
			end
			if time_pos >= streak.startpos and not previdx then
				previdx = i
			end
		end
		-- couldn't find an existing streak? then create it
		if not streakidx then
			local newidx
			if previdx then
				-- found the previous one? insert after that
				Debug(' no fitting streak found, creating one after %d (%.2f-%.2f)',
				    previdx, streaks[previdx].startpos, streaks[previdx].endpos)
				newidx = previdx+1
			else
				-- couldn't find a previous streak.
				-- either the table is empty, or all the streaks have start times after time_pos
				-- --> add it to the beginning in either case
				Debug(' no fitting streak found, creating one at the beginning')
				newidx = 1
			end
			local streak = {
				startpos = time_pos,
				endpos = false,
			}
			table.insert(streaks, newidx, streak)
			streakidx = newidx
			Debug(' now have %d streaks', #streaks)
		end
	end

	-- if we know the end timestamp of this streak but are past it,
	-- set it to false to represent "whatever the current playback position is"
	if (
		false ~= streaks[streakidx].endpos and
		time_pos >= streaks[streakidx].endpos
	) then
		Debug('passed end timestamp of streak %d (%.2f-%.2f) time_pos=%.2f',
		    streakidx,
		    streaks[streakidx].startpos, streaks[streakidx].endpos or math.huge,
		    time_pos)
		streaks[streakidx].endpos = false
	end

	local should, whynot = streak_should_append_subtitle(streaks[streakidx], sub)
	if should then
		Debug('adding sub %.2f-%.2f to streak %d (%.2f-%.2f)',
		    sub.startpos, sub.endpos,
		    streakidx, streaks[streakidx].startpos, streaks[streakidx].endpos or math.huge)
		table.insert(streaks[streakidx], sub)
	else
		Debug('will NOT add sub %.2f-%.2f to streak %d (%.2f-%.2f): %s',
		    sub.startpos, sub.endpos,
		    streakidx, streaks[streakidx].startpos, streaks[streakidx].endpos or math.huge,
		    whynot)
	end

	-- if there's another streak after this one and we've reached its start timestamp,
	-- merge it into this one
	while (
		streakidx < #streaks and
		time_pos >= streaks[streakidx+1].startpos
	) do
		Debug('current streak %d (%.2f-%.2f) has reached streak %d (%.2f-%.2f), merging',
		    streakidx, streaks[streakidx].startpos, time_pos,
		    streakidx+1, streaks[streakidx+1].startpos, streaks[streakidx+1].endpos)
		Debug('will have %d streaks after this', #streaks-1)
		local copies, skips = 0, 0
		for _, sub in ipairs(streaks[streakidx+1]) do
			local should, whynot = streak_should_append_subtitle(streaks[streakidx], sub)
			if should then
				table.insert(streaks[streakidx], sub)
				copies = copies+1
			else
				Debug(' skipping sub at %.2f-%.2f during merge: %s',
				    sub.startpos, sub.endpos,
				    whynot)
				skips = skips+1
			end
		end
		Debug(' copied %d/%d subs, skipped %d',
		    copies, #streaks[streakidx+1], skips)
		-- max() the range
		if streaks[streakidx+1].endpos > (streaks[streakidx].endpos or time_pos) then
			streaks[streakidx].endpos = streaks[streakidx+1].endpos
		end
		table.remove(streaks, streakidx+1)
	end
end

--------------------------------------------------------------------------------

local ignore_next_seek = false

mp.register_event('seek', function ()
	if ignore_next_seek then
		ignore_next_seek = false
		return
	end

	-- if the current streak has no end timestamp, set it here
	if (
		streakidx and
		streaks[streakidx] and
		false == streaks[streakidx].endpos
	) then
		-- the time-pos property is what was seeked to.
		-- use the time of the last subtitle in the streak
		local time_pos = streaks[streakidx][#streaks[streakidx]].startpos
		Debug('ending streak %d here (%.2f)', streakidx, time_pos)
		streaks[streakidx].endpos = time_pos
	end

	streakidx = nil
end)

--------------------------------------------------------------------------------

mp.observe_property('sub-text', 'native', function (_, sub_text)
	if not sub_text then
		return
	end

	local startpos = mp.get_property_native('sub-start')
	local endpos = mp.get_property_native('sub-end')
	if not (startpos and endpos) then
		return
	end

	streak_add_subtitle({
		text = sub_text,
		startpos = startpos,
		endpos = endpos,
	})
end)

--------------------------------------------------------------------------------

if dump_key then

mp.add_key_binding(dump_key, function ()
	Debug('streakidx=%d', streakidx or -1)
	Debug('streaks (%d):', #streaks)
	for stri, streak in ipairs(streaks) do
		Debug('  streak %d (%.2f-%.2f):', stri, streak.startpos, streak.endpos or math.huge)
		for _, sub in ipairs(streak) do
			local txt = sub.text:gsub('\n', ' ')
			if #txt > 30 then txt = txt:sub(1, 30)..'(...)' end
			Debug('    %s (%.2f-%.2f)', txt, sub.startpos, sub.endpos)
		end
	end
end)

end -- if dump_key

--------------------------------------------------------------------------------

local last_show_time = 0
local show_mult = 0
local show_last_idx = nil

if show_key then

mp.add_key_binding(show_key, function ()
	local time_pos = mp.get_property_native('time-pos')
	local streakidx = figure_out_streak(time_pos)
	if not streakidx then
		mp.osd_message('(...)', show_sec)
		return
	end

	local clock_now = mp.get_time()
	if clock_now <= last_show_time+show_dbl_time then
		Debug('+1')
		show_mult = show_mult+1
		show_last_idx = show_last_idx
	elseif clock_now <= last_show_time+show_sec then
		Debug('no change, still open')
		show_mult = show_mult
		show_last_idx = show_last_idx
	else
		Debug('0')
		show_mult = 0
		show_last_idx = nil
	end
	last_show_time = clock_now

	local lineidx = nil
	for i, sub in ipairs(streaks[streakidx]) do
		if sub.startpos+show_min_age <= time_pos then
			lineidx = i
		else
			break
		end
	end
	if not lineidx then
		Debug('huh?')
		mp.osd_message('(...)', show_sec)
		return
	end

	if not show_last_idx then
		show_last_idx = math.max(1, lineidx-(show_count-1))
	end

	local startidx = math.max(0, show_last_idx-show_mult)
	local endidx = lineidx

	Debug('startidx=%d endidx=%d show_mult=%d', startidx, endidx, show_mult)

	local lines = {}
	if startidx == 0 then
		table.insert(lines, '(...)')
		startidx = 1
	end
	for i = startidx, endidx do
		local sub = streaks[streakidx][i]
		local s = string.format('[%s] %s',
		    os.date('!%H:%M:%S', math.floor(sub.startpos)),
		    sub.text:gsub('\n', ' '):gsub('  +', ' '):gsub('^ +', ''))
		table.insert(lines, s)
	end

	mp.osd_message(table.concat(lines, '\n'), show_sec)
end)

end -- if show_key

--------------------------------------------------------------------------------

if prev_key then

mp.add_key_binding(prev_key, function ()
	local time_pos = mp.get_property_native('time-pos')
	local streakidx = figure_out_streak(time_pos)
	if not streakidx then
		mp.osd_message('(no line to seek to)', show_sec)
		return
	end

	local lineidx = nil
	for i, sub in ipairs(streaks[streakidx]) do
		if sub.startpos+prev_min_age <= time_pos then
			lineidx = i
		else
			break
		end
	end
	if not lineidx then
		Debug('huh?')
		mp.osd_message('(no line to seek to)', show_sec)
		return
	end

	Debug('seeking to line %d at %.2f', lineidx, streaks[streakidx][lineidx].startpos)

	ignore_next_seek = true
	mp.set_property_native('time-pos', streaks[streakidx][lineidx].startpos)
end)

end -- if prev_key
