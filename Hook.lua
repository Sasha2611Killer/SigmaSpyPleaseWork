--!nolint DeprecatedApi

--[[
	Taking my methods 💖💖
	I love a paster and a skid, puts disgust in my face

	[2026-11-15] PERF REWRITE:
	- ProcessRemote инвертирован: игра вызывается СРАЗУ, лог ставится в очередь.
	- Очередь флашится раз в Heartbeat одним проходом (Cobalt-style batch).
	- __namecall больше не ждёт Communication:Send — чат не стоит за спамом.
	- RemoteAllowed кэшируется по (Instance, Direction, Method).
	- Receive-хуки тоже через очередь (они реже, но консистентно).
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

--// Верификационный токен для разметки собственных колбэков (Cobalt-style)
local SpyVerificationToken = tostring(tick()) .. "_" .. tostring(math.random(1, 1e6))

--=====================================================================
--// PERF: очередь логов + флаш на Heartbeat
--=====================================================================
local LogQueue = {
	Head = 1,
	Tail = 0,
	Items = {},
}

-- Максимум записей, обрабатываемых за один Heartbeat-тик.
-- Если спам больше — остаток уйдёт на следующем тике (не блокируем кадр).
local DRAIN_BUDGET_PER_TICK = 512

-- Кэш RemoteAllowed: [Instance] = { [Method] = boolean }
-- __mode="k" чтобы не течь на удалённых ремоутах.
local RemoteAllowedCache = setmetatable({}, { __mode = "k" })

local function IsRemoteAllowedCached(self, Direction, Method)
	local bucket = RemoteAllowedCache[self]
	if not bucket then
		bucket = {}
		RemoteAllowedCache[self] = bucket
	end

	local cached = bucket[Method]
	if cached ~= nil then
		return cached
	end

	local allowed = Process:RemoteAllowed(self, Direction, Method)
	bucket[Method] = allowed
	return allowed
end

local function EnqueueLog(Entry)
	local Q = LogQueue
	Q.Tail += 1
	Q.Items[Q.Tail] = Entry
end

-- Флаш очереди. Вызывается из Heartbeat-треда, не из __namecall.
local function FlushLogQueue()
	local Q = LogQueue
	if Q.Head > Q.Tail then
		return
	end

	local budget = DRAIN_BUDGET_PER_TICK
	while Q.Head <= Q.Tail and budget > 0 do
		local entry = Q.Items[Q.Head]
		Q.Items[Q.Head] = nil
		Q.Head += 1
		budget -= 1

		if not entry then
			continue
		end

		-- ADAPT: подгони под реальную сигнатуру Process:ProcessRemote.
		-- Ожидается: Process:ProcessRemote(Data, Self, ...)
		-- Если у тебя другая — поправь аргументы ниже.
		pcall(
			Process.ProcessRemote,
			Process,
			entry.Data,
			entry.Self,
			Process:Unpack(entry.Args, 1, entry.Args.n)
		)
	end

	if Q.Head > Q.Tail then
		table.clear(Q.Items)
		Q.Head = 1
		Q.Tail = 0
	end
end

-- Один глобальный флаш-тред на весь Hook
local FlushThreadStarted = false
local function StartFlushThread()
	if FlushThreadStarted then
		return
	end
	FlushThreadStarted = true

	task.spawn(function()
		local RunService = game:GetService("RunService")
		while not (Configuration and Configuration.Unloaded) do
			RunService.Heartbeat:Wait()
			local ok, err = pcall(FlushLogQueue)
			if not ok then
				warn("[Hook] FlushLogQueue error:", err)
			end
		end
	end)
end

--=====================================================================
--// Hook setup
--=====================================================================

function Hook:Init(Data)
	Modules = Data.Modules

	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration

	-- включаем авто-игнор шумных ремоутов, если Process его поддерживает
	pcall(function()
		if Process.SetAutoIgnoreSpammyEvents then
			Process:SetAutoIgnoreSpammyEvents(true)
		end
	end)

	-- стартуем флаш-тред как только есть Process
	StartFlushThread()
end

--// Callback-обёртка для детуров (OnClientInvoke и т.п.).
--// Сохранена для случаев, где Callback возвращает значения напрямую.
local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
	local ReturnValues = Callback(...)
	if ReturnValues then
		if not AlwaysTable then
			return Process:Unpack(ReturnValues)
		end
		return ReturnValues
	end

	if AlwaysTable then
		return { OriginalFunc(...) }
	end

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

	setreadonly(Metatable, false)
	Metatable[Call] = newcclosure(function(...)
		return HookMiddle(OriginalFunc, Callback, false, ...)
	end)
	setreadonly(Metatable, true)

	return OriginalFunc
end

--// hookfunction
function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc)
	local OriginalFunc
	local WrappedCallback = newcclosure(Callback)
	OriginalFunc = clonefunction(hookfunction(Func, function(...)
		return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
	end))
	return OriginalFunc
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

	if Config.ReplaceMetaCallFunc then
		return self:ReplaceMetaMethod(Object, Call, Func)
	end

	return self:HookMetaCall(Object, Call, Func)
end

function Hook:PatchFunctions()
	if (Configuration and Configuration.NoFunctionPatching) or (Config and Config.NoFunctionPatching) then return end

	local _hookfunction = clonefunction(hookfunction)

	local Patches = {
		[pcall] = function(OldFunc, Func, ...)
			local Responce = { OldFunc(Func, ...) }
			local Success, Error = Responce[1], Responce[2]

			if Success == false and type(Error) == "string"
				and not iscclosure(Func) and Error:find("C stack overflow")
			then
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

			if type(Level) == "number" then
				Level += 2
			end

			local Responce = { OldFunc(Level, ...) }
			local ENV = Responce[1]

			if not checkcaller() and ENV == ExeENV then
				Communication:ConsolePrint("ENV escape patched")
				return OldFunc(999999, ...)
			end

			return Responce
		end
	}

	for Func, CallBack in Patches do
		local Original = clonefunction(Func)
		local Wrapped = newcclosure(CallBack)

		_hookfunction(Func, function(...)
			return Wrapped(Original, ...)
		end)

		self.PreviousFunctions[Func] = Original
	end
end

function Hook:GetOriginalFunc(Func)
	return self.PreviousFunctions[Func] or Func
end

function Hook:IsSpyConnectionFunction(Function): boolean
	if not Function then return false end
	if Process.LogConnectionFunctions[Function] then return true end

	local Success, Env = pcall(getfenv, Function)
	return Success
		and typeof(Env) == "table"
		and rawget(Env, "__SigmaSpyLogger") == SpyVerificationToken
end

function Hook:RunOnActors(Code: string, ChannelId: number)
	if not getactors or not run_on_actor then return end

	local function HookActor(Actor)
		task.spawn(function()
			local Hooked = false
			local Attempts = 0
			repeat
				Hooked = pcall(run_on_actor, Actor, Code, ChannelId)
				Attempts += 1
				if not Hooked then
					task.wait(0.25)
				end
			until Hooked or Attempts > 10
		end)
	end

	local SkipClassic = false
	if typeof(getactorstates) == "function" then
		local Ok, States = pcall(getactorstates)
		if Ok and type(States) == "table" then
			local First = next(States)
			if type(First) == "thread" and typeof(run_on_thread) == "function" then
				for _, State in States do
					pcall(run_on_thread, State, Code, ChannelId)
				end
				SkipClassic = true
			elseif (type(First) == "userdata" or type(First) == "table") and First.IsActorState then
				local HookedAny = false
				for _, Proxy in States do
					if not Proxy.IsActorState then continue end
					local OkH = pcall(function()
						return Proxy:Execute(Code, ChannelId, Proxy:GetActors()[1])
					end)
					HookedAny = HookedAny or OkH
				end
				if HookedAny then
					SkipClassic = true
				end
			end
		end
	end

	if not SkipClassic then
		for _, Category in { getactors(), typeof(getdeletedactors) == "function" and getdeletedactors() or {} } do
			if Category then
				for _, Actor in next, Category do
					HookActor(Actor)
				end
			end
		end
	end

	local StateCreated = typeof(on_actor_state_created) == "RBXScriptSignal" and on_actor_state_created or nil
	if StateCreated then
		StateCreated:Connect(HookActor)
	else
		game.DescendantAdded:Connect(function(Instance)
			if typeof(Instance) == "Instance" and Instance:IsA("Actor") then
				HookActor(Instance)
			end
		end)
	end
end

--=====================================================================
--// ProcessRemote — ИНВЕРТИРОВАННЫЙ
--//
--// Старый порядок: Callback(ProcessRemote) → OriginalFunc (игра ждёт лог)
--// Новый:          OriginalFunc (игра) → EnqueueLog (быстро) → return
--//
--// __namecall больше не блокируется Communication:Send.
--=====================================================================
local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	-- 1) игра — сразу, ноль задержки
	local Results = table.pack(OriginalFunc(self, ...))

	-- 2) лог — в очередь, но только если ремоут разрешён
	--    (IsRemoteAllowedCached дешёвый после первого раза)
	if IsRemoteAllowedCached(self, "Send", Method) then
		EnqueueLog({
			Data = {
				Method = Method,
				OriginalFunc = OriginalFunc,
				MetaMethod = MetaMethod,
				TransferType = "Send",
				IsExploit = checkcaller(),
			},
			Self = self,
			Args = table.pack(...),
		})
	end

	-- 3) возвращаем результат игры как есть
	return Process:Unpack(Results, 1, Results.n)
