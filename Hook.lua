--!nolint DeprecatedApi

--[[
	Taking my methods 💖💖
	I love a paster and a skid, puts disgust in my face
]]

local Hook = {
	OriginalNamecall = nil,
	OriginalIndex = nil,
	PreviousFunctions = {},
	DefaultConfig = {
		FunctionPatches = true
	}
}

type table = {
	[any]: any
}

type MetaFunc = (Instance, ...any) -> ...any
type UnkFunc = (...any) -> ...any

--// Modules
local Modules
local Process
local Configuration
local Config
local Communication

local ExeENV = getfenv(1)

---------------------------------------------------------------------
--// INTERNAL API HELPERS (не публичные, не меняют структуру Hook)
---------------------------------------------------------------------

--// Безопасный вызов is_hook_thread (oth)
local function IsHookThread(): boolean
	if oth and oth.is_hook_thread then
		local ok, res = pcall(oth.is_hook_thread)
		if ok then return res end
	end
	return false
end

--// Универсальный хук функции. Для C-замыканий — oth, иначе hookfunction/closures.
--// Возвращает корневую (оригинальную) функцию.
local function SafeHookFunction(Func, Callback)
	--// oth — только для C-замыканий
	if oth and oth.hook and iscclosure(Func) then
		local ok = pcall(oth.hook, Func, Callback)
		if ok then
			return function(...)
				local root = (oth.get_root_callback and oth.get_root_callback(Func)) or Func
				return root(...)
			end
		end
	end

	--// closures (если есть)
	if closures and closures.hookfunction then
		local ok, old = pcall(closures.hookfunction, Func, Callback)
		if ok then return old end
	end

	--// legacy hookfunction
	if hookfunction then
		local ok, old = pcall(hookfunction, Func, Callback)
		if ok then return old end
	end

	error("No function hooking API available")
end

--// Универсальный хук метаметода: сначала hookmetamethod, потом rawmetatable
local function SafeHookMetaMethod(Object, Call, Callback)
	if hookmetamethod then
		local ok, old = pcall(hookmetamethod, Object, Call, Callback)
		if ok then return old end
	end
	return nil --// сигнал «используй fallback»
end

--// Чтение свойства с identity 8
local function IndexWithIdentity(Object, Key)
	local getId = getidentity or getthreadidentity
	local setId = setidentity or setthreadidentity
	if not getId or not setId then
		return Object[Key]
	end
	local identity = getId()
	setId(8)
	local returned = Object[Key]
	setId(identity)
	return returned
end

--// Получить callback remote-функции
local function SafeGetCallbackValue(Remote, Method)
	if getcallbackvalue then
		local ok, value = pcall(getcallbackvalue, Remote, Method)
		if ok then return true, value end
	end
	local ok, value = pcall(function() return Remote[Method] end)
	return ok, value
end

---------------------------------------------------------------------

function Hook:Init(Data)
    Modules = Data.Modules

	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration
end

--// The callback is expected to return a nil value sometimes which should be ingored
local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
	--// Защита от рекурсии, если мы уже внутри потока хука
	if IsHookThread() then
		if AlwaysTable then
			return {OriginalFunc(...)}
		end
		return OriginalFunc(...)
	end

	--// Invoke callback and check for a reponce otherwise ignored
	local ReturnValues = Callback(...)
	if ReturnValues then
		--// Unpack
		if not AlwaysTable then
			return Process:Unpack(ReturnValues)
		end

		--// Return packed responce
		return ReturnValues
	end

	--// Return packed responce
	if AlwaysTable then
		return {OriginalFunc(...)}
	end

	--// Unpacked
	return OriginalFunc(...)
end)

local function Merge(Base: table, New: table)
	for Key, Value in next, New do
		Base[Key] = Value
	end
end

function Hook:Index(Object: Instance, Key: string)
	return IndexWithIdentity(Object, Key)
end

function Hook:PushConfig(Overwrites)
    Merge(self, Overwrites)
end

--// getrawmetatable (fallback-путь, оставлен как есть по структуре)
function Hook:ReplaceMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local ok, Metatable = pcall(getrawmetatable, Object)
	if not ok or not Metatable then
		error("getrawmetatable unavailable")
	end

	local OriginalFunc = clonefunction(Metatable[Call])

	--// Replace function
	pcall(setreadonly, Metatable, false)
	Metatable[Call] = newcclosure(function(...)
		return HookMiddle(OriginalFunc, Callback, false, ...)
	end)
	pcall(setreadonly, Metatable, true)

	return OriginalFunc
end

--// hookfunction (теперь через SafeHookFunction: oth для C, иначе hookfunction)
function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc)
	local WrappedCallback = newcclosure(Callback)
	local OriginalFunc

	OriginalFunc = SafeHookFunction(Func, function(...)
		return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
	end)

	--// Кэшируем оригинал для GetOriginalFunc
	self.PreviousFunctions[Func] = OriginalFunc
	return OriginalFunc
end

