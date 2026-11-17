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

--// Верификационный токен для разметки собственных колбэков (Cobalt-style):
--// игровые переборщики getconnections не могут отличить наш логгер,
--// т.к. токен живёт в env функции и переживает clonefunction.
local SpyVerificationToken = tostring(tick()) .. "_" .. tostring(math.random(1, 1e6))

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
	
	--// Getrawmetatable
	if Config.ReplaceMetaCallFunc then
		return self:ReplaceMetaMethod(Object, Call, Func)
	end
	
	--// Hookmetamethod
	return self:HookMetaCall(Object, Call, Func)
end

function Hook:PatchFunctions()
	--// Check if this function is disabled in the configuration
	if (Configuration and Configuration.NoFunctionPatching) or (Config and Config.NoFunctionPatching) then return end

	--// [FIX 2026-11-03] КЛАССИКА. clonefunction(clonefunction) УБРАН —
	--// недопустим и спамил ошибку в консоль (строка с "clonefunction"
	--// в логе = риск по списку Adonis). Защищённая копия — только
	--// hookfunction; цели клонируем обычным clonefunction.
	local _hookfunction = clonefunction(hookfunction)

	local Patches = {
		[pcall] = function(OldFunc, Func, ...)
			local Responce = {OldFunc(Func, ...)}
			local Success, Error = Responce[1], Responce[2]

			--// Только C stack overflow; обычные ошибки не трогаем
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

			local Responce = {OldFunc(Level, ...)}
			local ENV = Responce[1]

			if not checkcaller() and ENV == ExeENV then
				Communication:ConsolePrint("ENV escape patched")
				return OldFunc(999999, ...)
			end

			return Responce
		end
	}

	--// Hook each function
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

--// Cobalt-style: проверка "это наш логгер?" — реестр по ссылке ИЛИ
--// env-токен (выживает при clonefunction)
function Hook:IsSpyConnectionFunction(Function): boolean
	if not Function then return false end
	if Process.LogConnectionFunctions[Function] then return true end

	local Success, Env = pcall(getfenv, Function)
	return Success
		and typeof(Env) == "table"
		and rawget(Env, "__SigmaSpyLogger") == SpyVerificationToken
end

