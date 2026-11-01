--!nolint DeprecatedApi

--[[
	Обновлённый модуль Hook (v2 — с портами из Cobalt).
	Изменения относительно оригинала:
	- Capability detection: oth и библиотека Actors используются автоматически
	- Hook:HookFunction — oth.hook при наличии (фоллбэк hookfunction)
	- Hook:UnhookFunction — снятие хуков (oth.unhook / restorefunction)
	- Hook:RunOnActors — getdeletedactors + подписка на новые акторы
	  (Actors.on_actor_state_created → глобальное on_actor_state_created →
	  fallback game.DescendantAdded), как у Cobalt
	- setstackhidden на receive-колбэках (Cobalt делает так для детуров)
	- Все хуки кэшируют оригинал в PreviousFunctions
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

--// Capability detection — один раз при загрузке
local Capabilities = {
	Oth = typeof(oth) == "table"
		and typeof(oth.hook) == "function"
		and typeof(oth.get_root_callback) == "function",
	NewActors = typeof(Actors) == "table"
		and typeof(Actors.run_on_actor) == "function"
		and typeof(Actors.getactors) == "function",
}

function Hook:HasOth(): boolean
	return Capabilities.Oth
end

function Hook:HasNewActors(): boolean
	return Capabilities.NewActors
end

function Hook:GetCapabilities(): table
	return Capabilities
end

--// True, если текущий код выполняется внутри oth-хука
function Hook:IsOthThread(): boolean
	if not Capabilities.Oth then return false end
	if typeof(oth.is_hook_thread) ~= "function" then return false end
	return oth.is_hook_thread() or false
end

function Hook:Init(Data)
	Modules = Data.Modules

	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration
end

--// The callback is expected to return a nil value sometimes which should be ingored
local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
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
	local identity = getthreadidentity()
	setthreadidentity(8)
	local returned = Object[Key]
	setthreadidentity(identity)
	return returned
end

function Hook:PushConfig(Overwrites)
	Merge(self, Overwrites)
end

--// getrawmetatable
function Hook:ReplaceMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Metatable = getrawmetatable(Object)
	local OriginalFunc = clonefunction(Metatable[Call])

	--// Replace function
	setreadonly(Metatable, false)
	Metatable[Call] = newcclosure(function(...)
		return HookMiddle(OriginalFunc, Callback, false, ...)
	end)
	setreadonly(Metatable, true)

	return OriginalFunc
end

--// hookfunction / oth.hook — выбирается автоматически
function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc)
	local WrappedCallback = newcclosure(Callback)

	--// Современный путь: oth
	if Capabilities.Oth then
		local OriginalFunc
		oth.hook(Func, function(...)
			return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
		end)
		OriginalFunc = oth.get_root_callback(Func)

		self.PreviousFunctions[Func] = OriginalFunc
		return OriginalFunc
	end

	--// Классический путь
	local OriginalFunc
	OriginalFunc = clonefunction(hookfunction(Func, function(...)
		return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
	end))
	self.PreviousFunctions[Func] = OriginalFunc
	return OriginalFunc
end

--// Снятие хука
function Hook:UnhookFunction(Func: UnkFunc): boolean
	if Capabilities.Oth and typeof(oth.unhook) == "function" then
		oth.unhook(Func)
		self.PreviousFunctions[Func] = nil
		return true
	end

	if typeof(restorefunction) == "function" then
		restorefunction(Func)
		self.PreviousFunctions[Func] = nil
		return true
	end

	return false
end

--// hookmetamethod
function Hook:HookMetaCall(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Metatable = getrawmetatable(Object)
	local Unhooked

	Unhooked = self:HookFunction(Metatable[Call], function(...)
		return HookMiddle(Unhooked, Callback, true, ...)
	end)
	return Unhooked
end

function Hook:HookMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Func = newcclosure(Callback)

	--// Getrawmetatable
	if Config.ReplaceMetaCallFunc then
		return self:ReplaceMetaMethod(Object, Call, Func)
	end

	--// Hookmetamethod
	return self:HookMetaCall(Object, Call, Func)
end

--// This includes a few patches for executor functions that result in detection
function Hook:PatchFunctions()
	--// Check if this function is disabled in the configuration
	if Config.NoFunctionPatching then return end

	local Patches = {
		--// Error detection patch
		--// ПРИМЕЧАНИЕ: с oth сигнатуры "C stack overflow" могут отличаться
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

--// Подписка на появление новых акторов (порт подхода Cobalt):
--// новая библиотека Actors → глобальное событие → fallback через DescendantAdded
local function SubscribeToNewActors(Callback: (Instance) -> ())
	if Capabilities.NewActors and typeof(Actors.on_actor_state_created) == "RBXScriptSignal" then
		Actors.on_actor_state_created:Connect(Callback)
		return
	end

	if typeof(on_actor_state_created) == "RBXScriptSignal" then
		on_actor_state_created:Connect(Callback)
		return
	end

	--// Fallback: ловим акторов как инстансы
	game.DescendantAdded:Connect(function(Instance)
		if typeof(Instance) == "Instance" and Instance:IsA("Actor") then
			Callback(Instance)
		end
	end)
end

--// Запуск кода на акторх (порт подхода Cobalt: перебираем getactors И
--// getdeletedactors, подписываемся на новые состояния акторов)
function Hook:RunOnActors(Code: string, ChannelId: number)
	local RunOnActor = Capabilities.NewActors and Actors.run_on_actor or run_on_actor
	if typeof(RunOnActor) ~= "function" then return end

	local function HookActor(Actor)
		pcall(RunOnActor, Actor, Code, ChannelId)
	end

	local function HookAllActors()
		local Categories = {}

		if Capabilities.NewActors then
			table.insert(Categories, Actors.getactors())
		elseif typeof(getactors) == "function" then
			table.insert(Categories, getactors())
		end

		--// Удалённые (неинициализированные) акторы — Cobalt хукает и их
		if typeof(getdeletedactors) == "function" then
			table.insert(Categories, getdeletedactors())
		end

		for _, Category in Categories do
			if not Category then continue end
			for _, Actor in next, Category do
				HookActor(Actor)
			end
		end
	end

	--// Текущие + удалённые
	HookAllActors()

	--// Акторы, созданные позже
	SubscribeToNewActors(HookAllActors)
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
	local Remote = Instance.new(ClassName)
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
	local Success, Function = pcall(function()
		return getcallbackvalue(Remote, Method)
	end)

	--// Some executors like Potassium will throw a error if the Callback value is nil
	if not Success then return end
	if not Function then return end

	--// Test hookfunction
	local HookSuccess = pcall(function()
		self:HookFunction(Function, Callback)
	end)
	if HookSuccess then return end

	--// Replace callback function otherwise
	local Detour = function(...)
		return HookMiddle(Function, Callback, false, ...)
	end

	--// Скрываем детур из стека (Cobalt-style, если поддерживается)
	if typeof(setstackhidden) == "function" then
		pcall(setstackhidden, Detour, true)
	end

	Remote[Method] = Detour
end

function Hook:MultiConnect(Remotes)
	for _, Remote in next, Remotes do
		self:ConnectClientRecive(Remote)
	end
end

--// Скрытие колбэка из стека (Cobalt: setstackhidden на детурах)
local function HideFromStack(Function)
	if typeof(setstackhidden) == "function" then
		pcall(setstackhidden, Function, true)
	end
	return Function
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
	local Callback = HideFromStack(function(...)
        return Process:ProcessRemote({
            Method = Method,
            IsReceive = true,
            MetaMethod = "Connect",
			IsExploit = checkcaller()
        }, Remote, ...)
	end)

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
	assert(Channel, `Comm channel {ChannelId} not found`)
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