--// hookmetamethod (fallback-путь через hookfunction на метаметоде)
function Hook:HookMetaCall(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local ok, Metatable = pcall(getrawmetatable, Object)
	if not ok or not Metatable then
		error("getrawmetatable unavailable")
	end

	local Unhooked
	Unhooked = self:HookFunction(Metatable[Call], function(...)
		return HookMiddle(Unhooked, Callback, true, ...)
	end)
	return Unhooked
end

function Hook:HookMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Func = newcclosure(Callback)

	--// Сначала пробуем нативный hookmetamethod
	local old = SafeHookMetaMethod(Object, Call, Func)
	if old ~= nil then
		self.PreviousFunctions[Call] = old
		return old
	end

	--// Getrawmetatable
	if Config.ReplaceMetaCallFunc then
		return self:ReplaceMetaMethod(Object, Call, Func)
	end

	--// Hookmetamethod (через hookfunction на метаметоде)
	return self:HookMetaCall(Object, Call, Func)
end

--// This includes a few patches for executor functions that result in detection
--// This isn't bulletproof since some functions like hookfunction I can't patch
--// By the way, thanks for copying this guys! Super appreciate the copycat
function Hook:PatchFunctions()
	--// Check if this function is disabled in the configuration
	if Config.NoFunctionPatching then return end

	local Patches = {
		--// Error detection patch
		--// hookfunction may still be detected depending on the executor
		[pcall] =  function(OldFunc, Func, ...)
			local Responce = {OldFunc(Func, ...)}
			local Success, Error = Responce[1], Responce[2]
			local IsC = iscclosure(Func)

			--// Patch c-closure error detection
			if Success == false and IsC then
				local NewError = Process:CleanCError(Error)
				Responce[2] = NewError
			end

			--// Stack-overflow detection patch
			if Success == false and not IsC and Error:find("C stack overflow") then
				local Tracetable = Error:split(":")
				local Caller, Line = Tracetable[1], Tracetable[2]
				local Count = Process:CountMatches(Error, Caller)

				if Count == 196 then
					Communication:ConsolePrint(`C stack overflow patched, count was {Count}`)
					Responce[2] = Error:gsub(`{Caller}:{Line}: `, Caller, 1)
				end
			end

			return Responce
		end,
		[getfenv] = function(OldFunc, Level: number, ...)
			Level = Level or 1

			--// Prevent catpure of executor's env
			if type(Level) == "number" then
				Level += 2
			end

			local Responce = {OldFunc(Level, ...)}
			local ENV = Responce[1]

			--// __tostring ENV detection patch
			if not checkcaller() and ENV == ExeENV then
				Communication:ConsolePrint("ENV escape patched")
				return OldFunc(999999, ...)
			end

			return Responce
		end
	}

	--// Hook each function
	for Func, CallBack in Patches do
		local Wrapped = newcclosure(CallBack)
		local OldFunc; OldFunc = self:HookFunction(Func, function(...)
			return Wrapped(OldFunc, ...)
		end)

		--// Cache previous function
		self.PreviousFunctions[Func] = OldFunc
	end
end

function Hook:GetOriginalFunc(Func)
	return self.PreviousFunctions[Func] or Func
end

function Hook:RunOnActors(Code: string, ChannelId: number)
	if not getactors or not run_on_actor then return end

	local Actors = getactors()
	if not Actors then return end

	for _, Actor in Actors do
		pcall(run_on_actor, Actor, Code, ChannelId)
	end
end

local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	return Process:ProcessRemote({
		Method = Method,
		OriginalFunc = OriginalFunc,
		MetaMethod = MetaMethod,
		TransferType = "Send",
		IsExploit = checkcaller()
	}, self, ...)
end

function Hook:HookRemoteTypeIndex(ClassName: string, FuncName: string)
	--// Пытаемся переиспользовать существующий инстанс, чтобы не создавать новый
	local Remote
	if getnilinstances then
		for _, inst in next, getnilinstances() do
			if inst.ClassName == ClassName and inst[FuncName] then
				Remote = inst
				break
			end
		end
	end
	if not Remote then
		local ok, inst = pcall(function()
			return Instance.new(ClassName)
		end)
		if not ok or not inst then return end
		Remote = inst
	end

	local Func = Remote[FuncName]
	local OriginalFunc

	--// Remotes will share the same functions
	--// 	For example FireServer will be identical
	--// Addionally, this is for __index calls.
	--// 	A __namecall hook will not detect this
	OriginalFunc = self:HookFunction(Func, function(self, ...)
		--// Check if the Object is allowed
		if not Process:RemoteAllowed(self, "Send", FuncName) then return end

		--// Process the remote data
		return ProcessRemote(OriginalFunc, "__index", self, FuncName, ...)
	end)
end

function Hook:HookRemoteIndexes()
	local RemoteClassData = Process.RemoteClassData
	for ClassName, Data in RemoteClassData do
		local FuncName = Data.Send[1]
		self:HookRemoteTypeIndex(ClassName, FuncName)
	end
end

function Hook:BeginHooks()
	--// Hook Remote functions
	self:HookRemoteIndexes()

	--// Namecall hook
	local OriginalNameCall
	OriginalNameCall = self:HookMetaMethod(game, "__namecall", function(self, ...)
		local Method = getnamecallmethod()
		return ProcessRemote(OriginalNameCall, "__namecall", self, Method, ...)
	end)

	Merge(self, {
		OriginalNamecall = OriginalNameCall,
		--OriginalIndex = Oi
	})
end

function Hook:HookClientInvoke(Remote, Method, Callback)
	local Success, Function = SafeGetCallbackValue(Remote, Method)

	--// Some executors like Potassium will throw a error if the Callback value is nil
	if not Success then return end
	if not Function then return end

	--// Test hookfunction
	local HookSuccess = pcall(function()
		self:HookFunction(Function, Callback)
	end)
	if HookSuccess then return end

	--// Replace callback function otherwise
	local ok = pcall(function()
		Remote[Method] = function(...)
			return HookMiddle(Function, Callback, false, ...)
		end
	end)
	return ok
end

function Hook:MultiConnect(Remotes)
	for _, Remote in next, Remotes do
		self:ConnectClientRecive(Remote)
	end
end

function Hook:ConnectClientRecive(Remote)
	--// Check if the Remote class is allowed for receiving
	local Allowed = Process:RemoteAllowed(Remote, "Receive")
	if not Allowed then return end

	--// Check if the Object has Remote class data
    local ClassData = Process:GetClassData(Remote)
    local IsRemoteFunction = ClassData.IsRemoteFunction
	local NoReciveHook = ClassData.NoReciveHook
    local Method = ClassData.Receive[1]

	--// Check if the Recive should be hooked
	if NoReciveHook then return end

	--// New callback function
	local function Callback(...)
        return Process:ProcessRemote({
            Method = Method,
            IsReceive = true,
            MetaMethod = "Connect",
			IsExploit = checkcaller()
        }, Remote, ...)
	end

	--// Connect remote
	if not IsRemoteFunction then
   		Remote[Method]:Connect(Callback)
	else -- Remote functions
		self:HookClientInvoke(Remote, Method, Callback)
	end
end

function Hook:BeginService(Libraries, ExtraData, ChannelId, ...)
	--// Librareis
	local ReturnSpoofs = Libraries.ReturnSpoofs
	local ProcessLib = Libraries.Process
	local Communication = Libraries.Communication
	local Generation = Libraries.Generation
	local Config = Libraries.Config

	--// Check for configuration overwrites
	ProcessLib:CheckConfig(Config)

	--// Init data
	local InitData = {
		Modules = {
			ReturnSpoofs = ReturnSpoofs,
			Generation = Generation,
			Communication = Communication,
			Process = ProcessLib,
			Config = Config,
			Hook = self
		},
		Services = setmetatable({}, {
			__index = function(self, Name: string): Instance
				local Service = game:GetService(Name)
				return cloneref(Service)
			end,
		})
	}

	--// Init libraries
	Communication:Init(InitData)
	ProcessLib:Init(InitData)

	--// Communication configuration
	local Channel, IsWrapped = Communication:GetCommChannel(ChannelId)
	Communication:SetChannel(Channel)
	Communication:AddTypeCallbacks({
		["RemoteData"] = function(Id: string, RemoteData)
			ProcessLib:SetRemoteData(Id, RemoteData)
		end,
		["AllRemoteData"] = function(Key: string, Value)
			ProcessLib:SetAllRemoteData(Key, Value)
		end,
		["UpdateSpoofs"] = function(Content: string)
			local Spoofs = loadstring(Content)()
			ProcessLib:SetNewReturnSpoofs(Spoofs)
		end,
		["BeginHooks"] = function(Config)
			if Config.PatchFunctions then
				self:PatchFunctions()
			end
			self:BeginHooks()
			Communication:ConsolePrint("Hooks loaded")
		end
	})

	--// Process configuration
	ProcessLib:SetChannel(Channel, IsWrapped)
	ProcessLib:SetExtraData(ExtraData)

	--// Hook configuration
	self:Init(InitData)

	if ExtraData and ExtraData.IsActor then
		Communication:ConsolePrint("Actor connected!")
	end
end

function Hook:LoadMetaHooks(ActorCode: string, ChannelId: number)
	--// Hook actors
	if not Configuration.NoActors then
		self:RunOnActors(ActorCode, ChannelId)
	end

	--// Hook current thread
	self:BeginService(Modules, nil, ChannelId)
end

function Hook:LoadReceiveHooks()
	local NoReceiveHooking = Config.NoReceiveHooking
	local BlackListedServices = Config.BlackListedServices

	if NoReceiveHooking then return end

	--// Remote added
	game.DescendantAdded:Connect(function(Remote) -- TODO
		self:ConnectClientRecive(Remote)
	end)

	--// Collect remotes with nil parents
	self:MultiConnect(getnilinstances())

	--// Search for remotes
	for _, Service in next, game:GetChildren() do
		if table.find(BlackListedServices, Service.ClassName) then continue end
		self:MultiConnect(Service:GetDescendants())
	end
end

function Hook:LoadHooks(ActorCode: string, ChannelId: number)
	self:LoadMetaHooks(ActorCode, ChannelId)
	self:LoadReceiveHooks()
end

return Hook
