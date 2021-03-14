--[[
--https://gist.github.com/huglovefan/dbe057a82d4f5c8348cb12a593356ec1
requires:
- linux
- ffmpeg
- a smaller osd-font-size than the default (i use 20)
intended usage:
- watch foreign-language bideo
- turn off subtitles
- didn't understand what was just said? press `cfg.prev_key` to hear it again
- that didn't help? press `cfg.show_key` to see what the subtitles say
]]

local cfg = {
	show_key = 'ctrl+e', -- key to show them
	show_min_age = 0.8,  -- don't show lines that aren't at least this many seconds old
	show_count = 1,      -- show this many lines
	show_sec = 2,        -- ... for this many seconds
	show_dbl_time = 0.5, -- press the key again this fast to show one more line

	prev_key = 'ctrl+w', -- key to rewind the video to the line just said
	prev_min_age = 0.8,  -- ignore lines that aren't at least this old
	prev_info = 'time',  -- "time" or "line" -- show what we just seeked to
	next_key = 'ctrl+t', -- [new] key to seek to the next line

	select_key = 'ctrl+r', -- select the current subtitle track instead of guessing which one to show

	stats_key = 'ctrl+t', -- show how much of the subtitles you've heard/revealed (approximate)
	stats_file = '/tmp/subcorner.stats', -- write stats to this file on exit (in case you forget to check them) (nil to disable)
}

local state
local guess_subtitle_track = function (tracks)
	if state.selected_track_idx and tracks[state.selected_track_idx] then
		return tracks[state.selected_track_idx]
	end
	for _, track in ipairs(tracks) do
		for _, lang in ipairs(mp.get_property_native('slang', {})) do
			if track.lang == lang then
				return track
			end
		end
	end
	return tracks[1]
end

-- make show_min_age 0 if some subtitle track is visible in mpv
-- this way we'll always show the currently visible line
local min_age_default = cfg.show_min_age
local update_min_age = function (...)
	local min_age = min_age_default
	for _, t in ipairs(mp.get_property_native('track-list', {})) do
		if t.type == 'sub' and t.selected then
			min_age = 0
			break
		end
	end
	cfg.show_min_age = min_age
end
mp.observe_property('sid', 'native', update_min_age)

--------------------------------------------------------------------------------

local reset_state = function ()
	if state and state.watch_timer then
		state.watch_timer:stop()
	end
	state = {
		dialogue = nil,
		show_last_used = 0,
		show_first_idx = 0,
		selected_track_idx = nil,
		prev_last_used = 0,
		prev_idx = 0,
		watched_seconds = nil,
		watch_timer = nil,
		cheated_lines = nil,
	}
end
reset_state()

--------------------------------------------------------------------------------

-- epic copypasta

local trim = function (s)
	return (s:gsub('^[ \t\r\n]+', ''):gsub('[ \t\r\n]+', ' '):gsub('[ \t\r\n]+$', ''))
end

local urldecode = function (s)
	return (s:gsub('%+', ' '):gsub('%%(%x%x)', function (c)
		return string.char(tonumber(c, 16))
	end))
end

local shellquote = function (s)
	return '\'' .. s:gsub('\'', '\'\\\'\'') .. '\''
end

local fileurl2local = function (s)
	if s:find('^file://') then
		return urldecode(s:gsub('^file://', '', 1))
	else
		return s
	end
end

local open_as_utf8 = function (filepath)
	return io.popen([[
	file=]]..shellquote(filepath)..'\n'..[[
	e=$(file -b --mime-encoding "$file")
	if [ -z "$e" -o "$e" = binary ]; then # invalid encoding
		exec cat "$file"
	fi
	exec iconv -f "$e" -t UTF-8 <"$file"
	]])
end

local exec_ok = os.execute
if _VERSION == 'Lua 5.1' then
	exec_ok = function (...)
		return (os.execute(...) == 0)
	end
end

local get_ms = function ()
	local p = io.popen('exec date +%s%N')
	local s = p:read('*a'):gsub('[0-9][0-9][0-9][0-9][0-9][0-9]\n?$', '', 1)
	p:close()
	return tonumber(s)
end

--------------------------------------------------------------------------------

