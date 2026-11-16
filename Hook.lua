--!nolint DeprecatedApi

--[[
	Taking my methods 💖💖
	I love a paster and a skid, puts disgust in my face
]]

local Hook = {
	OriginalNamecall = nil,
	OriginalIndex = nil,
	PreviousFunctions = {},
	--// Remote, на которых уже стоит receive-хук (защита от дублей)
	ReceiveHooked = setmetatable({}, {__mode = "k"}),
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
	--// [FIX] В actor-VM / на экзекьюторах без identity-функций
	--// getthreadidentity/setthreadidentity могут отсутствовать.
	local HasIdentity = typeof(getthreadidentity) == "function"
		and typeof(setthreadidentity) == "function"

	if not HasIdentity then
		local Ok, Returned = pcall(function()
			return Object[Key]
		end)
		return Ok and Returned or nil
	end

	local Identity = getthreadidentity()
	setthreadidentity(8)
	local Ok, Returned = pcall(function()
		return Object[Key]
	end)
	setthreadidentity(Identity)

	if Ok then return Returned end
	return nil
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
	--// Идемпотентность: не патчим второй раз (actor + BeginHooks из main)
	if self.FunctionsPatched then return end

	--// Check if this function is disabled in the configuration
	if (Configuration and Configuration.NoFunctionPatching) or (Config and Config.NoFunctionPatching) then return end

	self.FunctionsPatched = true

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

function Hook:RunOnActors(Code: string, ChannelId: number)
	if not getactors or not run_on_actor then return end

	local function HookActor(Actor)
		task.spawn(function()
			local Hooked = false
			local Attempts = 0

			repeat
				--// БЫЛО: pcall(run_on_actor, Actor, Code, ChannelId)
				--// СТАЛО: + Actor вторым vararg'ом
				Hooked = pcall(run_on_actor, Actor, Code, ChannelId, Actor)
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
					--// Actor для треда неизвестен — передаём nil,
					--// IsActor всё равно выставится в actor-чанке.
					pcall(run_on_thread, State, Code, ChannelId, nil)
				end
				SkipClassic = true
			elseif (type(First) == "userdata" or type(First) == "table") and First.IsActorState then
				local HookedAny = false
				for _, Proxy in States do
					if not Proxy.IsActorState then continue end

					local Actors = Proxy:GetActors()
					local OkH = pcall(function()
						--// уже правильный порядок: ChannelId, Actor
						return Proxy:Execute(Code, ChannelId, Actors[1])
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

local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	return Process:ProcessRemote({
		Method = Method,
		OriginalFunc = OriginalFunc,
		MetaMethod = MetaMethod,
		TransferType = "Send",
		IsExploit = checkcaller()
	}, self, ...)
end

--// [FIX] Вызовы, которые уже обрабатывает __namecall. Если та же C-функция
--// дополнительно захукана через __index, второй хук не должен логировать
--// повторно (двойной лог + двойной обход стека).
local NamecallActive = setmetatable({}, {__mode = "k"})

--// [FIX] Дешёвый pre-check ВНУТРИ __namecall.
--// Раньше любой namecall (включая self:GetFullName() из старого print,
--// Script:IsA() из GetScriptFromFunc и т.д.) заходил в ProcessRemote.
--// Вызов метода инстанса изнутри __namecall = повторный вход в этот же
--// хук, а print(... self:GetFullName()) давал бесконечную рекурсию
--// (C stack overflow -> вылет игры). Теперь сюда попадают только
--// реальные remote-методы, и вложенные вызовы сразу уходят в оригинал.
--// ВАЖНО: здесь нельзя вызывать методы инстансов (GetFullName/IsA/...).
local function IsHookedSend(Object, Method: string): boolean
	if typeof(Object) ~= "Instance" then return false end
	if not Process then return false end

	local Lookup = Process.RemoteSendLookup
	if not Lookup then
		Process:BuildRemoteLookups()
		Lookup = Process.RemoteSendLookup
	end

	local Methods = Lookup and Lookup[Object.ClassName]
	if not Methods or not Methods[Method] then return false end

	if typeof(Process.IsProtectedRemote) == "function" and Process:IsProtectedRemote(Object) then
		return false
	end

	return true
end

--// Пускаем вызов в ProcessRemote.
--// ВАЖНО про возврат: __namecall заворачивается двумя разными способами.
--//  * oth.hook      — сырой хук: значения нужно вернуть РАСПАКОВАННЫМИ.
--//  * ReplaceMetaMethod — через HookMiddle: он ждёт УПАКОВАННУЮ таблицу
--//    (или nil, тогда сам зовёт оригинал и распаковывает).
--// Поэтому здесь возвращаем УПАКОВАННУЮ таблицу / nil, а распаковкой
--// занимается вызывающая ветка. Раньше распаковка была тут: пустой ответ
--// FireServer превращался в "no values" -> HookMiddle звал оригинал ЕЩЁ РАЗ
--// (двойная отправка remote), а InvokeServer с таблицей ломал HookMiddle.
local function CallNamecall(OriginalFunc, Object, Method: string, ...)
	local Thread = coroutine.running()
	local Active = NamecallActive[Thread]
	if not Active then
		Active = {}
		NamecallActive[Thread] = Active
	end

	--// Вложенный вызов на том же объекте (например self:GetFullName()
	--// изнутри обработки) — отдаём оригиналу, без рекурсии.
	if Active[Object] then return end

	--// Знаем, вызвался ли уже оригинал (внутри ProcessCallback). Если да,
	--// ошибку логирования нельзя "ронять" в fallback — иначе remote
	--// отправится второй раз.
	local OriginalCalled = false
	local function Tracked(...)
		OriginalCalled = true
		return OriginalFunc(...)
	end

	Active[Object] = true
	local Ok, ReturnValues = pcall(ProcessRemote, Tracked, "__namecall", Object, Method, ...)
	Active[Object] = nil

	if Ok then return ReturnValues end

	--// Логирование упало. Оригинал уже выполнен -> не дублируем вызов.
	if OriginalCalled then return {} end

	--// Оригинал не выполнялся -> пусть его вызовет обёртка, как обычно.
	return nil
end

--// [FIX] Дедуп: некоторые классы отдают ОДНУ И ТУ ЖЕ C-функцию
--// (RemoteEvent.FireServer == UnreliableRemoteEvent.FireServer).
--// Без этого повторный hookfunction заворачивал уже завёрнутую функцию
--// -> двойные логи и лишние кадры в стеке.
local HookedIndexFunctions = setmetatable({}, {__mode = "k"})

function Hook:HookRemoteTypeIndex(ClassName: string, FuncName: string)
	local Ok, Remote = pcall(Instance.new, ClassName)
	if not Ok or not Remote then return end

	local Func = Remote[FuncName]
	if typeof(Func) ~= "function" then
		--// алиасы вроде "fireServer"/"fireserver" не являются свойствами
		pcall(function() Remote:Destroy() end)
		return
	end

	if HookedIndexFunctions[Func] then
		pcall(function() Remote:Destroy() end)
		return
	end
	HookedIndexFunctions[Func] = true

	local OriginalFunc

	--// Remotes will share the same functions
	--// 	For example FireServer will be identical
	--// Addionally, this is for __index calls.
	--// 	A __namecall hook will not detect this
	OriginalFunc = self:HookFunction(Func, function(self, ...)
		--// Уже логируется через __namecall на этом же треде — не дублируем.
		--// Возвращаем nil: HookMiddle сам вызовет оригинал ровно один раз
		--// (вернуть результат оригинала нельзя — он его ещё раз распакует).
		local Active = NamecallActive[coroutine.running()]
		if Active and Active[self] then return end

		--// Check if the Object is allowed 
		if not Process:RemoteAllowed(self, "Send", FuncName) then return end

		--// Process the remote data
		return ProcessRemote(OriginalFunc, "__index", self, FuncName, ...)
	end)

	pcall(function() Remote:Destroy() end)
end

function Hook:HookRemoteIndexes()
	local RemoteClassData = Process.RemoteClassData
	for ClassName, Data in RemoteClassData do
		for _, FuncName in Data.Send or {} do
			local Ok, Err = pcall(self.HookRemoteTypeIndex, self, ClassName, FuncName)
			if not Ok and Communication then
				Communication:ConsolePrint("Index hook:", tostring(Err):sub(1, 120))
			end
		end
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
	if self.HooksStarted then return end
	self.HooksStarted = true

	local InActor = Process ~= nil and Process.ExtraData ~= nil
		and Process.ExtraData.IsActor == true

	local UseOth = not InActor
		and typeof(oth) == "table" and typeof(oth.hook) == "function"
		and (not Configuration or Configuration.UseOthHooks ~= false)

	local OriginalNameCall

	if UseOth then
		local OthOriginal
		OthOriginal = oth.hook(getrawmetatable(game).__namecall, function(self, ...)
			local Method = getnamecallmethod()

			if not IsHookedSend(self, Method) then
				return OthOriginal(self, ...)
			end

			local ReturnValues = CallNamecall(OthOriginal, self, Method, ...)
			if ReturnValues then
				return Process:Unpack(ReturnValues)
			end

			return OthOriginal(self, ...)
		end)
		OriginalNameCall = OthOriginal
	else
		local RawOriginal
		RawOriginal = hookmetamethod(game, "__namecall", function(self, ...)
			local Method = getnamecallmethod()

			if not IsHookedSend(self, Method) then
				return RawOriginal(self, ...)
			end

			local ReturnValues = CallNamecall(RawOriginal, self, Method, ...)
			if ReturnValues then
				return Process:Unpack(ReturnValues)
			end

			return RawOriginal(self, ...)
		end)
		OriginalNameCall = RawOriginal
	end

	Merge(self, {
		OriginalNamecall = OriginalNameCall,
	})

	pcall(self.HookRemoteIndexes, self)
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

	--// [FIX] Запоминаем скрипт-владельца callback ДО подмены.
	--// У OnClientInvoke/OnInvoke нет RBXScriptSignal, поэтому SourceScript
	--// для входящих вызовов берём из этого кэша (см. Process:ProcessRemote).
	local OriginalScript = Process:GetScriptFromFunc(Function)
	if typeof(OriginalScript) == "Instance" then
		Process.CallbackScripts[Remote] = OriginalScript
	end

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
			local HasIdentity = typeof(getthreadidentity) == "function"
				and typeof(setthreadidentity) == "function"
			local Identity = HasIdentity and getthreadidentity() or nil

			if HasIdentity then setthreadidentity(2) end
			pcall(function() setfenv(0, OriginalEnv) end)
			pcall(function()
				Remote[Method] = Detour
			end)
			if HasIdentity then setthreadidentity(Identity) end
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
	if not ClassData or not ClassData.Receive then return end

    local IsRemoteFunction = ClassData.IsRemoteFunction
	local NoReciveHook = ClassData.NoReciveHook
    local Method = ClassData.Receive[1]
	if not Method then return end

	--// Check if the Recive should be hooked
	if NoReciveHook then return end

	--// Не подключаем один и тот же remote дважды (сканы + DescendantAdded)
	local ReceiveHooked = self.ReceiveHooked
	if ReceiveHooked[Remote] then return end
	ReceiveHooked[Remote] = true

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
		local Ok, Connection = pcall(function()
			return Remote[Method]:Connect(Callback)
		end)

		if Ok and Connection then
			--// Сохраняем соединение для возможного использования
			Process:RememberConnection(Remote, Connection, getcallingscript())
		else
			ReceiveHooked[Remote] = nil
		end
	else
		if Configuration and Configuration.StealthReceive then return end
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
			Hook = self,
			--// В главном VM Configuration приходит из загрузчика. В actor-VM
			--// его нет (CompileModule пропускает таблицы), но актору он и не
			--// нужен: PatchFunctions/StealthReceive там не применяются,
			--// а BeginHooks в акторе всегда идёт напрямую (без oth).
			Configuration = Libraries.Configuration or Configuration
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
			--// Функциональные патчи нужны только в главном VM. В actor-VM
			--// они могут подменить pcall/getfenv самой игры — не трогаем.
			local InActor = Process and Process.ExtraData and Process.ExtraData.IsActor

			if Config and Config.PatchFunctions and not InActor then
				pcall(self.PatchFunctions, self)
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
	end

	--// Hook current thread
	self:BeginService(Modules, nil, ChannelId) 
end

function Hook:LoadReceiveHooks()
	--// Идемпотентность: actor вызывает сам + может прийти BeginHooks
	if self.ReceiveHooksLoaded then return end
	self.ReceiveHooksLoaded = true

	local NoReceiveHooking = Config.NoReceiveHooking
	local BlackListedServices = Config.BlackListedServices or {}

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
