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
			--// [FIX] Раньше возвращалась таблица Responce целиком: любой pcall()
			--// в игре/UI получал ОДИН table вместо (ok, result...). С включёнными
			--// "function patches" из-за этого ломался OnClientEvent и UI
			--// (меню перестаёт двигаться).
			local Results = table.pack(OldFunc(Func, ...))
			local Success, Error = Results[1], Results[2]

			--// Только C stack overflow; обычные ошибки не трогаем
			if Success == false and type(Error) == "string"
				and not iscclosure(Func) and Error:find("C stack overflow")
			then
				local Tracetable = Error:split(":")
				local Caller, Line = Tracetable[1], Tracetable[2]
				local Count = Process:CountMatches(Error, Caller)

				if Count == 196 then
					Communication:ConsolePrint(`C stack overflow patched, count was {Count}`)
					Results[2] = Error:gsub(`{Caller}:{Line}: `, Caller, 1)
				end
			end

			return table.unpack(Results, 1, Results.n)
		end,
		[getfenv] = function(OldFunc, Level: number, ...)
			Level = Level or 1

			if type(Level) == "number" then
				Level += 2
			end

			--// [FIX] тот же баг: возвращалась таблица вместо окружения,
			--// то есть getfenv() отдавал table вместо env.
			local Results = table.pack(OldFunc(Level, ...))
			local ENV = Results[1]

			if not checkcaller() and ENV == ExeENV then
				Communication:ConsolePrint("ENV escape patched")
				return OldFunc(999999, ...)
			end

			return table.unpack(Results, 1, Results.n)
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

--// [ROBUST] Хук акторов + подробный лог в консоль (F9).
--// Что изменено против исходника:
--//  * run_on_actor на Delta при отказе возвращает false, а pcall — true;
--//    старая версия считала это успехом и молча ничего не хукала;
--//  * getactorstates() может вернуть userdata/proxy без поля IsActorState —
--//    старая версия падала на индексации и роняла весь LoadHooks;
--//  * код актора обёрнут в xpcall: ошибка внутри VM актора теперь видна
--//    в консоли и в файле SigmaSpy_actor_error.txt (по каналу она не приходит);
--//  * имя актора передаётся внутрь кода, поэтому в консоли видно, кто подключился;
--//  * дедупликация по полному имени: Delta отдаёт новую обёртку Instance на
--//    каждый getactors(), сравнение по ссылке запускало один актор 8 раз.
local ActorErrorFile = "SigmaSpy_actor_error.txt"

local ActorCodeWrapper = [==[
pcall(function() __SigmaSpyActorName = %s end)
local __sigmaOk, __sigmaErr = xpcall(function()
%s
end, function(__e)
	local __tb = ""
	pcall(function() __tb = debug.traceback("", 2) end)
	return tostring(__e) .. "\n" .. tostring(__tb)
end)
if not __sigmaOk then
	local __msg = "[SigmaSpy] actor error:\n" .. tostring(__sigmaErr)
	pcall(print, __msg)
	pcall(function() writefile("SigmaSpy_actor_error.txt", __msg) end)
end
]==]