end

function Hook:HookRemoteTypeIndex(ClassName: string, FuncName: string)
	local Remote = Instance.new(ClassName)
	local Func = Remote[FuncName]
	local OriginalFunc

	OriginalFunc = self:HookFunction(Func, function(self, ...)
		if not Process:RemoteAllowed(self, "Send", FuncName) then return end
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

function Hook:BypassAdonis()
	if typeof(getgc) ~= "function" then return end

	task.spawn(function()
		local Detected, Kill
		local Deadline = os.clock() + 10

		repeat
			for _, v in getgc(true) do
				if typeof(v) == "table" then
					local DetectFunc = rawget(v, "Detected")
					local KillFunc = rawget(v, "Kill")

					if typeof(DetectFunc) == "function" and not Detected then
						Detected = DetectFunc
						hookfunction(Detected, function()
							return true
						end)
					end

					if rawget(v, "Variables") and rawget(v, "Process")
						and typeof(KillFunc) == "function" and not Kill
					then
						Kill = KillFunc
						hookfunction(Kill, function() end)
					end
				end
			end

			if Detected then break end
			task.wait(0.5)
		until Detected or os.clock() > Deadline

		if not Detected then return end

		local Old; Old = hookfunction(getrenv().debug.info, newcclosure(function(...)
			local LevelOrFunc = ...
			if LevelOrFunc == Detected then
				return coroutine.yield(coroutine.running())
			end
			return Old(...)
		end))
	end)
end

function Hook:BeginHooks()
	--// Стартуем флаш-тред (на случай, если Init ещё не звался)
	StartFlushThread()

	local UseOth = typeof(oth) == "table" and typeof(oth.hook) == "function"
		and (not Configuration or Configuration.UseOthHooks ~= false)

	local OriginalNameCall

	if UseOth then
		local OthOriginal
		OthOriginal = oth.hook(getrawmetatable(game).__namecall, function(self, ...)
			local Method = getnamecallmethod()

			-- ВАЖНО: OriginalNameCall вызывается ВНУТРИ ProcessRemote,
			--         но теперь ProcessRemote сначала зовёт игру, потом лог.
			local Ok, ReturnValues = pcall(ProcessRemote, OthOriginal, "__namecall", self, Method, ...)
			if Ok and ReturnValues ~= nil then
				return ReturnValues
			end

			return OthOriginal(self, ...)
		end)
		OriginalNameCall = OthOriginal
	else
		OriginalNameCall = self:ReplaceMetaMethod(game, "__namecall", function(self, ...)
			local Method = getnamecallmethod()
			return ProcessRemote(OriginalNameCall, "__namecall", self, Method, ...)
		end)
	end

	Merge(self, {
		OriginalNamecall = OriginalNameCall,
	})
end

local function HideFromStack(Function)
	if typeof(setstackhidden) == "function" then
		pcall(setstackhidden, Function, true)
	end
	return Function
end

function Hook:HookClientInvoke(Remote, Method, Callback)
	local Success, Function = pcall(function()
		return getcallbackvalue(Remote, Method)
	end)

	if not Success then return end
	if not Function then return end

	local HookSuccess = pcall(function()
		self:HookFunction(Function, Callback)
	end)
	if HookSuccess then return end

	local Detour = HideFromStack(function(...)
		return HookMiddle(Function, Callback, false, ...)
	end)

	local OriginalEnv = {}
	pcall(function()
		OriginalEnv = getfenv(Function)
	end)
	local OriginalScript = rawget(OriginalEnv, "script")
	local Trampoline = trampoline_call or (typeof(syn) == "table" and syn.trampoline_call) or nil

	if Trampoline then
		pcall(Trampoline, function()
			Remote[Method] = Detour
		end, {}, {
			env = OriginalEnv,
			script = OriginalScript,
			identity = 2,
		})
	else
		task.spawn(function()
			setthreadidentity(2)
			setfenv(0, OriginalEnv)
			Remote[Method] = Detour
		end)
	end
end

function Hook:MultiConnect(Remotes)
	for _, Remote in next, Remotes do
		self:ConnectClientRecive(Remote)
	end
end

function Hook:ConnectClientRecive(Remote)
	local Allowed = Process:RemoteAllowed(Remote, "Receive")
	if not Allowed then return end

	local ClassData = Process:GetClassData(Remote)
	local IsRemoteFunction = ClassData.IsRemoteFunction
	local NoReciveHook = ClassData.NoReciveHook
	local Method = ClassData.Receive[1]

	if NoReciveHook then return end

	-- Receive-колбэк: ставим в очередь, но игра уже отработала.
	-- Receive-хуки вызываются на входящих ремоутах — там ProcessRemote
	-- это и есть обработчик (мы получаем данные ОТ игры). Здесь
	-- инвертировать нечего: Callback = Process:ProcessRemote, и его
	-- надо вызвать, чтобы залогировать. Но чтобы не блокировать
	-- игровой тред — ставим в ту же очередь.
	local Callback = HideFromStack(function(...)
		local Args = table.pack(...)
		EnqueueLog({
			Data = {
				Method = Method,
				IsReceive = true,
				MetaMethod = "Connect",
				IsExploit = checkcaller(),
			},
			Self = Remote,
			Args = Args,
		})
	end)

	local OriginalEnv = getfenv(Callback)
	setfenv(Callback, setmetatable({
		["__SigmaSpyLogger"] = SpyVerificationToken,
	}, {
		__index = OriginalEnv,
		__newindex = OriginalEnv,
	}))

	Process.LogConnectionFunctions[Callback] = true

	if not IsRemoteFunction then
		Remote[Method]:Connect(Callback)
	else
		if Configuration and Configuration.StealthReceive then return end
		self:HookClientInvoke(Remote, Method, Callback)
	end
end

function Hook:BeginService(Libraries, ExtraData, ChannelId, ...)
	local ReturnSpoofs = Libraries.ReturnSpoofs
	local ProcessLib = Libraries.Process
	local Communication = Libraries.Communication
	local Generation = Libraries.Generation
	local Config = Libraries.Config

	ProcessLib:CheckConfig(Config)

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

	Communication:Init(InitData)
	ProcessLib:Init(InitData)

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

	ProcessLib:SetChannel(Channel, IsWrapped)
	ProcessLib:SetExtraData(ExtraData)

	self:Init(InitData)

	if ExtraData and ExtraData.IsActor then
		Communication:ConsolePrint("Actor connected!")
	end
end

function Hook:LoadMetaHooks(ActorCode: string, ChannelId: number)
	if not Configuration or not Configuration.NoActors then
		self:RunOnActors(ActorCode, ChannelId)
	end

	self:BeginService(Modules, nil, ChannelId)
end

function Hook:LoadReceiveHooks()
	local NoReceiveHooking = Config.NoReceiveHooking
	local BlackListedServices = Config.BlackListedServices

	if NoReceiveHooking then return end

	game.DescendantAdded:Connect(function(Remote)
		self:ConnectClientRecive(Remote)
	end)

	self:MultiConnect(getnilinstances())

	for _, Service in next, game:GetChildren() do
		if table.find(BlackListedServices, Service.ClassName) then continue end
		self:MultiConnect(Service:GetDescendants())
	end
end

function Hook:LoadHooks(ActorCode: string, ChannelId: number)
	self:BypassAdonis()
	self:LoadMetaHooks(ActorCode, ChannelId)
	self:LoadReceiveHooks()
end

return Hook
