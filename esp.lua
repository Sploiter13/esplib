--!native
--!optimize 2

---- environment ----
local assert, typeof, tonumber = assert, typeof, tonumber
local pcall, pairs, ipairs = pcall, pairs, ipairs
local task_wait, task_spawn = task.wait, task.spawn
local table_find, table_insert, table_remove = table.find, table.insert, table.remove
local string_format, string_lower = string.format, string.lower
local math_floor, math_sqrt = math.floor, math.sqrt
local vector_magnitude, vector_create = vector.magnitude, vector.create

local game = game
local workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

---- constants ----
local DEFAULT_CONFIG = {
	enabled = true,
	name_esp = true,
	distance_esp = true,
	box_esp = false,
	health_bar = false,
	tracers = false,
	
	-- Colors
	name_color = Color3.new(1, 1, 1),
	box_color = Color3.new(1, 0, 0),
	tracer_color = Color3.new(0, 1, 0),
	health_bar_color = Color3.new(0, 1, 0),
	
	-- Settings
	max_distance = 1000,
	font_size = 14,
	font = "Tamzen",
	box_thickness = 2,
	tracer_thickness = 1,
	
	-- Transparency
	name_opacity = 1,
	box_opacity = 0.8,
	tracer_opacity = 0.6,
	
	-- Distance fade
	fade_enabled = true,
	fade_start = 500,
	fade_end = 1000,
	
	-- Team check (if applicable)
	ignore_team = false,
}

---- variables ----
local tracked_objects = {}
local active_paths = {}
local include_filter = nil
local exclude_filter = {}
local camera = nil
local render_connection = nil
local update_connection = nil
local config = {}

---- functions ----
local function deep_copy(tbl: {[any]: any}): {[any]: any}
	local copy = {}
	for k, v in pairs(tbl) do
		if typeof(v) == "table" then
			copy[k] = deep_copy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

local function calculate_distance(pos1: vector, pos2: vector): number
	local delta = pos1 - pos2
	return math_sqrt(delta.X * delta.X + delta.Y * delta.Y + delta.Z * delta.Z)
end

local function calculate_fade_opacity(distance: number): number
	if not config.fade_enabled then
		return 1
	end
	
	if distance <= config.fade_start then
		return 1
	elseif distance >= config.fade_end then
		return 0
	else
		local range = config.fade_end - config.fade_start
		local fade_distance = distance - config.fade_start
		return 1 - (fade_distance / range)
	end
end

local function should_track_object(obj: Instance): boolean
	assert(typeof(obj) == "Instance", "invalid argument #1 (Instance expected)")
	
	local obj_name = obj.Name
	
	-- Check include filter (whitelist mode)
	if include_filter then
		local found = false
		for _, name in ipairs(include_filter) do
			if string_lower(obj_name):find(string_lower(name), 1, true) then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end
	
	-- Check exclude filter (blacklist mode)
	for _, name in ipairs(exclude_filter) do
		if string_lower(obj_name):find(string_lower(name), 1, true) then
			return false
		end
	end
	
	return true
end

local function get_object_position(obj: Instance): vector?
	-- Try different position methods
	local success, result = pcall(function()
		if obj.ClassName == "Model" then
			local primary = obj.PrimaryPart
			if primary then
				return primary.Position
			end
			
			-- Try common part names
			local parts = {"HumanoidRootPart", "Head", "Torso", "UpperTorso"}
			for _, part_name in ipairs(parts) do
				local part = obj:FindFirstChild(part_name)
				if part and part.ClassName:find("Part") then
					return part.Position
				end
			end
			
			-- Fallback: first BasePart
			for _, child in ipairs(obj:GetChildren()) do
				if child.ClassName:find("Part") then
					return child.Position
				end
			end
		elseif obj.ClassName:find("Part") then
			return obj.Position
		end
		return nil
	end)
	
	if success and result then
		return result
	end
	return nil
end

local function get_object_health(obj: Instance): (number?, number?)
	if obj.ClassName ~= "Model" then
		return nil, nil
	end
	
	local success, result = pcall(function()
		local humanoid = obj:FindFirstChildOfClass("Humanoid")
		if humanoid then
			return humanoid.Health, humanoid.MaxHealth
		end
		return nil, nil
	end)
	
	if success then
		return result
	end
	return nil, nil
end

local function scan_path(path: Instance)
	assert(typeof(path) == "Instance", "invalid path (Instance expected)")
	
	local success, children = pcall(function()
		return path:GetChildren()
	end)
	
	if not success then
		warn(`failed to scan path: {path.Name}`)
		return
	end
	
	for _, obj in ipairs(children) do
		if should_track_object(obj) then
			local obj_id = obj.Data or tostring(obj)
			
			if not tracked_objects[obj_id] then
				local position = get_object_position(obj)
				if position then
					tracked_objects[obj_id] = {
						object = obj,
						name = obj.Name,
						position = position,
						last_seen = os.clock(),
					}
				end
			else
				-- Update existing
				tracked_objects[obj_id].last_seen = os.clock()
			end
		end
	end
end

local function cleanup_stale_objects()
	local current_time = os.clock()
	local stale_threshold = 2 -- seconds
	
	for obj_id, data in pairs(tracked_objects) do
		if current_time - data.last_seen > stale_threshold then
			tracked_objects[obj_id] = nil
		elseif not data.object or not data.object.Parent then
			tracked_objects[obj_id] = nil
		end
	end
end

local function update_loop()
	while config.enabled do
		-- Update camera reference
		local success = pcall(function()
			camera = workspace.CurrentCamera
		end)
		
		if not success then
			camera = nil
		end
		
		-- Scan all active paths
		for _, path in ipairs(active_paths) do
			if path and path.Parent then
				scan_path(path)
			end
		end
		
		-- Cleanup stale objects
		cleanup_stale_objects()
		
		task_wait(0.5) -- Update twice per second
	end
