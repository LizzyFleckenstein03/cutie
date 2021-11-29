local posix = {
	termio = require("posix.termio"),
	poll = require("posix.poll"),
	unistd = require("posix.unistd"),
}

local cutie = {
	esc = string.char(27) .. "[",
	terminal_size = nil,
	buffer = "",
	input = EventTarget()
}

-- colors

local function color_from_hue(hue)
	local h = hue / 60
	local x = (1 - math.abs(h % 2 - 1))

	local i = math.floor(h)

	if i == 0 then
		return {1, x, 0}
	elseif i == 1 then
		return {x, 1, 0}
	elseif i == 2 then
		return {0, 1, x}
	elseif i == 3 then
		return {0, x, 1}
	elseif i == 4 then
		return {x, 0, 1}
	else
		return {1, 0, x}
	end
end

function cutie.to_color(color)
	local t = type(color)

	if t == "number" then
		return color_from_hue(color)
	elseif t == "string" then
		local color = color:gsub("#", "")

		return {
			tonumber(color:sub(1, 2), 16) / 255,
			tonumber(color:sub(3, 4), 16) / 255,
			tonumber(color:sub(5, 6), 16) / 255,
		}
	else
		return color
	end
end

function make_color(color, bg)
	color = cutie.to_color(color)

	return cutie.esc
		.. (bg and "48" or "38") .. ";2"
		.. ";" .. math.clamp(math.floor(color[1] * 255), 0, 255)
		.. ";" .. math.clamp(math.floor(color[2] * 255), 0, 255)
		.. ";" .. math.clamp(math.floor(color[3] * 255), 0, 255)
		.. "m"
end

function cutie.color(color)
	return make_color(color, false)
end

function cutie.background_color(color)
	return make_color(color, true)
end

function cutie.set_color(color)
	cutie.render(cutie.color(color))
end

function cutie.set_background(color)
	cutie.render(cutie.background_color(color))
end

-- simple effects

cutie.bold = cutie.esc .. "1m"
cutie.no_effects = cutie.esc .. "0m"

function cutie.set_bold()
	cutie.render(cutie.bold)
end

function cutie.clear_effects()
	cutie.render(cutie.no_effects)
end

function cutie.move_cursor(x, y)
	cutie.render_escape(math.floor(y) .. ";" .. math.floor(x) .. "H")
end

function cutie.set_alternate_buffer(enabled)
	cutie.render_escape("?1049" .. (enabled and "h" or "l"))
end

function cutie.set_cursor_shown(enabled)
	cutie.render_escape("?25" .. (enabled and "h" or "l"))
end

-- input

function cutie.set_canon_input(enabled)
	local termios = posix.termio.tcgetattr(0)

	if enabled then
		termios.lflag = bit32.bor(termios.lflag,
			posix.termio.ICANON,
			posix.termio.ECHO
		)
	else
		termios.lflag = bit32.band(termios.lflag, bit32.bnot(bit32.bor(
			posix.termio.ICANON,
			posix.termio.ECHO
		)))
	end

	posix.termio.tcsetattr(0, posix.termio.TCSANOW, termios)
end

function cutie.set_input_buffer(enabled)
	lua_async.poll_functions[cutie.poll_input] = enabled or nil

	cutie.input.buffer = enabled and "" or nil
	cutie.input.history = enabled and {} or nil
	cutie.input.cursor = nil
end

local function getchar()
	return posix.unistd.read(0, 1)
end

function cutie.poll_input()
	local pfd = {[0] = {events = {IN = true}}}
	posix.poll.poll(pfd, 0)

	if pfd[0].revents and pfd[0].revents.IN then
		local char = getchar()

		if char == "\n" then
			if input ~= "" then
				cutie.input:dispatchEvent(Event("input", {input = cutie.input.buffer}))
				table.insert(cutie.input.history, cutie.input.buffer)
				cutie.input.buffer = ""
				cutie.input.cursor = nil
			end
		elseif char == cutie.esc:sub(1, 1) then
			local char2 = getchar()

			if char2 == cutie.esc:sub(2, 2) then
				local char3 = getchar()

				if char3 == "A" or char3 == "B" then
					cutie.input.cursor = (cutie.input.cursor or #cutie.input.history + 1) + (char3 == "A" and -1 or 1)

					if cutie.input.cursor > #cutie.input.history then
						cutie.input.cursor = #cutie.input.history + 1
					end

					if cutie.input.cursor < 1 then
						cutie.input.cursor = 1
					end

					cutie.input.buffer = cutie.input.history[cutie.input.cursor] or ""
				end
			end
		elseif char == string.char(127) then
			cutie.input.buffer = cutie.input.buffer:sub(1, #cutie.input.buffer - 1)
		else
			cutie.input.buffer = cutie.input.buffer .. char
		end
	end
end

-- rendering

function cutie.clear_screen()
	cutie.render_escape("2J")
end

function cutie.empty_screen()
	cutie.move_cursor(1, 1)

	local size = cutie.get_terminal_size()
	local str = (string.rep(" ", size[1]) .. "\n"):rep(size[2])
	str = str:sub(1, #str - 1)

	cutie.render(str)
end

function cutie.render(text)
	cutie.buffer = cutie.buffer .. text
end

function cutie.render_escape(text)
	cutie.render(cutie.esc .. text)
end

function cutie.render_at(array, x, y)
	for i, line in ipairs(array) do
		cutie.move_cursor(x + 1, y + i)
		cutie.render(line)
	end
end

function cutie.get_dimensions(array)
	local width = 0

	for _, line in pairs(array) do
		width = math.max(width, #line)
	end

	return {width, #array}
end

function cutie.flush_buffer()
	io.write(cutie.buffer)
	io.stdout:flush()
	cutie.buffer = ""
end

-- terminal size

function cutie.handle_resize()
	local pf = io.popen("echo -ne \"cols\\nlines\" | tput -S", "r")
	local size = pf:read("*all"):split("\n")
	pf:close()
	cutie.terminal_size = size
end

function cutie.get_terminal_size()
	return cutie.terminal_size
end

return cutie