--// [ROBUST] Хук акторов.
--// Почему переписано:
--//  * run_on_actor на Delta при отказе возвращает false, а pcall возвращает true —
--//    старая версия считала это успехом и молча ничего не хукала;
--//  * getactorstates() может вернуть userdata без поля IsActorState — старая версия
--//    падала на индексации и роняла весь LoadHooks;
--//  * Instance.new("Actor") Delta вообще не видит в getactors() (нужна готовая VM),
--//    поэтому бессмысленно ретраить такой актор 10 раз с паузами.
function Hook:RunOnActors(Code: string, ChannelId: number)
	if typeof(getactors) ~= "function" or typeof(run_on_actor) ~= "function" then
		warn("[SigmaSpy] actors: нет getactors/run_on_actor — акторы пропущены")
		return
	end

	local Attempted = setmetatable({}, { __mode = "k" })
	local Connected = 0
	local Tried = 0
	local UsedStates = false

	local function TryActor(Actor, Attempt, Quiet)
		if typeof(Actor) ~= "Instance" or not Actor:IsA("Actor") then return false end
		if Attempted[Actor] then return false end
		Attempted[Actor] = true
		Tried += 1

		--// Delta: при отказе возвращает false, ошибку не бросает
		local Ok, Ret = pcall(run_on_actor, Actor, Code, ChannelId)
		if Ok and Ret ~= false then
			Connected += 1
			return true
		end

		--// у актора могла ещё не подняться VM — одна отложенная попытка
		if Attempt == 1 then
			task.delay(1, function()
				if UsedStates then return end
				local Ok2, Ret2 = pcall(run_on_actor, Actor, Code, ChannelId)
				if Ok2 and Ret2 ~= false then
					Connected += 1
				elseif not Quiet then
					warn(("[SigmaSpy] actor %s не принял код (ok=%s, ret=%s)")
						:format(tostring(Actor), tostring(Ok2), tostring(Ret2)))
				end
			end)
		elseif not Quiet then
			warn(("[SigmaSpy] actor %s не принял код (ok=%s, ret=%s)")
				:format(tostring(Actor), tostring(Ok), tostring(Ret)))
		end
		return false
	end

	--// 1) акторы из игры (у Delta это единственные, у кого есть VM)
	local Lists = {}
	local OkGet, All = pcall(getactors)
	if OkGet and typeof(All) == "table" then
		Lists[#Lists + 1] = { All, false }
	end
	if typeof(getdeletedactors) == "function" then
		local OkDel, Deleted = pcall(getdeletedactors)
		if OkDel and typeof(Deleted) == "table" then
			--// удалённые акторы почти всегда уже без VM — не спамим warn
			Lists[#Lists + 1] = { Deleted, true }
		end
	end

	for _, Entry in next, Lists do
		for _, Actor in next, Entry[1] do
			TryActor(Actor, 1, Entry[2])
		end
	end

	--// 2) если классический путь не дал ни одного подключения — состояния
	local StatesUsed = 0
	if Connected == 0 and typeof(getactorstates) == "function" then
		local Ok, States = pcall(getactorstates)
		if Ok and typeof(States) == "table" then
			for _, State in next, States do
				if type(State) == "thread" then
					if typeof(run_on_thread) == "function" then
						StatesUsed += 1
						pcall(run_on_thread, State, Code, ChannelId)
					end
					continue
				end

				--// поле может отсутствовать (userdata/proxy) — проверяем безопасно
				local OkIs, IsState = pcall(function() return State.IsActorState end)
				if OkIs and IsState then
					StatesUsed += 1
					pcall(function()
						return State:Execute(Code, ChannelId, State:GetActors()[1])
					end)
				end
			end
		end
	end
	UsedStates = StatesUsed > 0

	--// 3) акторы, появившиеся позже
	local Signal = typeof(on_actor_state_created) == "RBXScriptSignal" and on_actor_state_created or nil
	if Signal then
		Signal:Connect(function(Actor)
			TryActor(Actor, 1)
		end)
	else
		game.DescendantAdded:Connect(function(Instance)
			if typeof(Instance) == "Instance" and Instance:IsA("Actor") then
				task.delay(0.5, function()
					TryActor(Instance, 1)
				end)
			end
		end)
	end

	if UsedStates then
		if Configuration and Configuration.Debug then
			print("[SigmaSpy] actors: использован путь getactorstates()/Execute")
		end
	elseif Connected > 0 then
		if Configuration and Configuration.Debug then
			print(("[SigmaSpy] actors: подключено %d"):format(Connected))
		end
	elseif Tried > 0 then
		warn("[SigmaSpy] actors: ни один актор не принял код (Delta видит только акторы с готовой VM)")
	elseif Configuration and Configuration.Debug then
		print("[SigmaSpy] actors: в игре нет акторов с VM — пропущено")
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
	--// Два режима, переключаются Configuration.UseOthHooks:
	--// true  — oth (отдельный тред): детекторам не виден, но обход
	--//         стека не видит игру → обе кнопки Decompile показывают
	--//         один скрипт (fallback getcallingscript).
	--// false — ПРЯМАЯ ЗАПИСЬ __namecall: обработчик на игровом треде,
	--//         полная атрибуция (SourceScript/CallerScript различаются).
	--//         Детекты Adonis нейтрализует BypassAdonis.
	--// Оба режима распаковывают результат (Unpack) — без этого игра
	--// получает таблицу вместо значений (зависание камеры).
	local UseOth = typeof(oth) == "table" and typeof(oth.hook) == "function"
		and (not Configuration or Configuration.UseOthHooks ~= false)

	local OriginalNameCall

	if UseOth then
		local OthOriginal
		OthOriginal = oth.hook(getrawmetatable(game).__namecall, function(self, ...)
			local Method = getnamecallmethod()

			local Ok, ReturnValues = pcall(ProcessRemote, OthOriginal, "__namecall", self, Method, ...)
			if Ok and ReturnValues then
				return Process:Unpack(ReturnValues)
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
--// Скрытие функции из стека (Cobalt делает так для детуров).
--// Executor без setstackhidden — просто пропускаем (pcall).
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

	--// Some executors like Potassium will throw a error if the Callback value is nil
	if not Success then return end
	if not Function then return end
	
	--// Test hookfunction
	local HookSuccess = pcall(function()
		self:HookFunction(Function, Callback)
	end)
	if HookSuccess then return end

	--// Replace callback function otherwise (скрыт из стека, Cobalt-style)
	local Detour = HideFromStack(function(...)
		return HookMiddle(Function, Callback, false, ...)
	end)

	--// Cobalt-style: присвоение OnClientInvoke под identity 2 и env
	--// оригинального колбэка — игровые __newindex-детекты видят "свой"
	--// вызов (checkcaller() == false), а не executor.
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

	--// New callback function (скрыт из стека, Cobalt-style)
	local Callback = HideFromStack(function(...)
        return Process:ProcessRemote({
            Method = Method,
            IsReceive = true,
            MetaMethod = "Connect",
			IsExploit = checkcaller()
        }, Remote, ...)
	end)

	--// Env-токен (Cobalt-style): помечаем функцию как свою — токен живёт
	--// в env и переживает clonefunction, в отличие от реестра по ссылке.
	local OriginalEnv = getfenv(Callback)
	setfenv(Callback, setmetatable({
		["__SigmaSpyLogger"] = SpyVerificationToken,
	}, {
		__index = OriginalEnv,
		__newindex = OriginalEnv,
	}))

	--// Не показывать собственный колбэк в списке соединений
	Process.LogConnectionFunctions[Callback] = true

	--// Connect remote
	if not IsRemoteFunction then
   		Remote[Method]:Connect(Callback)
	else -- Remote functions
		--// [ANTI-DETECT] Детур OnClientInvoke требует hookfunction на
		--// игровой колбэк — детектится. В стелс-режиме пропускаем.
		if Configuration and Configuration.StealthReceive then return end
		self:HookClientInvoke(Remote, Method, Callback)
	end
end

function Hook:BeginService(Libraries, ExtraData, ChannelId, ...)
	--// [FIX] генератор ActorCode может передать {ChannelId} — разворачиваем,
	--// иначе get_comm_channel(number expected, got table)
	if type(ChannelId) == "table" then
		ChannelId = ChannelId[1]
	end

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
	if not Configuration or not Configuration.NoActors then
		self:RunOnActors(ActorCode, ChannelId)
	else
		warn("[SigmaSpy] actors: отключены (NoActors = true)")
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
	self:BypassAdonis()
	self:LoadMetaHooks(ActorCode, ChannelId)
	self:LoadReceiveHooks()
end

return Hook
