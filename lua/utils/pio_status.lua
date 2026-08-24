-- lua/utils/pio_status.lua
-- Statusline badge:
--   • "PIO(<environment>)" inside PlatformIO projects
--   • "Arduino" for loose .ino files outside PIO
--   • "" otherwise

local PioStatus = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Utility helpers
-- ─────────────────────────────────────────────────────────────────────────────

local function get_buffer_directory(buffer_number)
	local buffer_full_path = vim.api.nvim_buf_get_name(buffer_number)
	if buffer_full_path == "" then
		return vim.uv.cwd()
	end
	return vim.fs.dirname(buffer_full_path)
end

local function find_upwards(start_directory, target_name, options)
	local search_options = options or {}
	search_options.path = start_directory
	search_options.upward = true
	return vim.fs.find(target_name, search_options)[1]
end

local function read_entire_file(file_path)
	if not file_path then
		return nil
	end
	local file_handle = io.open(file_path, "r")
	if not file_handle then
		return nil
	end
	local file_contents = file_handle:read("*a")
	file_handle:close()
	return file_contents
end

local function list_immediate_subdirectories(parent_directory)
	local subdirectories = {}

	local scan_root_directory = parent_directory or ""
	local handle_or_iterator, legacy_dir_handle = vim.uv.fs_scandir(scan_root_directory)
	if not handle_or_iterator then
		return subdirectories
	end

	if type(handle_or_iterator) == "userdata" then
		local scandir_handle = handle_or_iterator

		while true do
			local entry_name, entry_type = vim.uv.fs_scandir_next(scandir_handle)

			if not entry_name then
				break
			end
			if entry_type == "directory" then
				subdirectories[#subdirectories + 1] = entry_name
			end
		end
		return subdirectories
	end

	local iterator_function = handle_or_iterator
	local dir_handle = legacy_dir_handle

	while true do
		local entry_name, entry_type = iterator_function(dir_handle)

		if not entry_name then
			break
		end
		if entry_type == "directory" then
			subdirectories[#subdirectories + 1] = entry_name
		end
	end

	return subdirectories
end

local function split_csv_like(input_string)
	local tokens = {}
	for token in input_string:gmatch("([^,%s]+)") do
		table.insert(tokens, token)
	end
	return tokens
end

local function first_environment_from_ini(ini_text)
	if not ini_text then
		return nil
	end
	return ini_text:match("%[env:([%w%._%-%/]+)%]")
end

local function default_environments_from_ini(ini_text)
	if not ini_text then
		return nil
	end
	local platformio_section = ini_text:match("%[platformio%](.-)%[") or ini_text:match("%[platformio%](.+)$")
	if not platformio_section then
		return nil
	end
	local default_envs_line = platformio_section:match("[^\r\n]*default_envs%s*=%s*([^\r\n]+)")
	if not default_envs_line then
		return nil
	end
	return split_csv_like(default_envs_line)
end

-- Decide which env name to display:
-- 1) If exactly one ".pio/build/<env>" exists → use it (last-built env)
-- 2) Else, use the first from [platformio] default_envs
-- 3) Else, use the first "[env:NAME]" section
local function choose_display_environment(project_root_directory, ini_text)
	local build_environment_directories = list_immediate_subdirectories(project_root_directory .. "/.pio/build")
	if #build_environment_directories == 1 then
		return build_environment_directories[1]
	end

	local default_environment_list = default_environments_from_ini(ini_text)
	if default_environment_list and #default_environment_list > 0 then
		return (default_environment_list[1]:gsub("^%s+", ""):gsub("%s+$", ""))
	end

	return first_environment_from_ini(ini_text)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────────

function PioStatus.detect(buffer_number)
	local current_buffer = buffer_number or vim.api.nvim_get_current_buf()
	local start_directory = get_buffer_directory(current_buffer)

	-- PlatformIO?
	local platformio_ini_path = find_upwards(start_directory, "platformio.ini")
	if platformio_ini_path then
		local project_root_directory = vim.fs.dirname(platformio_ini_path)
		local ini_text = read_entire_file(platformio_ini_path)
		local environment_name = choose_display_environment(project_root_directory, ini_text)
		return { kind = "PIO", env = environment_name }
	end

	-- Arduino (plain .ino outside PlatformIO)?
	local buffer_filetype = vim.bo[current_buffer].filetype
	local buffer_extension = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(current_buffer), ":e")
	if buffer_filetype == "arduino" or buffer_extension == "ino" then
		return { kind = "Arduino" }
	end

	return { kind = nil }
end

function PioStatus.badge()
	local detected = PioStatus.detect()
	if not detected or not detected.kind then
		return ""
	end
	if detected.kind == "PIO" then
		return detected.env and ("PIO(" .. detected.env .. ")") or "PIO"
	elseif detected.kind == "Arduino" then
		return "Arduino"
	end
	return ""
end

function PioStatus.setup()
	local refresh_group = vim.api.nvim_create_augroup("PioStatuslineRefresh", { clear = true })

	vim.api.nvim_create_autocmd({ "BufEnter", "DirChanged" }, {
		group = refresh_group,
		callback = function()
			pcall(require, "lualine")
			pcall(require("lualine").refresh)
		end,
	})

	vim.api.nvim_create_autocmd("BufWritePost", {
		group = refresh_group,
		pattern = "platformio.ini",
		callback = function()
			pcall(require("lualine").refresh)
		end,
	})
end

return PioStatus