local commasplit = function (s)
	local t = {}
	for p in s:gsub(',', ' , '):gmatch('[^,]+') do
		t[#t+1] = trim(p:gsub(' , ', ','))
	end
	return t
end

local parse_formatted = function (s, format_keys)
	local t = {}
	local i = 1
	for val in s:gsub(',', ' , '):gmatch('[^,]+') do
		if i > #format_keys then -- last field contains a comma
			t[format_keys[#format_keys]] =
				trim(s:gsub('^' .. string.rep('[^,]*, *', #format_keys-1), '', 1))
			break
		end
		t[format_keys[i]] = trim(val:gsub(' , ', ','))
		i = i + 1
	end
	return t
end

local ass_ts2sec = function (ts)
	local h, m, s, A = ts:match('^([0-9]+):([0-9]+):([0-9]+)%.([0-9]+)$')
	if not h then
		return -1
	end
	return tonumber(h)*60*60 + tonumber(m)*60 + tonumber(s) + tonumber(A)/100
end

local parse_ass = function (file)
	local format = {}
	local dialogue = {}
	for line in file:lines() do
		line = trim(line)
		local m = line:match('^Format:(.*)$')
		if m then
			format = commasplit(m)
		else
		local m = line:match('^Dialogue:(.*)$')
		if m then
			dialogue[#dialogue+1] = parse_formatted(m, format)
		end
	end end
	file:close()
	return {
		dialogue = dialogue,
	}
end

--------------------------------------------------------------------------------

local g_subtitle_tmpfilename = '/tmp/subside.ass'

local is_supported = function (t)
	return (t.codec == 'ass' or t.codec == 'subrip')
end
local get_subtracks = function ()
	local them = {}
	for _, t in ipairs(mp.get_property_native('track-list', {})) do
		if t.type == 'sub' and is_supported(t) then
			table.insert(them, t)
		end
	end
	return them
end

local get_ass_subfile = function (t)
	if t.codec == 'ass' and t.external then
		return fileurl2local(t['external-filename'])
	end
	local tmpfilename = g_subtitle_tmpfilename
	if (t.codec == 'ass' or t.codec == 'subrip') and not t.external then
		mp.osd_message('extracting subtitles... (this is slow)', 2)
		if not exec_ok(string.format(
		'exec ffmpeg -y -loglevel error -i %s -map 0:%s -f ass %s',
			shellquote(mp.get_property('path')),
			shellquote(tostring(t['ff-index'])),
			shellquote(tmpfilename)))
		then
			return nil, 'failed to extract subtitles'
		end
		return tmpfilename
	end
	if t.codec == 'subrip' and t.external then
		mp.osd_message('converting subtitles...')
		if not exec_ok(string.format(
		'exec ffmpeg -y -loglevel error -i %s -f ass %s',
			shellquote(fileurl2local(t['external-filename'])),
			shellquote(tmpfilename)))
		then
			return nil, 'failed to convert subtitles'
		end
		return tmpfilename
	end
	return nil, 'subtitle format not supported'
end

--------------------------------------------------------------------------------

local watch_timer_tick = function ()
	if not state.watched_seconds then return end
	local sec = math.floor(mp.get_property_native('time-pos', 0))
	state.watched_seconds[sec] = true
end

local load_dialogue = function ()
	if state.dialogue then return true end
	local st = guess_subtitle_track(get_subtracks())
	if not st then
		mp.osd_message('error: no subtitle tracks found')
		return false
	end
	local ass, err = get_ass_subfile(st)
	if not ass then
		mp.osd_message('error: ' .. err)
		return false
	end
	local dialogue = parse_ass(open_as_utf8(ass)).dialogue
	if ass == g_subtitle_tmpfilename then
		os.execute(string.format('rm -f -- %s', g_subtitle_tmpfilename))
	end

	local tfilter = function (t, fn)
		local t2 = {}
		for i = 1, #t do
			local v = fn(t[i])
			if v ~= nil then
				t2[#t2+1] = v
			end
		end
		return t2
	end
	local array_without = function (a, t)
		return tfilter(a, function (t_) if t_ ~= t then return t_ end return nil end)
	end

	-- initial filtering
	local ends_at = {}
	local prev = nil
	dialogue = tfilter(dialogue, function (t)
		t.Text = trim(t.Text:gsub('{[^}]*}', ''):gsub('\\N', ' '))
		if t.Text == '' then return nil end
		if t.Text:find('^m [0-9]+ [0-9]+ ') then return nil end
		if prev then
			if prev.Text == t.Text and prev.Start == t.Start and t.End == t.End then
				return nil
			end
		end
		ends_at[t.End] = (ends_at[t.End] or {}) table.insert(ends_at[t.End], t)
		prev = t
		return t
	end)

	-- more filtering
	local is_continuation = function (t)
		local rv = false
		if ends_at[t.Start] then
			ends_at[t.Start] = tfilter(ends_at[t.Start], function (told)
				if told.Text == t.Text then
					rv = true
					ends_at[told.End] = array_without(ends_at[told.End], told)
					told.End = t.End
					ends_at[t.End] = (ends_at[t.End] or {})
					table.insert(ends_at[t.End], told)
				end
				return told
			end)
		end
		return rv
	end
	local make_timestamp = function (stamp)
		stamp = stamp:gsub('^[^1-9]+', '', 1)
		if stamp == '' then
			stamp = '0.00'
		end
		return stamp
	end
	dialogue = tfilter(dialogue, function (t)
		if is_continuation(t) then
			return nil
		end
		return {
			Start = ass_ts2sec(t.Start),
			Start_ = make_timestamp(t.Start),
			Text = t.Text,
		}
	end)

	-- sort!!
	table.sort(dialogue, function (t1, t2)
		if t1.Start_ ~= t2.Start_ then
			return t1.Start < t2.Start
		else
			return t1.Text < t2.Text
		end
	end)

	if update_min_age then update_min_age() end

	local watched_seconds = {}
	for i = 0, math.ceil(mp.get_property_native('duration', 0)) do
		watched_seconds[i] = false
	end
	state.watched_seconds = watched_seconds

	local cheated_lines = {}
	for i = 1, #dialogue do
		cheated_lines[i] = false
	end
	state.cheated_lines = cheated_lines

	state.watch_timer = mp.add_periodic_timer(0.5, watch_timer_tick)
	if mp.get_property_native('pause') then
		state.watch_timer:stop()
	end

	state.dialogue = dialogue
	return true
end

local last_pos_of = function (fn)
	local idx = 1
	for i, t in ipairs(state.dialogue) do
		if fn(t) then
			idx = i
		else
			break
		end
	end
	return idx
end

if cfg.show_key then
mp.add_key_binding(cfg.show_key, function ()
	if not load_dialogue() then return end

	local now_sec = mp.get_property_native('time-pos', 0)
	local lastidx = last_pos_of(function (t)
		return t.Start+cfg.show_min_age <= now_sec
	end)

	local clock_sec = get_ms()/1000

	-- if we just did "prev", make sure we show the line it seeked to
	local did_seek = false
	if clock_sec <= state.prev_last_used+cfg.show_sec then
		state.prev_last_used = clock_sec
		lastidx = math.max(state.prev_idx, lastidx)
		did_seek = true
	end

	local firstidx = math.max(1, lastidx-(cfg.show_count-1))

	if clock_sec <= state.show_last_used+cfg.show_sec then
		firstidx = state.show_first_idx
		if clock_sec <= state.show_last_used+cfg.show_dbl_time then
			firstidx = math.max(1, firstidx-1)
		end
	end

	firstidx = math.min(lastidx, firstidx)
	state.show_first_idx = firstidx
	state.show_last_used = clock_sec

	local lines = {}
	for i = firstidx, lastidx do
		local t = state.dialogue[i]
		-- don't check the time if we just seeked. it sometimes rewinds more than necessary
		if t and (t.Start <= now_sec or did_seek) then
			table.insert(lines, string.format('[%s] %s', t.Start_, t.Text))
			state.cheated_lines[i] = true
		end
	end

	if #lines == 0 then lines = {'(no lines to show)'} end
	mp.osd_message(table.concat(lines, '\n'), cfg.show_sec)
end)
end

local prev_or_next = function (is_next)
	if not load_dialogue() then return end

	local now_sec = mp.get_property_native('time-pos', 0)
	local idx
	if is_next then
		idx = last_pos_of(function (t)
			local seek_error = 0.1
			return t.Start-seek_error <= now_sec
		end)
	else
		idx = last_pos_of(function (t)
			return t.Start+cfg.prev_min_age <= now_sec
		end)
	end
	local t = state.dialogue[idx+(is_next and 1 or 0)]
	if not t then
		mp.osd_message('(no line to seek to)', cfg.show_sec)
		return
	end

	state.machine_seek = true
	mp.set_property_native('time-pos', t.Start)

	local now = get_ms()/1000
	state.prev_idx = idx
	state.prev_last_used = now

	if not (cfg.prev_info == 'time' or cfg.prev_info == 'line') then
		return
	end

	-- currently showing lines from "show" => make sure those are also shown
	if now <= state.show_last_used+cfg.show_sec then
		state.show_last_used = now

		local firstidx = state.show_first_idx
		local lastidx = idx
		firstidx = math.min(lastidx, firstidx)

		local lines = {}
		for i = firstidx, lastidx do
			local t = state.dialogue[i]
			if t and t.Start <= now_sec then
				table.insert(lines, string.format('[%s] %s', t.Start_, t.Text))
				state.cheated_lines[i] = true
			end
		end

		if #lines == 0 then lines = {'(no lines to show)'} end -- ?????
		mp.osd_message(table.concat(lines, '\n'), cfg.show_sec)

		return
	end

	if cfg.prev_info == 'time' then
		mp.osd_message(string.format('[%s]', t.Start_), cfg.show_sec)
	elseif cfg.prev_info == 'line' then
		mp.osd_message(string.format('[%s] %s', t.Start_, t.Text), cfg.show_sec)
		state.cheated_lines[idx] = true
	end
end

if cfg.prev_key then
mp.add_key_binding(cfg.prev_key, function ()
	return prev_or_next(false)
end)
end

if cfg.next_key then
mp.add_key_binding(cfg.next_key, function ()
	return prev_or_next(true)
end)
end

if cfg.select_key then
mp.add_key_binding(cfg.select_key, function ()
	local idx = nil
	for i, t in ipairs(get_subtracks()) do
		if t.selected then
			idx = i
			break
		end
	end
	if idx ~= state.selected_track_idx then
		state.dialogue = nil
	end
	state.selected_track_idx = idx
	if idx then
		mp.osd_message(string.format('selected track %s', tostring(idx)))
	else
		mp.osd_message('selected track cleared')
	end
end)
end

local get_stats = function ()
	if not state.dialogue then return nil end
	local total_seconds_watched_containing_lines = 0
	local total_seconds_containing_lines = 0
	local total_seconds_cheated_containing_lines = 0
	local lineidx = 1
	for i = 0, #state.watched_seconds do
		local watched_this = (state.watched_seconds[i])
		local this_had_line = false
		local cheated_this = false
		while lineidx <= #state.dialogue and math.floor(state.dialogue[lineidx].Start) <= i do
			if math.floor(state.dialogue[lineidx].Start) == i then this_had_line = true end
			if state.cheated_lines[lineidx] then cheated_this = true end
			lineidx = (lineidx + 1)
		end
		if this_had_line then
			total_seconds_containing_lines = (total_seconds_containing_lines + 1)
		end
		if watched_this and this_had_line then
			total_seconds_watched_containing_lines = (total_seconds_watched_containing_lines + 1)
		end
		if cheated_this then total_seconds_cheated_containing_lines = (total_seconds_cheated_containing_lines + 1) end
	end
	local lines = {}
	lines[#lines+1] = string.format('watched: %d/%d (%.2f%%)', total_seconds_watched_containing_lines, total_seconds_containing_lines, (total_seconds_watched_containing_lines/total_seconds_containing_lines)*100)
	lines[#lines+1] = string.format('cheated: %d/%d (%.2f%%)', total_seconds_cheated_containing_lines, total_seconds_watched_containing_lines, (total_seconds_cheated_containing_lines/total_seconds_watched_containing_lines)*100)
	return table.concat(lines, '\n')
end

local maybe_save_stats = function ()
	if not cfg.stats_file then return end
	local stats = get_stats()
	if not stats then return end
	local f = io.open(cfg.stats_file, 'w')
	if not f then return end
	f:write(stats)
	f:close()
end

local maybe_load_stats = function ()
	local rv = nil
	if cfg.stats_file then
		local f = io.open(cfg.stats_file, 'r')
		if f then
			rv = f:read('*a')
			f:close()
		end
	end
	return rv
end

if cfg.stats_key then
mp.add_key_binding(cfg.stats_key, function ()
	local stats = get_stats()
	if not stats then
		stats = maybe_load_stats()
		if not stats then return end
		stats = (stats .. '\n(last session)')
	end
	mp.osd_message(stats, 4)
end)
end

mp.add_hook('on_load', 50, function ()
	maybe_save_stats()
	reset_state()
end)

mp.register_event('shutdown', function ()
	maybe_save_stats()
	reset_state()
end)

mp.register_event('seek', function ()
	if state.machine_seek then
		state.machine_seek = false
		return
	end
	state.show_last_used = 0
	state.prev_last_used = 0
end)

mp.observe_property('pause', 'native', function (_, paused)
	if not state.watch_timer then return end
	if paused then
		state.watch_timer:stop()
	else
		state.watch_timer:resume()
	end
end)