end

local function render_loop()
	if not camera or not config.enabled then
		return
	end
	
	local cam_pos = camera.Position
	
	for _, data in pairs(tracked_objects) do
		local obj = data.object
		if not obj or not obj.Parent then
			continue
		end
		
		-- Update position
		local pos = get_object_position(obj)
		if not pos then
			continue
		end
		data.position = pos
		
		-- Calculate distance
		local distance = calculate_distance(pos, cam_pos)
		if distance > config.max_distance then
			continue
		end
		
		-- World to screen
		local screen, visible = camera:WorldToScreenPoint(pos)
		if not visible then
			continue
		end
		
		local screen_pos = vector_create(screen.X, screen.Y, 0)
		local fade_opacity = calculate_fade_opacity(distance)
		
		if fade_opacity <= 0 then
			continue
		end
		
		local y_offset = 0
		
		-- Name ESP
		if config.name_esp then
			local name_text = data.name
			if config.distance_esp then
				name_text = `{name_text} [{math_floor(distance)}m]`
			end
			
			DrawingImmediate.OutlinedText(
				screen_pos - vector_create(0, y_offset, 0),
				config.font_size,
				config.name_color,
				config.name_opacity * fade_opacity,
				name_text,
				true,
				config.font
			)
			y_offset = y_offset + config.font_size + 2
		end
		
		-- Health bar
		if config.health_bar then
			local health, max_health = get_object_health(obj)
			if health and max_health and max_health > 0 then
				local bar_width = 100
				local bar_height = 4
				local health_percent = health / max_health
				
				local bar_pos = screen_pos - vector_create(bar_width / 2, y_offset, 0)
				
				-- Background
				DrawingImmediate.FilledRectangle(
					bar_pos,
					vector_create(bar_width, bar_height, 0),
					Color3.new(0.2, 0.2, 0.2),
					0.8 * fade_opacity
				)
				
				-- Health bar
				DrawingImmediate.FilledRectangle(
					bar_pos,
					vector_create(bar_width * health_percent, bar_height, 0),
					config.health_bar_color,
					0.9 * fade_opacity
				)
				
				y_offset = y_offset + bar_height + 4
			end
		end
		
		-- Box ESP
		if config.box_esp then
			local box_size = 2000 / distance
			box_size = math.clamp(box_size, 20, 100)
			
			DrawingImmediate.Rectangle(
				screen_pos - vector_create(box_size / 2, box_size, 0),
				vector_create(box_size, box_size * 2, 0),
				config.box_color,
				config.box_opacity * fade_opacity,
				config.box_thickness
			)
		end
		
		-- Tracers
		if config.tracers then
			local screen_center = camera.ViewportSize / 2
			local tracer_start = vector_create(screen_center.X, screen_center.Y, 0)
			
			DrawingImmediate.Line(
				tracer_start,
				screen_pos,
				config.tracer_color,
				config.tracer_opacity * fade_opacity,
				1,
				config.tracer_thickness
			)
		end
	end
end

---- module ----
local ESP = {}

function ESP.new(settings: {[string]: any}?): typeof(ESP)
	settings = settings or {}
	
	config = deep_copy(DEFAULT_CONFIG)
	
	-- Apply custom settings
	for key, value in pairs(settings) do
		if config[key] ~= nil then
			config[key] = value
		end
	end
	
	return ESP
end

function ESP.add_path(path: Instance | string)
	local actual_path: Instance? = nil
	
	if typeof(path) == "string" then
		-- Try to find the path
		local parts = string.split(path, ".")
		local current = workspace
		
		for _, part in ipairs(parts) do
			local success, result = pcall(function()
				return current:FindFirstChild(part)
			end)
			
			if success and result then
				current = result
			else
				warn(`failed to find path: {path}`)
				return false
			end
		end
		actual_path = current
	elseif typeof(path) == "Instance" then
		actual_path = path
	else
		error(`invalid path type: {typeof(path)}`)
	end
	
	assert(actual_path, `path not found: {path}`)
	
	-- Check if already added
	for _, existing in ipairs(active_paths) do
		if existing == actual_path then
			return true
		end
	end
	
	table_insert(active_paths, actual_path)
	return true
end

function ESP.remove_path(path: Instance | string)
	for i, existing in ipairs(active_paths) do
		if existing == path or existing.Name == path then
			table_remove(active_paths, i)
			return true
		end
	end
	return false
end

function ESP.set_include(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	include_filter = names
	exclude_filter = {}
end

function ESP.set_exclude(names: {string})
	assert(typeof(names) == "table", "invalid argument #1 (table expected)")
	exclude_filter = names
	include_filter = nil
end

function ESP.clear_filters()
	include_filter = nil
	exclude_filter = {}
end

function ESP.set_config(key: string, value: any)
	assert(config[key] ~= nil, `invalid config key: {key}`)
	config[key] = value
end

function ESP.get_config(key: string): any
	return config[key]
end

function ESP.start()
	if render_connection or update_connection then
		warn("ESP already running")
		return
	end
	
	config.enabled = true
	
	-- Start render loop
	render_connection = RunService.Render:Connect(render_loop)
	
	-- Start update loop
	task_spawn(update_loop)
end

function ESP.stop()
	config.enabled = false
	
	if render_connection then
		render_connection:Disconnect()
		render_connection = nil
	end
	
	-- Clear tracked objects
	tracked_objects = {}
end

function ESP.get_tracked_count(): number
	local count = 0
	for _ in pairs(tracked_objects) do
		count = count + 1
	end
	return count
end

---- exports ----
return ESP