function Hook:RunOnActors(Code: string, ChannelId: number)
	local Tag = "[SigmaSpy]"

	local function Log(...) print(Tag, ...) end
	local function Warn(...) warn(Tag, ...) end

	if typeof(getactors) ~= "function" or typeof(run_on_actor) ~= "function" then
		Warn("actors: нет getactors/run_on_actor — акторы пропущены")
		return
	end

	--// файл от прошлого запуска не должен путать диагностику
	pcall(function()
		if typeof(isfile) == "function" and typeof(delfile) == "function" and isfile(ActorErrorFile) then
			delfile(ActorErrorFile)
		end
	end)

	--// Ключ по полному имени, а не по ссылке: Delta отдаёт новый Instance-обёртку
	--// на каждый getactors(), из-за чего один и тот же актор запускался 8 раз.
	local HookedKeys = {}
	local HookedCount = 0
	local Seen = 0
	local Failures = {}

	local function ActorKey(Actor)
		local Ok, Name = pcall(function() return Actor:GetFullName() end)
		if Ok and type(Name) == "string" and #Name > 0 then return Name end
		return tostring(Actor)
	end

	local function TryActor(Actor, Quiet)
		if typeof(Actor) ~= "Instance" or not Actor:IsA("Actor") then return false end

		local Key = ActorKey(Actor)
		if HookedKeys[Key] then return true end
		Seen += 1

		--// имя актора уезжает внутрь кода — в консоли видно, кто подключился
		local Payload = ActorCodeWrapper:format(("%q"):format(Key), Code)

		local Ok, Ret = pcall(run_on_actor, Actor, Payload, ChannelId)
		if Ok and Ret ~= false then
			HookedKeys[Key] = true
			HookedCount += 1
			Log(("actor подключён: %s"):format(Key))
			return true
		end

		local Reason = ("ok=%s ret=%s"):format(tostring(Ok), tostring(Ret))
		Failures[Key] = Reason
		if not Quiet then
			Warn(("actor %s не принял код (%s)"):format(Key, Reason))
		end
		return false
	end

	--// 1) акторы из игры — у Delta только они имеют готовую VM
	local OkGet, Actors = pcall(getactors)
	local GameActors = (OkGet and typeof(Actors) == "table") and Actors or {}
	Log(("actors: getactors = %d"):format(#GameActors))
	for _, Actor in next, GameActors do
		TryActor(Actor, false)
	end

	--// удалённые акторы почти всегда уже без VM — пробуем тихо
	if typeof(getdeletedactors) == "function" then
		local OkDel, Deleted = pcall(getdeletedactors)
		if OkDel and typeof(Deleted) == "table" and #Deleted > 0 then
			Log(("actors: getdeletedactors = %d (пробую тихо)"):format(#Deleted))
			for _, Actor in next, Deleted do
				TryActor(Actor, true)
			end
		end
	end

	--// 2) если классический путь не дал ничего — состояния акторов
	if HookedCount == 0 and typeof(getactorstates) == "function" then
		local OkStates, States = pcall(getactorstates)
		if OkStates and typeof(States) == "table" then
			Log(("actors: getactorstates = %d"):format(#States))
			local StatePayload = ActorCodeWrapper:format('"actor state"', Code)
			for _, State in next, States do
				if type(State) == "thread" then
					if typeof(run_on_thread) == "function" then
						local OkRun, RetRun = pcall(run_on_thread, State, StatePayload, ChannelId)
						Log(("actor state (thread): run_on_thread ok=%s ret=%s")
							:format(tostring(OkRun), tostring(RetRun)))
					end
					continue
				end

				--// поле может отсутствовать (userdata/proxy) — проверяем безопасно
				local OkIs, IsState = pcall(function() return State.IsActorState end)
				if OkIs and IsState then
					local OkExec, RetExec = pcall(function()
						return State:Execute(StatePayload, ChannelId, State:GetActors()[1])
					end)
					Log(("actor state: Execute ok=%s ret=%s")
						:format(tostring(OkExec), tostring(RetExec)))
				end
			end
		else
			Log(("actors: getactorstates не сработал (%s)"):format(tostring(States)))
		end
	end

	--// 3) актор мог получить VM позже — повторная проверка, без повторов запуска
	if HookedCount == 0 then
		task.spawn(function()
			for _ = 1, 10 do
				task.wait(1)
				if HookedCount > 0 then break end
				local OkNow, Current = pcall(getactors)
				if OkNow and typeof(Current) == "table" then
					for _, Actor in next, Current do
						TryActor(Actor, true)
					end
				end
			end

			if HookedCount == 0 then
				Warn("actors: за 10 секунд ни один актор не принял код")
				for Name, Reason in next, Failures do
					Warn(("  %s: %s"):format(Name, Reason))
				end
			else
				Log(("actors: итог — подключено %d"):format(HookedCount))
			end
		end)
	end

	--// 4) новые акторы после запуска (на Delta on_actor_state_created = nil)
	game.DescendantAdded:Connect(function(Instance)
		if typeof(Instance) == "Instance" and Instance:IsA("Actor") then
			task.delay(0.5, function()
				TryActor(Instance, true)
			end)
		end
	end)

	--// 5) ошибки из VM актора по каналу не приходят — читаем файл
	if typeof(isfile) == "function" and typeof(readfile) == "function" then
		task.delay(2, function()
			local OkFile, Content = pcall(function()
				if isfile(ActorErrorFile) then return readfile(ActorErrorFile) end
			end)
			if OkFile and Content and #Content > 0 then
				Warn("ошибка внутри актора:\n" .. Content)
				pcall(function() delfile(ActorErrorFile) end)
			end
		end)
	end

	if HookedCount > 0 then
		Log(("actors: подключено сразу %d"):format(HookedCount))
	elseif Seen == 0 then
		Log("actors: в игре нет акторов с VM — нечего хукать")
	else
		Warn(("actors: сразу не принял ни один из %d, жду появления VM"):format(Seen))
	end
end

local ActorProbeLogged = 0
local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	local Extra = Process.ExtraData
	local IsActorVM = type(Extra) == "table" and Extra.IsActor == true

	--// для актора: класс remote'а и пропустит ли его Process
	local ClassName, IsRemoteClass
	if IsActorVM then
		local OkClass, Class = pcall(function() return self.ClassName end)
		ClassName = OkClass and tostring(Class) or "?"
		IsRemoteClass = ClassName == "RemoteEvent"
			or ClassName == "RemoteFunction"
			or ClassName == "UnreliableRemoteEvent"
	end

	local Allowed = false
	if IsRemoteClass then
		local OkAllowed, Value = pcall(Process.RemoteAllowed, Process, self, "Send", Method)
		Allowed = OkAllowed and Value == true
	end

	local Caller = checkcaller()
	local Identity = getthreadidentity()

	local Data = {
		Method = Method,
		OriginalFunc = OriginalFunc,
		MetaMethod = MetaMethod,
		TransferType = "Send",
		--// [FIX] В VM актора checkcaller() обычно true, и тогда лог получал
		--// IsExploit = true. При выключенном "Log exploit calls" UI выбрасывал
		--// такие записи молча — remote'ы актора просто не появлялись.
		--// Вызовы игрового скрипта актора эксплойтными не являются.
		IsExploit = IsActorVM and false or Caller
	}

	local Result
	if IsActorVM then
		--// ошибку внутри Process не роняем в игровой тред: пишем в консоль и
		--// пропускаем вызов дальше, чтобы игра работала как без хука
		local Ok, Value = pcall(Process.ProcessRemote, Process, Data, self, ...)
		if Ok then
			Result = Value
		else
			pcall(print, ("[SigmaSpy] actor: ProcessRemote ошибка — %s (%s:%s)")
				:format(tostring(Value), tostring(self), tostring(Method)))
		end
	else
		Result = Process:ProcessRemote(Data, self, ...)
	end

	--// первые реальные remote'ы из актора: класс, метод, фильтр, checkcaller
	--// (при caller=true Ui:CreateLog выбрасывает лог как «exploit»)
	if IsRemoteClass and ActorProbeLogged < 3 then
		ActorProbeLogged += 1
		pcall(print, ("[SigmaSpy] actor: remote #%d — %s (%s:%s) allowed=%s caller=%s identity=%s")
			:format(
				ActorProbeLogged,
				tostring(self),
				ClassName,
				tostring(Method),
				tostring(Allowed),
				tostring(Caller),
				tostring(Identity)
			))

		--// отдельная строка в консоль через канал: если она видна, а записи в
		--// списке нет — лог потерялся при передаче батча, а не в хуке
		if Allowed then
			pcall(function()
				Communication:ConsolePrint(
					("[actor] raw %s:%s"):format(tostring(self), tostring(Method))
				)
			end)
		end
	end

	return Result
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

	self.HookMode = UseOth and "oth" or "namecall"

	--// в акторе Configuration раньше терялась (CompileModule выбрасывал таблицы)
	if Process and Process.ExtraData and Process.ExtraData.IsActor then
		pcall(print, ("[SigmaSpy] actor: BeginHooks, Configuration=%s, UseOthHooks=%s, режим=%s")
			:format(
				tostring(Configuration ~= nil),
				tostring(Configuration and Configuration.UseOthHooks),
				self.HookMode
			))
	end

	local OriginalNameCall
	local Intercepted = 0

	if UseOth then
		local OthOriginal
		OthOriginal = oth.hook(getrawmetatable(game).__namecall, function(self, ...)
			local Method = getnamecallmethod()
			Intercepted += 1

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
			Intercepted += 1
			return ProcessRemote(OriginalNameCall, "__namecall", self, Method, ...)
		end)
	end

	--// Диагностика для актора: сколько вообще namecall'ов прошло через его VM.
	--// 0 = актор ничего не вызывает (тогда и remote'ов в UI быть не может).
	local IsActorVM = Process ~= nil
		and Process.ExtraData ~= nil
		and Process.ExtraData.IsActor == true

	if IsActorVM then
		--// Самопроверка сразу после установки: делаем заведомый namecall
		--// (game:GetService) и смотрим, вырос ли счётчик. Не вырос — хук в
		--// этой VM актора не встал, и любой remote пройдёт мимо логгера.
		--// Это печатается синхронно, без task.delay (таймеры в actor VM
		--// могут не тикать, поэтому раньше строка «за 8с» не появлялась).
		local Before = Intercepted
		pcall(function() game:GetService("Players") end)
		local After = Intercepted
		pcall(print, ("[SigmaSpy] actor: самопроверка хука = %s (namecall %d -> %d, __namecall=%s)")
			:format(
				After > Before and "OK" or "FAIL",
				Before,
				After,
				tostring(typeof(getrawmetatable(game).__namecall))
			))

		task.delay(8, function()
			local Who = "actor"
			pcall(function()
				local Name = __SigmaSpyActorName
				if type(Name) == "string" and #Name > 0 then Who = Name end
			end)
			pcall(print, ("[SigmaSpy] actor: перехвачено namecall за 8с = %d (%s)")
				:format(Intercepted, Who))
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
	--// [SAFE] Files:MakeActorScript подставляет ChannelId числом, но если код
	--// соберут иначе (конкатенацией с таблицей) — разворачиваем, чтобы не было
	--// get_comm_channel(number expected, got table)
	if type(ChannelId) == "table" then
		ChannelId = ChannelId[1]
	end

	--// [DEBUG] печатается из VM актора — сразу видно, дошёл ли код до BeginService
	local IsActor = type(ExtraData) == "table" and ExtraData.IsActor == true

	--// имя актора передаёт обёртка RunOnActors (глобал ставится внутри той же VM)
	local Who = "actor"
	if IsActor then
		local OkWho, Name = pcall(function() return __SigmaSpyActorName end)
		if OkWho and type(Name) == "string" and #Name > 0 then
			Who = Name
		end
	end

	if IsActor then
		pcall(print, ("[SigmaSpy] actor: BeginService старт, channel = %s (%s)")
			:format(tostring(ChannelId), Who))
	end

	--// Librareis
	local ReturnSpoofs = Libraries.ReturnSpoofs
	local ProcessLib = Libraries.Process
	local Communication = Libraries.Communication
	local Generation = Libraries.Generation
	local Config = Libraries.Config

	--// [FIX] В акторе Configuration раньше отсутствовала: InitData.Modules
	--// собирается вручную и поля Configuration в нём не было, а в Libraries
	--// таблицы выбрасывались генератором. Из-за этого Hook:BeginHooks в акторе
	--// шёл другим режимом (oth), и remote'ы актора не попадали в лог.
	local Configuration = Libraries.Configuration or Configuration
	if Configuration and IsActor then
		pcall(print, ("[SigmaSpy] actor: Configuration получена (%s), UseOthHooks=%s")
			:format(tostring(Configuration), tostring(Configuration.UseOthHooks)))
	end

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
			Configuration = Configuration,
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
	local OkChannel, Channel, IsWrapped = pcall(Communication.GetCommChannel, Communication, ChannelId)
	if IsActor then
		pcall(print, ("[SigmaSpy] actor: GetCommChannel ok=%s channel=%s wrapped=%s")
			:format(tostring(OkChannel), tostring(Channel), tostring(IsWrapped)))
	end
	if not OkChannel or Channel == nil then
		error(("[SigmaSpy] actor: канал %s не получен: %s"):format(tostring(ChannelId), tostring(Channel)))
	end
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

			--// в консоли видно, что актор реально доехал до установки хуков
			local Message = IsActor
				and ("[actor] Hooks loaded — " .. Who .. " (режим: " .. tostring(self.HookMode) .. ")")
				or "Hooks loaded"
			Communication:ConsolePrint(Message)
		end
	})
	
	--// Process configuration
	ProcessLib:SetChannel(Channel, IsWrapped)
	ProcessLib:SetExtraData(ExtraData)

	--// Hook configuration
	self:Init(InitData)

	if IsActor then
		pcall(print, ("[SigmaSpy] actor: Init готов, отправляю 'Actor connected!' (%s)"):format(Who))
		Communication:ConsolePrint("Actor connected! — " .. Who)
	else
		print("[SigmaSpy] main: BeginService готов, канал = " .. tostring(ChannelId))
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
	print(("[SigmaSpy] LoadHooks: старт, канал = %s, ActorCode = %d байт")
		:format(tostring(ChannelId), #tostring(ActorCode)))
	self:BypassAdonis()
	print("[SigmaSpy] LoadHooks: Adonis bypass ок")
	self:LoadMetaHooks(ActorCode, ChannelId)
	print("[SigmaSpy] LoadHooks: мета-хуки и main BeginService ок")
	self:LoadReceiveHooks()
	print("[SigmaSpy] LoadHooks: приём хуков подключён, жду BeginHooks")
end

return Hook
