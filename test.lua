--!native
--!optimize 2

---- environment ----
local assert, typeof = assert, typeof
local pcall, pairs = pcall, pairs
local table_insert, table_remove, table_create, table_clear = table.insert, table.remove, table.create, table.clear
local string_format, string_lower, string_split = string.format, string.lower, string.split
local math_floor, math_sqrt, math_min, math_max = math.floor, math.sqrt, math.min, math.max
local math_huge = math.huge
local vector_create = vector.create
local os_clock = os.clock
local task_spawn = task.spawn
local task_wait = task.wait

local game = game
local workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local function deep_copy(tbl: {[any]: any}): {[any]: any}
	local copy = table_create(10)
	for k, v in pairs(tbl) do
		copy[k] = typeof(v) == "table" and deep_copy(v) or v
	end
	return copy
end

---- constants ----
local DEFAULT_CONFIG = {
	enabled = false,
	profiling = false,
	Dynamic = false,
	
	name_esp = true,
	distance_esp = true,
	box_esp = true,
	health_bar = false,
	tracers = false,
	
	exclude_players = false,
	auto_exclude_localplayer = true,
	
	name_color = Color3.new(1, 1, 1),
	box_color = Color3.new(1, 0, 0),
	tracer_color = Color3.new(0, 1, 0),
	health_bar_color = Color3.new(0, 1, 0),
	
	max_distance = 1000,
	max_render_objects = 100,
	font_size = 14,
	font = "Tamzen",
	box_thickness = 2,
	tracer_thickness = 1,
	
	name_opacity = 1,
	box_opacity = 0.8,
	tracer_opacity = 0.6,
	
	fade_enabled = true,
	fade_start = 500,
	fade_end = 1000,
}

local PART_NAMES = {"HumanoidRootPart", "Head", "UpperTorso", "Torso"}
local SCAN_INTERVAL = 1
local BOX_CACHE_TIME = 5
local BOX_DISTANCE_LIMIT = 300
local LOD_DISTANCE_CLOSE = 200
local LOD_DISTANCE_MEDIUM = 500

---- variables ----
local tracked_objects = {}
local dynamic_entries = {}
local box_cache = {}
local render_data = table_create(100)

local active_paths = table_create(10)
local include_filter = nil
local exclude_filter = table_create(10)

local camera = nil
local camera_position = nil
local viewport_size = nil
local screen_center = nil

local local_player = nil
local local_character = nil

local config = {}
local frame_count = 0
local fade_range_inv = 1

local running = false

---- profiling ----
local profile_times = {
	scan = 0,
	render = 0,
}

local profile_counters = {
	tracked = 0,
	rendered = 0,
}

---- functions ----
local function calculate_fade_opacity(distance: number): number
	local fade_enabled = config.fade_enabled
	local fade_start = config.fade_start
	local fade_end = config.fade_end
	
	if fade_enabled == nil or fade_start == nil or fade_end == nil then
		return 1
	end
	
	if not fade_enabled or distance <= fade_start then
		return 1
	elseif distance >= fade_end then
		return 0
	end
	return 1 - ((distance - config.fade_start) * fade_range_inv)
end

local function update_local_player()
	pcall(function()
		local_player = Players.LocalPlayer
		local_character = local_player and local_player.Character
	end)
end

local function is_player_character(obj: Instance): boolean
	if not obj or obj.ClassName ~= "Model" then
		return false
	end
	
	local success, result = pcall(function()
		for _, player in pairs(Players:GetPlayers()) do
			if player.Character == obj then
				return true
			end
		end
		return false
	end)
	
	return success and result
end

local function should_exclude_object(obj: Instance): boolean
	if config.auto_exclude_localplayer and obj == local_character then
		return true
	end
	
	if config.exclude_players and is_player_character(obj) then
		return true
	end
	
	return false
end

local function should_track_object(obj: Instance): boolean
	if should_exclude_object(obj) then
		return false
	end
	
	local success, obj_name = pcall(function()
		return string_lower(obj.Name)
	end)
	
	if not success then
		return false
	end
	
	if include_filter then
		local found = false
		for i = 1, #include_filter do
			if obj_name:find(string_lower(include_filter[i]), 1, true) then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end
	
	for i = 1, #exclude_filter do
		if obj_name:find(string_lower(exclude_filter[i]), 1, true) then
			return false
		end
	end
	
	return true
end

