local type, setmetatable, setfenv, unpack, next, intersection, union, pcall, _G = type, setmetatable, setfenv, unpack, next, bit.band, bit.bor, pcall, getfenv(0)
local error, import_error, declaration_error, collision_error, mutability_error
local pass, start_declaration, advance_declaration, env_mt, interface_mt, metadata_mt, property_mt

local PRIVATE, PUBLIC, MUTABLE, PROPERTY = 0, 1, 2, 4
local INDEX, NEWINDEX, CALL = 1, 2, 4
local _state = {}

function error(message, ...)
	return _G.error(format(message or '', unpack(arg))..'\n'..debugstack(), 0)
end
import_error = function() error 'Invalid imports.' end
declaration_error = function() error 'Invalid declaration.' end
collision_error = function(key) error('Field "%s" already exists.', key) end
mutability_error = function(key) error('Field "%s" is immutable.', key) end

pass = function() end

do
	local function unpack_property_value(t)
		local get, set; get, set, t.get, t.set = t.get, t.set, nil, nil
		if next(t) or get ~= nil and type(get) ~= 'function' or set ~= nil and type(set) ~= 'function' then error() end
		return get, set
	end
	local function declare(state, modifiers, key, value)
		if intersection(MUTABLE, modifiers) * intersection(PUBLIC+PROPERTY, modifiers) ~= 0 then declaration_error() end
		local metadata = state.metadata
		metadata[key] = metadata[key] and collision_error(key) or modifiers
		if intersection(PROPERTY, modifiers) == 0 then
			state.data[key] = value
		else
			local success, getter, setter = pcall(unpack_property_value, value)
			if success or declaration_error() then
				state.getters[key], state.setters[key] = getter, setter
			end
		end
	end

	do
		local MODIFIER = {private=PRIVATE, public=PUBLIC, mutable=MUTABLE, property=PROPERTY}
		local state, modifiers, property
		local function intercept(_, key, value)
			if type == INDEX and (not property or declaration_error()) then
				local modifier = MODIFIER[key]
				if not modifier then modifier, property = PROPERTY, key end
				modifiers = union(modifiers, modifier)
				return true
			elseif type == NEWINDEX then
				if property then key, value = property, {[key]=value} end
				declare(state, union(modifiers, state.modifiers), key, value)
				advance_declaration = pass
				return true
			elseif type == CALL then
				if property then declare(state, union(modifiers, state.modifiers), property, value) else state.modifiers = modifiers end
				advance_declaration = pass
				return true
			end
		end
		function start_declaration(state, modifier)
			if advance_declaration ~= pass then declaration_error() end
			advance_declaration, state, modifiers, property = intercept, state, modifier, nil
		end
	end

	env_mt = {__metatable=false}
	function env_mt:__index(key, state) state=_state[self]
		if advance_declaration(INDEX, key) then return self end
		if intersection(PROPERTY, state.metadata[key] or 0) ~= 0 then
			return state.getters[key]()
		else
			local value = state.data[key]
			if value ~= nil then return value else return _G[key] end
		end
	end
	function env_mt:__newindex(key, value, state) state=_state[self]
		if advance_declaration(NEWINDEX, key, value) then return end
		local modifiers = state.metadata[key]
		if modifiers then
			if intersection(PROPERTY, modifiers) ~= 0 then
				state.setters[key](value)
			elseif intersection(MUTABLE, modifiers) ~= 0 or mutability_error(key) then
				state.data[key] = value
			end
		else
			declare(state, state.modifiers, key, value)
		end
	end
	function env_mt:__call(key, ...)
		advance_declaration(CALL, key, arg)
	end
end

interface_mt = {__metatable=false}
function interface_mt:__index(key, state) state=_state[self]
	local masked = intersection(PUBLIC+PROPERTY, state.metadata[key] or 0)
	if masked == PUBLIC+PROPERTY then
		return state.getters[key]()
	elseif masked == PUBLIC then
		return state.data[key]
	end
end
function interface_mt:__newindex(key, value, state) state=_state[self]
	if intersection(PUBLIC+PROPERTY, state.metadata[key] or 0) == PUBLIC+PROPERTY then
		return state.setters[key](value)
--	elseif masked == PUBLIC and type(state.data[key]) == 'function' then
--		return state.data[key](value)
	end
end

property_mt = {__index=function() return pass end}

local function module(...)
	local state, env, interface
	env, interface = setmetatable({}, env_mt), setmetatable({}, interface_mt)
	state = {
		metadata = {_=PROPERTY, error=PRIVATE, pass=PRIVATE, _G=PRIVATE, M=PRIVATE, I=PRIVATE, private=PROPERTY, public=PROPERTY, mutable=PROPERTY, property=PROPERTY},
		fields = {_G=_G, M=env, I=interface, error=error},
		getters = setmetatable({
			private = function() start_declaration(PRIVATE, state); return env end,
			public = function() start_declaration(PUBLIC, state); return env end,
			mutable = function() start_declaration(MUTABLE, state); return env end,
			property = function() start_declaration(PROPERTY, state); return env end,
		}, property_mt),
		setters = setmetatable({}, property_mt),
	}
	for i=1,arg.n do
		local module = state[arg[i] or import_error()] or import_error()
		for k, v in module.metadata do
			if intersection(PUBLIC, v) ~= 0 and (not state.metadata[k] or import_error()) then
				state.metadata[k], state.data[k], state.getters[k], state.setters[k] = v, module.data[k], module.getters[k], module.setters[k]
			end
		end
	end
	state[env], state[interface] = state, state
	setfenv(2, env)
end