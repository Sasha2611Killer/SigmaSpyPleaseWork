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
	--// Идемпотентность по модулю: BeginHooks может сработать дважды.
	if self._PatchedFunctions then
		print("[Sigma][Patch] повторный вызов PatchFunctions — пропускаю (хуки уже стоят)")
		return
	end
	self._PatchedFunctions = true

	--// [FIX 2026-11-19] Настоящие pcall/getfenv — ДО любых хуков.
	--// Весь код ниже идёт только через них: если исполнитель поставит
	--// «полуживой» хук, наша собственная логика не упадёт вместе с ним.
	local RealPcall = pcall
	local RealGetfenv = getfenv

	--// Спасательный круг для Ui/Process: настоящий pcall виден снаружи.
	--// Ui:ProcessLogQueue зовёт Hook.RealPcall, если он есть.
	self.RealPcall = RealPcall

	local NoPatch = (Configuration and Configuration.NoFunctionPatching)
		or (Config and Config.NoFunctionPatching)
	if NoPatch then
		print("[Sigma][Patch] SKIPPED: NoFunctionPatching = true")
		return
	end

	--// [FIX 2026-11-19] МАРКЕР В НАСТОЯЩЕМ ГЛОБАЛЬНОМ ENV (getfenv(0)).
	--// getgenv() на Velocity не сохраняется между вызовами, а getfenv(0) — да.
	--// Без маркера вторая копия (актор / повторный запуск) ставила хук на
	--// уже захуканный pcall: двойные вызовы и лишние кадры в getfenv.
	local GlobalEnv = nil
	do
		local OkEnv, Env = RealPcall(RealGetfenv, 0)
		if OkEnv and type(Env) == "table" then
			GlobalEnv = Env
		end
	end
	if GlobalEnv and rawget(GlobalEnv, "__SigmaFunctionPatched") then
		print("[Sigma][Patch] pcall уже захукан в этом Lua-state — пропускаю")
		return
	end

	local Unpack = table.unpack or unpack

	local function SafeUnpack(Packed)
		local Amount = Packed.n
		if type(Amount) ~= "number" then
			Amount = #Packed
		end
		return Unpack(Packed, 1, Amount)
	end

	--// [FIX 2026-11-19] ГЛАВНАЯ СТРАХОВКА.
	--// Раньше хук звал OldFunc(Func, ...) напрямую. Если clonefunction(pcall)
	--// на исполнителе не защищает Lua-ошибки (ровно так ведёт себя Velocity),
	--// ошибка из Func вылетала наружу: «ElementStyle is not a valid member
	--// of TextButton "Button"» из ReGui убивал очередь логов и клиент.
	--// Теперь вызов «оригинала» ВСЕГДА обёрнут в настоящий pcall — ошибка
	--// физически не может покинуть хук.
	local HooksFired = 0

	local function PcallCallback(OldFunc, Func, ...)
		HooksFired += 1

		--// Outer[1] — поймал ли ошибку НАШ pcall
		--// Outer[2] — ok от OldFunc, Outer[3] — первое значение или ошибка
		local Outer = table.pack(RealPcall(OldFunc, Func, ...))

		if not Outer[1] then
			--// OldFunc сам выбросил — значит это не pcall. Эмулируем.
			return false, Outer[2]
		end

		--// Оригинальная фича: чистим сообщение «C stack overflow» (x196).
		if Outer[2] == false and type(Outer[3]) == "string" then
			local Error = Outer[3]

			if type(Func) == "function"
				and not iscclosure(Func)
				and string.find(Error, "C stack overflow", 1, true)
			then
				local Caller, Line = string.match(Error, "^(.-):(%d+): ")

				if Caller and Process then
					local Count = Process:CountMatches(Error, Caller)

					if Count == 196 then
						local Prefix = Caller .. ":" .. Line .. ": "

						if string.sub(Error, 1, #Prefix) == Prefix then
							Outer[3] = Caller .. string.sub(Error, #Prefix + 1)
						end
					end
				end
			end
		end

		return Unpack(Outer, 2, Outer.n)
	end

	--// [FIX 2026-11-19] getfenv-патч УБРАН.
	--// Сдвиг уровня (+2) зависит от того, сколько кадров добавляет
	--// hookfunction конкретного исполнителя; надёжно проверить это нельзя.
	--// Ошибка на единицу = чужие env у всех библиотек (ReGui, парсер) —
	--// ровно тот класс поломок, который мы лечим.

	--// Безопасный clonefunction: если копия не получена, установку НЕ
	--// делаем вообще (иначе Original == Target и хук зовёт сам себя).
	local _hookfunction
	do
		local OkHook, Hooked = RealPcall(clonefunction, hookfunction)
		_hookfunction = (OkHook and type(Hooked) == "function") and Hooked or hookfunction
	end

	local Hooks = {}

	local function Install(Name, Target, Callback)
		local OkClone, Original = RealPcall(clonefunction, Target)
		if not OkClone or type(Original) ~= "function" or Original == Target then
			print("[Sigma][Patch]  hook:", Name, "-> SKIP: clonefunction не дал копию")
			return false
		end

		local OkWrap, Wrapped = RealPcall(newcclosure, Callback)
		if not OkWrap or type(Wrapped) ~= "function" then
			Wrapped = Callback
		end

		local Ok, Err = RealPcall(function()
			_hookfunction(Target, function(...)
				return Wrapped(Original, ...)
			end)
		end)

		Hooks[Name] = {
			Target = Target,
			Original = Original,
		}

		print("[Sigma][Patch]  hook:", Name, "->", Ok and "ok" or ("ERROR: " .. tostring(Err)))

		return Ok, Original
	end

	local PcallOk, PcallOriginal = Install("pcall", pcall, PcallCallback)

	if not PcallOriginal then
		print("[Sigma][Patch] pcall не захукан — function patches не применены")
		return
	end

	--// ── Самопроверка ────────────────────────────────────────────────────
	--// Всё гоняем через RealPcall: диагностика не должна падать сама.
	local Checks = {}

	local function Report(Name, Ok, Detail)
		Checks[Name] = Ok and true or false

		local Line = string.format("[Sigma][Patch]  %-18s %s", Name, Ok and "OK" or "FAIL")
		if Detail ~= nil then
			Line ..= " (" .. tostring(Detail) .. ")"
		end
		print(Line)
	end

	--// 1. Хук вообще вызывается? (иначе он «тихо не встал»)
	local HitsBefore = HooksFired
	RealPcall(function()
		pcall(function() return 1 end)
	end)
	local PcallLive = HooksFired > HitsBefore
	Report("pcall live", PcallLive, string.format("hits=%d", HooksFired - HitsBefore))

	--// 2. Несколько возвращаемых значений
	local OkAmount, Amount = RealPcall(function()
		return select("#", pcall(function() return 1, 2, 3 end))
	end)
	Report("pcall returns", OkAmount and Amount == 4, Amount)

	--// 3. Ошибка из Lua-функции (на этом и ломался Velocity)
	local OkLua, LuaOk, LuaErr = RealPcall(function()
		return pcall(function() error("SIGMA_LUA_PROBE") end)
	end)
	Report("pcall lua error", OkLua and LuaOk == false
		and type(LuaErr) == "string"
		and string.find(LuaErr, "SIGMA_LUA_PROBE", 1, true) ~= nil, LuaErr)

	--// 4. Ошибка движка при записи свойства (ElementStyle/AutoSize из ReGui)
	local OkNative, NativeOk, NativeErr = RealPcall(function()
		local Probe = Instance.new("Frame")
		return pcall(function()
			Probe.ElementStyle = "SIGMA_NATIVE_PROBE"
		end)
	end)
	Report("pcall native error", OkNative and NativeOk == false
		and type(NativeErr) == "string"
		and string.find(NativeErr, "ElementStyle", 1, true) ~= nil, NativeErr)

	--// 5. Ошибка из C-функции
	local OkC, COk, CErr = RealPcall(function()
		return pcall(error, "SIGMA_C_PROBE")
	end)
	Report("pcall C error", OkC and COk == false and CErr == "SIGMA_C_PROBE", CErr)

	--// 6. Вложенный pcall
	local OkNest, NestA, NestB, NestErr = RealPcall(function()
		return pcall(function()
			return pcall(function() error("SIGMA_NESTED_PROBE") end)
		end)
	end)
	Report("pcall nested", OkNest and NestA == true and NestB == false
		and type(NestErr) == "string"
		and string.find(NestErr, "SIGMA_NESTED_PROBE", 1, true) ~= nil, NestErr)

	--// 7. Самое важное: исключение не выходит наружу из pcall
	local Escaped = RealPcall(function()
		pcall(function() error("SIGMA_ESCAPE_PROBE") end)
	end)
	Report("pcall no escape", Escaped == true,
		Escaped == true and nil or "ошибка вышла наружу")

	local Healthy = Checks["pcall returns"]
		and Checks["pcall lua error"]
		and Checks["pcall native error"]
		and Checks["pcall C error"]
		and Checks["pcall nested"]
		and Checks["pcall no escape"]

	--// ── Вердикт ─────────────────────────────────────────────────────────
	if PcallLive and not Healthy then
		print("[Sigma][Patch] ROLLBACK: pcall-хук ломает защиту — снимаю")

		RealPcall(_hookfunction, Hooks.pcall.Target, Hooks.pcall.Original)

		--// Вторая страховка: даже если hookfunction не умеет снимать хук
		--// с C-функции, вернём рабочую ссылку в глобальный env.
		if GlobalEnv then
			RealPcall(function()
				GlobalEnv.pcall = Hooks.pcall.Original
			end)
		end

		print("[Sigma][Patch] pcall восстановлен, function patches отключены")
		return
	end

	if not PcallLive then
		print("[Sigma][Patch] pcall-хук не активен (hookfunction не сработал на C-функции)")
		print("[Sigma][Patch] ничего не изменено — клиент в безопасности")
		return
	end

	--// Всё хорошо: помечаем Lua-state, чтобы повторный запуск не хукал хук.
	if GlobalEnv then
		RealPcall(function()
			GlobalEnv.__SigmaFunctionPatched = true
			GlobalEnv.__SigmaRealPcall = Hooks.pcall.Original
		end)
	end

	print(string.format(
		"[Sigma][Patch] function patches активны | executor=%s | live=%s",
		tostring(identifyexecutor and identifyexecutor() or (getexecutorname and getexecutorname()) or "?"),
		tostring(PcallLive)
	))
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

	--// Cobalt-style ретрай: run_on_actor может падать на неинициализированных
	--// акторах (LuaStateProxy) — повторяем до 10 раз с паузой
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

	--// Современная библиотека: getactorstates может возвращать НЕ Actor-инстансы,
	--// а состояния — треды (run_on_thread) или LuaStateProxy (:Execute).
	--// Классический getactors() такие акторы не видит.
	local SkipClassic = false
	if typeof(getactorstates) == "function" then
		local Ok, States = pcall(getactorstates)
		if Ok and type(States) == "table" then
			local First = next(States)
			if type(First) == "thread" and typeof(run_on_thread) == "function" then
				for _, State in States do
					pcall(run_on_thread, State, Code, ChannelId)
				end
				SkipClassic = true -- состояния захуканы — getactors-проход не нужен
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

	--// Текущие + удалённые (неинициализированные) акторы — как в Cobalt
	if not SkipClassic then
		for _, Category in {getactors(), typeof(getdeletedactors) == "function" and getdeletedactors() or {}} do
			if Category then
				for _, Actor in next, Category do
					HookActor(Actor)
				end
			end
		end
	end

	--// Акторы, созданные ПОЗЖЕ: нативное событие → fallback DescendantAdded.
	--// В старой версии такие акторы вообще не хукались.
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
	--// [FIX 2026-11-19] Идемпотентность: BeginHooks срабатывает дважды,
	--// а повторная установка __namecall = двойные логи и двойная работа
	--// Process:ProcessRemote на каждый вызов.
	if self.OriginalNamecall then
		print("[Sigma][Patch] BeginHooks: __namecall уже стоит — пропускаю")
		return
	end

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
			--// [DIAG] видно, дошёл ли Yes до этого места
			print("[Sigma][Patch] BeginHooks fired, PatchFunctions =", tostring(Config.PatchFunctions))

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