local function get_object_position(obj: Instance): vector?
	local success, result = pcall(function()
		if not obj or not obj.Parent then return nil end
		
		if obj.ClassName == "Tool" then
			local handle = obj:FindFirstChild("Handle")
			if handle and handle.Parent and handle.ClassName:find("Part") or handle.ClassName:find("Union") then
				return handle.Position
			end
			
			local children = obj:GetChildren()
			for i = 1, #children do
				local child = children[i]
				if child.Parent and child.ClassName:find("Part") then
					return child.Position
				end
			end
		end
		
		if obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary and primary.Parent then
				return primary.Position
			end
			
			for i = 1, #PART_NAMES do
				local part = obj:FindFirstChild(PART_NAMES[i])
				if part and part.Parent and part.ClassName:find("Part") then
					return part.Position
				end
			end
			
			local children = obj:GetChildren()
			for i = 1, #children do
				local child = children[i]
				if child.Parent and child.ClassName:find("Part") then
					return child.Position
				end
			end
		elseif obj.ClassName:find("Part") then
			return obj.Position
		end
		
		return nil
	end)
	
	return success and result or nil
end


local function get_simple_box_corners(obj: Instance): {vector}?
	local success, corners = pcall(function()
		if not obj or not obj.Parent then return nil end
		
		local pos, size
		
		if obj.ClassName == "Tool" then
			local handle = obj:FindFirstChild("Handle")
			if handle and handle.Parent and handle.ClassName:find("Part") then
				pos = handle.Position
				size = handle.Size
			else
				local children = obj:GetChildren()
				for i = 1, #children do
					local child = children[i]
					if child.Parent and child.ClassName:find("Part") then
						pos = child.Position
						size = child.Size
						break
					end
				end
			end
		elseif obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary and primary.Parent then
				pos = primary.Position
				size = primary.Size
			else
				for i = 1, #PART_NAMES do
					local part = obj:FindFirstChild(PART_NAMES[i])
					if part and part.Parent and part.ClassName:find("Part") then
						pos = part.Position
						size = part.Size
						break
					end
				end
			end
		elseif obj.ClassName:find("Part") then
			pos = obj.Position
			size = obj.Size
		end
		
		if not pos or not size then return nil end
		
		local hsx, hsy, hsz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
		local px, py, pz = pos.X, pos.Y, pos.Z
		
		return {
			vector_create(px - hsx, py - hsy, pz - hsz),
			vector_create(px + hsx, py - hsy, pz - hsz),
			vector_create(px + hsx, py - hsy, pz + hsz),
			vector_create(px - hsx, py - hsy, pz + hsz),
			vector_create(px - hsx, py + hsy, pz - hsz),
			vector_create(px + hsx, py + hsy, pz - hsz),
			vector_create(px + hsx, py + hsy, pz + hsz),
			vector_create(px - hsx, py + hsy, pz + hsz),
		}
	end)
	
	return success and corners or nil
end

local function project_corners_to_screen(corners: {vector}, cam: Instance): (vector?, vector?)
	local min_x, min_y = math_huge, math_huge
	local max_x, max_y = -math_huge, -math_huge
	local any_visible = false
	
	pcall(function()
		for i = 1, 8 do
			local screen_pos, visible = cam:WorldToScreenPoint(corners[i])
			if visible then
				any_visible = true
				local sx, sy = screen_pos.X, screen_pos.Y
				min_x = math_min(min_x, sx)
				min_y = math_min(min_y, sy)
				max_x = math_max(max_x, sx)
				max_y = math_max(max_y, sy)
			end
		end
	end)
	
	if not any_visible then
		return nil, nil
	end
	
	return vector_create(min_x, min_y, 0), vector_create(max_x, max_y, 0)
end

local function scan_paths()
	local prof_start = config.profiling and os_clock()
	
	table_clear(tracked_objects)
	
	for path_idx = 1, #active_paths do
		pcall(function()
			local path = active_paths[path_idx]
			if not path or not path.Parent then return end
			
			local children = path:GetChildren()
			
			for i = 1, #children do
				local obj = children[i]
				
				if should_track_object(obj) then
					local position = get_object_position(obj)
					
					if position then
						local obj_name
						pcall(function()
							obj_name = obj.Name
						end)
						
						local obj_id = tostring(obj)
						tracked_objects[obj_id] = {
							object = obj,
							name = obj_name or "Unknown",
							position = position,
						}
					end
				end
			end
		end)
	end
	
	if config.profiling then
		profile_times.scan = os_clock() - prof_start
		profile_counters.tracked = 0
		for _ in pairs(tracked_objects) do
			profile_counters.tracked = profile_counters.tracked + 1
		end
	end
end

