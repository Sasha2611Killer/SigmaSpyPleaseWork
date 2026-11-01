--!nolint DeprecatedApi

--[[
	Обновлённый модуль Hook.
	Что изменено:
	- Capability detection: oth и библиотека Actors используются автоматически, если существуют
	- Hook:HookFunction — использует oth.hook при наличии (с фоллбэком на hookfunction)
	- Hook:UnhookFunction — снятие хуков через oth.unhook / restorefunction
	- Hook:IsOthThread / Hook:HasOth / Hook:HasNewActors / Hook:GetCapabilities
	- Hook:RunOnActors — подписывается на on_actor_state_created (акторы, созданные позже)
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

--// Capability detection — выполняется один раз при загрузке.
--// oth / Actors могут отсутствовать в окружении: обращение к ним безопасно (nil).
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

--// True, если текущий код выполняется внутри oth-хука (oth исполняет
--// callback на отдельном треде — это важно для разбора стека вызовов)
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

--// hookfunction / oth.hook — выбирается автоматически по capability detection.
--// Семантика возврата идентична: возвращается оригинал функции.
function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc)
	local WrappedCallback = newcclosure(Callback)

	--// Современный путь: oth (C-closure хуки, root callback, unhook)
	if Capabilities.Oth then
		local OriginalFunc
		oth.hook(Func, function(...)
			return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
		end)
		OriginalFunc = oth.get_root_callback(Func)

		--// Кэшируем оригинал (раньше кэшировалось только в PatchFunctions)
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

--// Снятие хука. Раньше такой возможности не было вовсе.
--// Возвращает true, если удалось снять.
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
--// This isn't bulletproof since some functions like hookfunction I can't patch
--// By the way, thanks for copying this guys! Super appreciate the copycat
function Hook:PatchFunctions()
	--// Check if this function is disabled in the configuration
	if Config.NoFunctionPatching then return end

	local Patches = {
		--// Error detection patch
		--// hookfunction may still be detected depending on the executor
		--// ПРИМЕЧАНИЕ: с oth сигнатуры "C stack overflow" могут отличаться —
		--// патч всё равно срабатывает, но строку ошибки стоит проверить на твоём executor'е
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

--// Запуск кода на акторах.
--// Современный путь (Actors): хук текущих акторов + подписка на вновь созданные.
--// Legacy путь: разовый проход по getactors().
function Hook:RunOnActors(Code: string, ChannelId: number)
	if Capabilities.NewActors then
		local function HookAllActors()
			local ActorList = Actors.getactors()
			if not ActorList then return end

			for _, Actor in next, ActorList do
				pcall(Actors.run_on_actor, Actor, Code, ChannelId)
			end
		end

		--// Текущие акторы
		HookAllActors()

		--// Акторы, созданные ПОЗЖЕ (в legacy-варианте это было упущено)
		local Signal = Actors.on_actor_state_created
		if typeof(Signal) == "RBXScriptSignal" then
			Signal:Connect(HookAllActors)
		end

		return
	end

	--// Legacy путь
	if not getactors or not run_on_actor then return end

	local ActorsList = getactors()
	if not ActorsList then return end

	for _, Actor in ActorsList do
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
	Remote[Method] = function(...)
		return HookMiddle(Function, Callback, false, ...)
	end
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