local function destroy_dynamic_entry(obj_id: string)
	local entry = dynamic_entries[obj_id]
	if not entry then return end
	
	if entry.cluster then
		pcall(function()
			entry.cluster:Destroy()
		end)
	end
	
	if entry.point then
		pcall(function()
			entry.point:Destroy()
		end)
	end
	
	if entry.drawings then
		for i = 1, #entry.drawings do
			pcall(function()
				local item = entry.drawings[i]
				if item and item.obj then
					item.obj:Remove()
				end
			end)
		end
	end
	
	dynamic_entries[obj_id] = nil
end

local function clear_dynamic_entries()
	for obj_id in pairs(dynamic_entries) do
		destroy_dynamic_entry(obj_id)
	end
end

local function make_dynamic_point(obj: Instance): any
	if obj.ClassName == "Model" then
		if not PointModel then return nil end
		return PointModel.new(obj)
	end
	
	if obj.ClassName == "Tool" then
		local handle = obj:FindFirstChild("Handle")
		if handle and handle.Parent and handle.ClassName:find("Part") then
			return PointInstance.new(handle)
		end
	end
	
	if obj.ClassName:find("Part") then
		return PointInstance.new(obj)
	end
	
	return nil
end

local function create_dynamic_entry(obj_id: string, obj: Instance, name: string)
	local point = make_dynamic_point(obj)
	if not point then return nil end
	
	local drawings = table_create(2)
	local attach_config = {}
	
	if config.box_esp then
		local box = Drawing.new("Square")
		box.Visible = true
		box.Filled = false
		box.Color = config.box_color
		box.Thickness = config.box_thickness
		box.Opacity = config.box_opacity
		
		drawings[#drawings + 1] = { obj = box, kind = "Square" }
		attach_config[box] = {
			Link = point,
			Size = UDim2.fromScale(1, 1),
			AnchorPoint = Vector2.new(0.5, 0.5),
		}
	end
	
	if config.name_esp then
		local text = Drawing.new("Text")
		text.Visible = true
		text.Color = config.name_color
		text.Size = config.font_size
		text.Center = true
		text.Outline = true
		text.Opacity = config.name_opacity
		
		local font_value = config.font
		if typeof(font_value) ~= "number" then
			font_value = 2
		end
		text.Font = font_value
		
		drawings[#drawings + 1] = { obj = text, kind = "Text" }
		attach_config[text] = {
			Link = point,
			Size = UDim2.fromOffset(0, 0),
			AnchorPoint = Vector2.new(0.5, 1),
		}
	end
	
	if #drawings == 0 then
		pcall(function()
			point:Destroy()
		end)
		return nil
	end
	
	local cluster = Drawing.attach(attach_config)
	
	return {
		point = point,
		cluster = cluster,
		drawings = drawings,
		object = obj,
		name = name,
	}
end

local function update_dynamic_entry(entry, distance: number, fade: number, name_text: string?)
	for i = 1, #entry.drawings do
		local item = entry.drawings[i]
		local d = item and item.obj
		local kind = item and item.kind
		if not d or not kind then
			continue
		end
		
		if kind == "Square" then
			d.Visible = config.box_esp and fade > 0
			d.Color = config.box_color
			d.Thickness = config.box_thickness
			d.Opacity = config.box_opacity * fade
		elseif kind == "Text" then
			d.Visible = config.name_esp and name_text ~= nil and fade > 0
			if name_text then
				d.Text = name_text
			end
			d.Color = config.name_color
			d.Size = config.font_size
			d.Opacity = config.name_opacity * fade
		end
	end
end

local function sync_dynamic_entries()
	local cam = workspace.CurrentCamera
	local cam_pos = cam and cam.Position
	if not cam_pos then return end
	
	local seen = {}
	
	for obj_id, data in pairs(tracked_objects) do
		seen[obj_id] = true
		
		local obj = data.object
		if not obj or not obj.Parent then
			destroy_dynamic_entry(obj_id)
		else
			local entry = dynamic_entries[obj_id]
			if not entry then
				entry = create_dynamic_entry(obj_id, obj, data.name)
				if entry then
					dynamic_entries[obj_id] = entry
				else
					continue
				end
			end
			
			local pos = get_object_position(obj)
			if not pos then
				update_dynamic_entry(entry, 0, 0, nil)
				continue
			end
			
			local dx = pos.X - cam_pos.X
			local dy = pos.Y - cam_pos.Y
			local dz = pos.Z - cam_pos.Z
			local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
			
			if distance > config.max_distance then
				update_dynamic_entry(entry, distance, 0, nil)
				continue
			end
			
			local fade = calculate_fade_opacity(distance)
			if fade <= 0 then
				update_dynamic_entry(entry, distance, 0, nil)
				continue
			end
			
			local name_text = nil
			if config.name_esp then
				local dist_floored = math_floor(distance)
				if config.distance_esp then
					name_text = data.name .. " [" .. dist_floored .. "m]"
				else
					name_text = data.name
				end
			end
			
			update_dynamic_entry(entry, distance, fade, name_text)
		end
	end
	
	for obj_id in pairs(dynamic_entries) do
		if not seen[obj_id] then
			destroy_dynamic_entry(obj_id)
		end
	end
end

---- scan loop ----
local function scan_loop()
	while running do
		if config.enabled then
			scan_paths()
			if config.Dynamic then
				sync_dynamic_entries()
			end
		end
		task_wait(SCAN_INTERVAL)
	end
end

---- box cache update loop ----
local function box_cache_loop()
	while running do
		if config.enabled and config.box_esp and not config.Dynamic then
			local current_time = os_clock()
			
			for obj_id, data in pairs(tracked_objects) do
				local cache_entry = box_cache[obj_id]
				
				if not cache_entry or (current_time - cache_entry.time) > BOX_CACHE_TIME then
					pcall(function()
						local obj = data.object
						if obj and obj.Parent then
							local corners = get_simple_box_corners(obj)
							if corners then
								box_cache[obj_id] = {
									corners = corners,
									time = current_time,
								}
							end
						end
					end)
				end
				
				task_wait(0.01)
			end
		end
		task_wait(0.5)
	end
end

---- render loop ----
local function render_loop()
	RunService.Render:Connect(function()
		if not config.enabled then return end
		if config.Dynamic then return end
		
		local prof_start = config.profiling and os_clock()
		
		update_local_player()
		
		pcall(function()
			camera = workspace.CurrentCamera
			camera_position = camera and camera.Position
			viewport_size = camera and camera.ViewportSize
			screen_center = viewport_size and vector_create(viewport_size.X * 0.5, viewport_size.Y * 0.5, 0)
		end)
		
		if not camera or not camera_position or not viewport_size or not screen_center then
			return
		end
		
		table_clear(render_data)
		local render_count = 0
		
		for obj_id, data in pairs(tracked_objects) do
			if render_count >= config.max_render_objects then
				break
			end
			
			pcall(function()
				local obj = data.object
				if not obj or not obj.Parent then return end
				
				if should_exclude_object(obj) then return end
				
				local pos = get_object_position(obj)
				if not pos then return end
				
				local dx = pos.X - camera_position.X
				local dy = pos.Y - camera_position.Y
				local dz = pos.Z - camera_position.Z
				local distance = math_sqrt(dx * dx + dy * dy + dz * dz)
				
				if distance > config.max_distance then return end
				
				local screen, visible = camera:WorldToScreenPoint(pos)
				if not visible then return end
				
				local fade_opacity = calculate_fade_opacity(distance)
				if fade_opacity <= 0 then return end
				
				render_count = render_count + 1
				
				local rd = {
					screen_pos = vector_create(screen.X, screen.Y, 0),
					fade_opacity = fade_opacity,
					distance = distance,
					name = data.name,
				}
				
				local is_medium = distance < LOD_DISTANCE_MEDIUM
				
				if config.box_esp and distance < BOX_DISTANCE_LIMIT then
					local cache_entry = box_cache[obj_id]
					if cache_entry and cache_entry.corners then
						local box_min, box_max = project_corners_to_screen(cache_entry.corners, camera)
						
						if box_min and box_max then
							rd.box_min = box_min
							rd.box_size = box_max - box_min
						end
					end
				end
				
				if config.name_esp then
					local dist_floored = math_floor(distance)
					if config.distance_esp and is_medium then
						rd.name_text = data.name .. " [" .. dist_floored .. "m]"
					else
						rd.name_text = data.name
					end
				end
				
				rd.draw_tracer = config.tracers and is_medium
				
				render_data[render_count] = rd
			end)
		end
		
		for i = 1, render_count do
			local data = render_data[i]
			if not data then break end
			
			local fade = data.fade_opacity
			
			if config.box_esp and data.box_min then
				DrawingImmediate.Rectangle(
					data.box_min,
					data.box_size,
					config.box_color,
					config.box_opacity * fade,
					config.box_thickness
				)
			end
			
			if config.name_esp and data.name_text then
				DrawingImmediate.OutlinedText(
					data.screen_pos,
					config.font_size,
					config.name_color,
					config.name_opacity * fade,
					data.name_text,
					true,
					config.font
				)
			end
			
			if data.draw_tracer then
				DrawingImmediate.Line(
					screen_center,
					data.screen_pos,
					config.tracer_color,
					config.tracer_opacity * fade,
					1,
					config.tracer_thickness
				)
			end
		end
		
		if config.profiling then
			profile_times.render = os_clock() - prof_start
			profile_counters.rendered = render_count
			
			frame_count = frame_count + 1
			if frame_count % 60 == 0 then
				print(string_format("\n==== ESP Performance Report ===="))
				print(string_format("Scan:   %.4fms", profile_times.scan * 1000))
				print(string_format("Render: %.4fms", profile_times.render * 1000))
				print(string_format("Tracked:  %d", profile_counters.tracked))
				print(string_format("Rendered: %d", profile_counters.rendered))
				print(string_format("================================\n"))
			end
		end
	end)
end

---- module ----
local ESP = {}

function ESP.new(settings: {[string]: any}?): typeof(ESP)
	settings = settings or {}
	
	config = deep_copy(DEFAULT_CONFIG)
	
	for key, value in pairs(settings) do
		if config[key] ~= nil then
			config[key] = value
		end
	end
	
	local fade_range = config.fade_end - config.fade_start
	fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
	
	update_local_player()
	
	print(string_format("[ESP] Initialized - Profiling: %s", config.profiling and "ENABLED" or "DISABLED"))
	
	return ESP
end

function ESP.add_path(path: Instance | string): boolean
	local actual_path = nil
	
	if typeof(path) == "string" then
		local parts = string_split(path, ".")
		local current = workspace
		
		for i = 1, #parts do
			local success, result = pcall(function()
				return current:FindFirstChild(parts[i])
			end)
			
			if success and result then
				current = result
			else
				return false
			end
		end
		
		actual_path = current
	elseif typeof(path) == "Instance" then
		actual_path = path
	else
		return false
	end
	
	if not actual_path then
		return false
	end
	
	for i = 1, #active_paths do
		if active_paths[i] == actual_path then
			return true
		end
	end
	
	table_insert(active_paths, actual_path)
	print(string_format("[ESP] Added path: %s", tostring(actual_path)))
	return true
end

function ESP.remove_path(path: Instance | string): boolean
	for i = 1, #active_paths do
		local existing = active_paths[i]
		local match = false
		
		pcall(function()
			match = (existing == path) or (existing.Name == path)
		end)
		
		if match then
			table_remove(active_paths, i)
			return true
		end
	end
	
	return false
end

function ESP.set_include(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	include_filter = names
	table_clear(exclude_filter)
end

function ESP.set_exclude(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	table_clear(exclude_filter)
	
	for i = 1, #names do
		exclude_filter[i] = names[i]
	end
	
	include_filter = nil
end

function ESP.clear_filters()
	include_filter = nil
	table_clear(exclude_filter)
end

function ESP.set_config(key: string, value: any)
	config[key] = value
	
	if key == "fade_start" or key == "fade_end" then
		local fade_range = config.fade_end - config.fade_start
		fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
	end
	
	if key == "Dynamic" then
		if value then
			table_clear(render_data)
			table_clear(box_cache)
		else
			clear_dynamic_entries()
		end
	end
end

function ESP.get_config(key: string): any
	return config[key]
end

function ESP.enable_profiling(enabled: boolean)
	config.profiling = enabled
	print(string_format("[ESP] Profiling: %s", enabled and "ENABLED" or "DISABLED"))
end

function ESP.start()
	if running then
		print("[ESP] Already running")
		return
	end
	
	if not config.enabled and config.fade_start == nil then
		config = deep_copy(DEFAULT_CONFIG)
		local fade_range = config.fade_end - config.fade_start
		fade_range_inv = fade_range > 0 and (1 / fade_range) or 1
		update_local_player()
	end
	
	config.enabled = true
	running = true
	frame_count = 0
	
	task_spawn(scan_loop)
	task_spawn(box_cache_loop)
	render_loop()
	
	print("[ESP] Started")
end

function ESP.stop()
	running = false
	config.enabled = false
	table_clear(tracked_objects)
	table_clear(render_data)
	table_clear(box_cache)
	clear_dynamic_entries()
	print("[ESP] Stopped")
end

function ESP.get_tracked_count(): number
	local count = 0
	for _ in pairs(tracked_objects) do
		count = count + 1
	end
	return count
end

return ESP
