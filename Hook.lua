--!nolint DeprecatedApi

--[[
	Taking my methods 💖💖
	I love a paster and a skid, puts disgust in my face

	Cobalt-style перехват (v2):
		1) Нативные фильтры executor'а (AllFilter/InstanceTypeFilter/NamecallFilter)
		   -> Lua-колбэк вообще не вызывается для не-ремоутов.
		2) Fallback: rawset + дешёвый Lua-фильтр (class/method lookup).
		3) Бюджет захвата: спам-ремоут не съедает игровой тред.
		4) Метаметод через hookmetamethod (нативный), а не через hookfunction.
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

--// =====================================================================
--// 1) НАТИВНЫЕ ФИЛЬТРЫ EXECUTOR'А (Cobalt: Src/Utils/Hook/Luau.luau)
--// =====================================================================
--// Фильтр отдаётся движку: для нерелевантных вызовов Lua-обработчик
--// НЕ вызывается вообще. Это единственный способ снять нагрузку
--// с хот-пути игры (каждый :Method() в игре идёт через __namecall).
local FilterBase = nil
do
	local Ok, Result = pcall(function()
		local Candidates = {
			{ Key = "All", Value = AllFilter },
			{ Key = "Any", Value = AnyFilter },
			{ Key = "Not", Value = NotFilter },
			{ Key = "Argument", Value = ArgumentFilter },
			{ Key = "InstanceType", Value = InstanceTypeFilter },
			{ Key = "Namecall", Value = NamecallFilter },
		}

		local Found = {}
		for _, Candidate in Candidates do
			local Value = Candidate.Value
			if Value ~= nil and type(Value.new) == "function" then
				Found[Candidate.Key] = Value
			end
		end

		if Found.All and Found.Any and Found.InstanceType and Found.Namecall then
			return Found
		end

		return nil
	end)

	if Ok then
		FilterBase = Result
	end
end

--// Классы исходящих вызовов (зеркалит Cobalt AllowedClassNames)
local OUTGOING_CLASSES = {
	RemoteEvent = true,
	UnreliableRemoteEvent = true,
	RemoteFunction = true,
	BindableEvent = true,
	BindableFunction = true,
}

--// Методы исходящих вызовов (зеркалит Cobalt NamecallMethods)
local OUTGOING_METHODS = {
	FireServer = true,
	fireServer = true,
	InvokeServer = true,
	invokeServer = true,
	Fire = true,
	fire = true,
	Invoke = true,
	invoke = true,
}

--// Базовые методы по классам (fallback, если RemoteClassData неполон)
local DEFAULT_SEND_METHODS = {
	RemoteEvent = { FireServer = true, fireServer = true },
	UnreliableRemoteEvent = { FireServer = true, fireServer = true },
	RemoteFunction = { InvokeServer = true, invokeServer = true },
	BindableEvent = { Fire = true, fire = true },
	BindableFunction = { Invoke = true, invoke = true },
}

--// Lua-side lookup: [ClassName] = { [Method] = true }
local SendMethodLookup = {}

local function BuildSendMethodLookup()
	local Lookup = {}

	for ClassName, Methods in pairs(DEFAULT_SEND_METHODS) do
		Lookup[ClassName] = table.clone(Methods)
	end

	local ClassData = Process and Process.RemoteClassData
	if type(ClassData) == "table" then
		for ClassName, Data in pairs(ClassData) do
			local Send = type(Data) == "table" and Data.Send or nil
			if type(Send) == "table" then
				local Set = Lookup[ClassName] or {}
				for _, Method in pairs(Send) do
					if type(Method) == "string" then
						Set[Method] = true
					end
				end
				Lookup[ClassName] = Set
			end
		end
	end

	SendMethodLookup = Lookup
end

--// Строит нативный фильтр для __namecall (Cobalt: NamecallHookFilter)
local function BuildOutgoingFilter(): any
	if not FilterBase then return nil end

	local Ok, Filter = pcall(function()
		local ClassFilters = {}
		for ClassName in pairs(OUTGOING_CLASSES) do
			table.insert(ClassFilters, FilterBase.InstanceType.new(1, ClassName))
		end

		local MethodFilters = {}
		for Method in pairs(OUTGOING_METHODS) do
			table.insert(MethodFilters, FilterBase.Namecall.new(Method))
		end

		return FilterBase.All.new({
			FilterBase.Any.new(ClassFilters),
			FilterBase.Any.new(MethodFilters),
		})
	end)

	if not Ok then
		FilterBase = nil
		return nil
	end

	return Filter
end

--// =====================================================================
--// 2) БЮДЖЕТ ЗАХВАТА (Cobalt: Log:IsOverSpamThreshold)
--// =====================================================================
--// Спам-ремоут не должен блокировать игровой тред. Логируем не чаще
--// MAX_LOGS_PER_SECOND раз в секунду на ремоут; сам вызов ремоута
--// при этом происходит ВСЕГДА и без задержки.
--// Бюджет захвата — аварийный предохранитель, а не основной механизм.
--// При батчинге канала (InstallChannelBatching) он не нужен: спамный
--// ремоут должен быть виден ПОЛНОСТЬЮ, как в Cobalt.
--// 0 = без ограничений (рекомендуется), 30 = жёсткий лимит.
local MAX_LOGS_PER_SECOND = 0

--// Раздельные бюджеты на Send/Receive: спам исходящих не должен
--// глушить входящие логи того же ремоута (и наоборот).
local CaptureBudgets = {
	Send = { Entries = {}, Count = 0 },
	Receive = { Entries = {}, Count = 0 },
}

local function PruneCaptureBudget(Budget: any, Now: number)
	if Budget.Count < 256 then return end

	for Instance, Entry in pairs(Budget.Entries) do
		if Now - Entry.WindowStart > 5 then
			Budget.Entries[Instance] = nil
			Budget.Count -= 1
		end
	end
end

local function AllowCapture(Kind: string, Instance): boolean
	local Budget = CaptureBudgets[Kind]
	if not Budget then return true end
	if MAX_LOGS_PER_SECOND <= 0 then return true end

	local Now = tick()
	local Entry = Budget.Entries[Instance]

	if not Entry then
		Budget.Entries[Instance] = { Count = 1, WindowStart = Now }
		Budget.Count += 1
		PruneCaptureBudget(Budget, Now)
		return true
	end

	if Now - Entry.WindowStart >= 1 then
		Entry.WindowStart = Now
		Entry.Count = 1
		return true
	end

	Entry.Count += 1
	return Entry.Count <= MAX_LOGS_PER_SECOND
end

--// =====================================================================
--// 3) БАТЧИНГ КАНАЛА (Cobalt: LogNotificationQueue + Heartbeat)
--// =====================================================================
--// ПРОБЛЕМА: Communication:Fire("RemoteData", ...) — СИНХРОННЫЙ вызов
--// (BindableEvent:Fire зовёт обработчики inline). Тяжёлое логирование
--// вставало ПЕРЕД реальным вызовом ремоута:
--//
--//     remote:FireServer(x)
--//       → __namecall хук
--//           → Process:ProcessRemote
--//               → сериализация
--//               → Communication:Fire   ← UI-работа ЗДЕСЬ, синхронно
--//           → OriginalFunc(self, ...)  ← только теперь реальный FireServer
--//
--// СПАМ-РЕМОУТ (100 вызовов/сек) → каждый вызов ждал UI-работу предыдущего
--// → другие ремоуты уходили с задержкой.
--//
--// РЕШЕНИЕ (принцип Cobalt): fire откладывается до конца кадра.
--// Сам вызов ремоута уходит СРАЗУ, UI получает пачку один раз за кадр.
--// Плюс: спамный ремоут виден ПОЛНОСТЬЮ (как в Cobalt) — бюджет не нужен.
--// Батчинг перенесён в Process.new.lua (очередь логов + воркер) —
--// здесь он не нужен и выключен, чтобы не дублировать.
local BATCH_REMOTE_DATA = false

local RemoteDataQueue = {}
local RemoteDataCount = 0

local function InstallChannelBatching(Communication)
	if not BATCH_REMOTE_DATA then return end
	if type(Communication) ~= "table" then return end
	if Communication.__SigmaBatched then return end

	local OriginalFire = Communication.Fire
	if type(OriginalFire) ~= "function" then return end

	Communication.__SigmaBatched = true

	Communication.Fire = function(self, Type, ...)
		--// Только RemoteData батчим — остальные типы как есть
		if Type == "RemoteData" then
			RemoteDataCount += 1
			RemoteDataQueue[RemoteDataCount] = table.pack(self, Type, ...)
			return
		end

		return OriginalFire(self, Type, ...)
	end

	task.spawn(function()
		while true do
			task.wait()

			if RemoteDataCount == 0 then continue end

			local Batch = RemoteDataQueue
			local Count = RemoteDataCount
			RemoteDataQueue = {}
			RemoteDataCount = 0

			for Index = 1, Count do
				local Packed = Batch[Index]
				OriginalFire(table.unpack(Packed, 1, Packed.n))
			end
		end
	end)
end

--// Modules
function Hook:Init(Data)
	Modules = Data.Modules

	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration

	--// Lookup строим после CheckConfig, чтобы не разойтись с конфигом
	BuildSendMethodLookup()
end

--// The callback is expected to return a nil value sometimes which should be ingored
local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
	--// Invoke callback and check for a reponce otherwise ignored
	--// ВАЖНО: именно ~= nil, иначе callback, возвращающий false,
	--// считался бы "без ответа" и вызывалась бы оригинальная функция.
	local ReturnValues = Callback(...)
	if ReturnValues ~= nil then
		--// Unpack
		if not AlwaysTable then
			if type(ReturnValues) == "table" then
				return Process:Unpack(ReturnValues)
			end

			return ReturnValues
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
	if typeof(getthreadidentity) ~= "function" or typeof(setthreadidentity) ~= "function" then
		return Object[Key]
	end

	local identity = getthreadidentity()
	setthreadidentity(8)

	local Success, Returned = pcall(function()
		return Object[Key]
	end)

	setthreadidentity(identity)

	if not Success then
		error(Returned, 0)
	end

	return Returned
end

function Hook:PushConfig(Overwrites)
	Merge(self, Overwrites)
end

--// getrawmetatable
function Hook:ReplaceMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc?
	local Metatable = getrawmetatable(Object)
	if not Metatable then return nil end

	local Original = Metatable[Call]
	if not Original then return nil end

	local OriginalFunc = clonefunction(Original)

	--// Replace function
	setreadonly(Metatable, false)

	local Success, Error = pcall(function()
		Metatable[Call] = newcclosure(function(...)
			return HookMiddle(OriginalFunc, Callback, false, ...)
		end)
	end)

	setreadonly(Metatable, true)

	if not Success then
		error(Error, 0)
	end

	return OriginalFunc
end

--// hookfunction
function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc): UnkFunc?
	if not Func then return nil end

	local OriginalFunc
	local WrappedCallback = newcclosure(Callback)

	--// pcall: некоторые executor'ы кидают ошибку при повторном хуке
	local Ok, Original = pcall(hookfunction, Func, function(...)
		return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
	end)

	if not Ok or not Original then return nil end

	OriginalFunc = clonefunction(Original)
	return OriginalFunc
end

--// hookmetamethod
function Hook:HookMetaCall(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc?
	local Metatable = getrawmetatable(Object)
	if not Metatable then return nil end

	local Unhooked

	Unhooked = self:HookFunction(Metatable[Call], function(...)
		return HookMiddle(Unhooked, Callback, true, ...)
	end)
	return Unhooked
end

--// Cobalt-style: hookmetamethod С НАТИВНЫМ ФИЛЬТРОМ.
--// Фильтр исполняется движком — Lua-колбэк вызывается только для
--// подходящих вызовов (это то, что снимает нагрузку с хот-пути игры).
function Hook:HookMetaMethodFiltered(Object: Instance, Call: string, Callback: MetaFunc, Filter: any): MetaFunc?
	if Filter then
		local Ok, Result = pcall(hookmetamethod, Object, Call, Callback, true, Filter)
		if Ok and Result then
			return Result
		end
	end

	return self:HookMetaMethod(Object, Call, Callback)
end

function Hook:HookMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc?
	local Func = newcclosure(Callback)

	--// Getrawmetatable
	if Config and Config.ReplaceMetaCallFunc then
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
			local IsCClosure = typeof(iscclosure) == "function" and iscclosure(Func)

			if Success == false and type(Error) == "string"
				and not IsCClosure and Error:find("C stack overflow")
			then
				local Tracetable = Error:split(":")
				local Caller, Line = Tracetable[1], Tracetable[2]
				local Count = Caller and Process:CountMatches(Error, Caller) or 0

				if Count == 196 then
					Communication:ConsolePrint(`C stack overflow patched, count was {Count}`)

					--// plain-find вместо gsub: Caller/Line могут содержать
					--// магические для Lua-паттернов символы.
					local Prefix = `{Caller}:{Line}: `
					local StartPos, EndPos = Error:find(Prefix, 1, true)
					if StartPos then
						Responce[2] = Error:sub(1, StartPos - 1) .. Caller .. Error:sub(EndPos + 1)
					end
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
				return {OldFunc(999999, ...)}
			end

			return Responce
		end
	}

	--// Hook each function
	for Func, CallBack in Patches do
		local Original = clonefunction(Func)
		local Wrapped = newcclosure(CallBack)

		local Ok = pcall(function()
			_hookfunction(Func, function(...)
				return Wrapped(Original, ...)
			end)
		end)

		if not Ok then
			continue
		end

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
	if Process and Process.LogConnectionFunctions and Process.LogConnectionFunctions[Function] then return true end

	local Success, Env = pcall(getfenv, Function)
	return Success
		and typeof(Env) == "table"
		and rawget(Env, "__SigmaSpyLogger") == SpyVerificationToken
end

function Hook:RunOnActors(Code: string, ChannelId: number)
	local HasClassic = typeof(getactors) == "function" and typeof(run_on_actor) == "function"
	local HasStates = typeof(getactorstates) == "function"

	if not HasClassic and not HasStates then return end

	--// Cobalt-style ретрай: run_on_actor может падать на неинициализированных
	--// акторах (LuaStateProxy) — повторяем до 10 раз с паузой
	local function HookActor(Actor)
		if not Actor or typeof(Actor) ~= "Instance" then return end

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
	if HasStates then
		local Ok, States = pcall(getactorstates)
		if Ok and type(States) == "table" then
			--// ВАЖНО: next(States) возвращает КЛЮЧ, а не первый элемент.
			--// Для массива это число, из-за чего проверки ниже никогда
			--// не срабатывали. Берём именно значение.
			local First = States[1]
			if First == nil then
				local _, Value = next(States)
				First = Value
			end

			local FirstIsActorState = false
			if type(First) == "userdata" or type(First) == "table" then
				local OkState, IsActorState = pcall(function()
					return First.IsActorState
				end)
				FirstIsActorState = OkState and IsActorState == true
			end

			if type(First) == "thread" and typeof(run_on_thread) == "function" then
				for _, State in States do
					pcall(run_on_thread, State, Code, ChannelId)
				end
				SkipClassic = true -- состояния захуканы — getactors-проход не нужен
			elseif FirstIsActorState then
				local HookedAny = false
				for _, Proxy in States do
					if type(Proxy) ~= "userdata" and type(Proxy) ~= "table" then continue end

					local Ok, IsActorState = pcall(function()
						return Proxy.IsActorState
					end)
					if not (Ok and IsActorState == true) then continue end

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
	if HasClassic and not SkipClassic then
		local Categories = {}

		local OkActors, Actors = pcall(getactors)
		if OkActors and type(Actors) == "table" then
			table.insert(Categories, Actors)
		end

		if typeof(getdeletedactors) == "function" then
			local OkDeleted, Deleted = pcall(getdeletedactors)
			if OkDeleted and type(Deleted) == "table" then
				table.insert(Categories, Deleted)
			end
		end

		for _, Category in Categories do
			for _, Actor in next, Category do
				HookActor(Actor)
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

	if not Func then return end

	--// Remotes will share the same functions
	--// 	For example FireServer will be identical
	--// Addionally, this is for __index calls.
	--// 	A __namecall hook will not detect this
	OriginalFunc = self:HookFunction(Func, function(self, ...)
		--// Check if the Object is allowed
		if not Process:RemoteAllowed(self, "Send", FuncName) then return end

		--// Бюджет захвата: спам-ремоут не должен съедать тред
		if not AllowCapture("Send", self) then
			return OriginalFunc(self, ...)
		end

		--// Process the remote data
		return ProcessRemote(OriginalFunc, "__index", self, FuncName, ...)
	end)
end

function Hook:HookRemoteIndexes()
	local RemoteClassData = Process.RemoteClassData
	for ClassName, Data in RemoteClassData do
		local Send = Data and Data.Send
		local FuncName = type(Send) == "table" and Send[1] or nil

		if FuncName then
			self:HookRemoteTypeIndex(ClassName, FuncName)
		end
	end
end

function Hook:BypassAdonis()
	if typeof(getgc) ~= "function" then return end

	task.spawn(function()
		local Detected, Kill
		local Deadline = os.clock() + 10

		repeat
			local OkGC, GC = pcall(getgc, true)
			if OkGC and type(GC) == "table" then
				for _, v in GC do
					if typeof(v) == "table" then
						local DetectFunc = rawget(v, "Detected")
						local KillFunc = rawget(v, "Kill")

						if typeof(DetectFunc) == "function" and not Detected then
							Detected = DetectFunc
							pcall(hookfunction, Detected, function()
								return true
							end)
						end

						if rawget(v, "Variables") and rawget(v, "Process")
							and typeof(KillFunc) == "function" and not Kill
						then
							Kill = KillFunc
							pcall(hookfunction, Kill, function() end)
						end
					end
				end
			end

			if Detected then break end
			task.wait(0.5)
		until Detected or os.clock() > Deadline

		if not Detected then return end

		local Info = getrenv and getrenv().debug and getrenv().debug.info
		if not Info then return end

		local Old
		local OkHook, Result = pcall(function()
			return hookfunction(Info, newcclosure(function(...)
				local LevelOrFunc = ...
				if LevelOrFunc == Detected then
					return coroutine.yield(coroutine.running())
				end
				return Old(...)
			end))
		end)

		if OkHook then
			Old = Result
		end
	end)
end

function Hook:BeginHooks()
	--// Два режима, переключаются Configuration.UseOthHooks:
	--// true  — oth (отдельный тред): детекторам не виден, но обход
	--//         стека не видит игру → обе кнопки Decompile показывают
	--//         один скрипт (fallback getcallingscript).
	--// false — НАТИВНЫЙ hookmetamethod с фильтром: обработчик на игровом
	--//         треде, полная атрибуция (SourceScript/CallerScript
	--//         различаются), но Lua-колбэк вызывается ТОЛЬКО для
	--//         ремоутов (фильтр исполняет движок).
	--// Оба режима распаковывают результат (Unpack) — без этого игра
	--// получает таблицу вместо значений (зависание камеры).
	local UseOth = typeof(oth) == "table" and typeof(oth.hook) == "function"
		and (not Configuration or Configuration.UseOthHooks ~= false)

	local NamecallOriginal

	if UseOth then
		local Filter = BuildOutgoingFilter()
		local OthOriginal

		local Hooked = pcall(function()
			OthOriginal = oth.hook(getrawmetatable(game).__namecall, function(self, ...)
				local Method = getnamecallmethod()

				--// Бюджет: спам-ремоут не должен блокировать oth-тред
				if not AllowCapture("Send", self) then
					return NamecallOriginal(self, ...)
				end

				local Ok, ReturnValues = pcall(ProcessRemote, NamecallOriginal, "__namecall", self, Method, ...)
				if Ok and ReturnValues ~= nil then
					return Process:Unpack(ReturnValues)
				end

				return NamecallOriginal(self, ...)
			end, Filter)
		end)

		if Hooked and OthOriginal then
			NamecallOriginal = OthOriginal
		else
			UseOth = false
		end
	end

	if not UseOth then
		local Filter = BuildOutgoingFilter()

		--// Общий обработчик для hookmetamethod.
		--// ВАЖНО: hookmetamethod ЗАМЕНЯЕТ метаметод, поэтому оригинал
		--// мы обязаны звать сами (в HookMiddle это делалось автоматом).
		local function NamecallHandler(self, ...)
			local Method = getnamecallmethod()

			--// Второй рубеж (если executor проигнорировал фильтр)
			local Set = SendMethodLookup[self.ClassName]
			if Set and Method ~= nil and Set[Method] then
				--// Бюджет захвата
				if AllowCapture("Send", self) then
					local Result = ProcessRemote(NamecallOriginal, "__namecall", self, Method, ...)

					if Result ~= nil then
						if type(Result) == "table" then
							return Process:Unpack(Result)
						end

						return Result
					end
				end
			end

			--// Не наш вызов (или бюджет исчерпан) — просто оригинал
			return NamecallOriginal(self, ...)
		end

		--// C-closure для маскировки (как в Cobalt). Если newcclosure
		--// недоступен/ломается — остаёмся на обычном клозуре.
		local Handler = NamecallHandler
		if typeof(newcclosure) == "function" then
			local Ok, Result = pcall(newcclosure, NamecallHandler)
			if Ok and Result then
				Handler = Result
			end
		end

		--// Путь 1: нативный hookmetamethod + фильтр (Cobalt).
		--// Фильтр отдаётся движку: для 99% вызовов игры колбэк
		--// вообще не вызывается.
		local Hooked = false
		if Filter then
			local Ok, Result = pcall(function()
				return hookmetamethod(game, "__namecall", Handler, true, Filter)
			end)

			if Ok and Result then
				Hooked = true
				NamecallOriginal = Result
			end
		end

		--// Путь 2 (fallback): hookmetamethod без фильтра
		if not Hooked then
			local Ok, Result = pcall(function()
				return hookmetamethod(game, "__namecall", Handler)
			end)

			if Ok and Result then
				Hooked = true
				NamecallOriginal = Result
			end
		end

		--// Путь 3 (last resort): rawset в метамодель
		if not Hooked then
			NamecallOriginal = self:ReplaceMetaMethod(game, "__namecall", function(self, ...)
				local Method = getnamecallmethod()

				local Set = SendMethodLookup[self.ClassName]
				if not Set or Method == nil or not Set[Method] then
					return nil
				end

				if not AllowCapture("Send", self) then
					return nil
				end

				return ProcessRemote(NamecallOriginal, "__namecall", self, Method, ...)
			end)
		end
	end

	if not NamecallOriginal then return end

	Merge(self, {
		OriginalNamecall = NamecallOriginal,
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
	local HookSuccess, Original = pcall(self.HookFunction, self, Function, Callback)
	if HookSuccess and Original then return end

	--// Replace callback function otherwise (скрыт из стека, Cobalt-style)
	local Detour = HideFromStack(function(...)
		return HookMiddle(Function, Callback, false, ...)
	end)

	--// Cobalt-style: присвоение OnClientInvoke под identity 2 и env
	--// оригинального колбэка — игровые __newindex-детекты видят "свой"
	--// вызов (checkcaller() == false), а не executor.
	local OriginalEnv = {}
	pcall(function()
		local Env = getfenv(Function)
		if type(Env) == "table" then
			OriginalEnv = Env
		end
	end)
	local OriginalScript = rawget(OriginalEnv, "script")
	local Trampoline = trampoline_call or (typeof(syn) == "table" and syn.trampoline_call) or nil

	local Assigned = false
	if Trampoline then
		Assigned = pcall(Trampoline, function()
			Remote[Method] = Detour
		end, {}, {
			env = OriginalEnv,
			script = OriginalScript,
			identity = 2,
		})
	end

	if not Assigned then
		task.spawn(function()
			pcall(function()
				if typeof(setthreadidentity) == "function" then
					setthreadidentity(2)
				end
				if typeof(setfenv) == "function" then
					setfenv(0, OriginalEnv)
				end
				Remote[Method] = Detour
			end)
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
		--// Бюджет захвата: спам-ремоут не должен съедать тред.
		--// nil = "не логировать". Для OnClientInvoke это безопасно:
		--// HookMiddle вызовет оригинальный колбэк.
		if not AllowCapture("Receive", Remote) then
			return nil
		end

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

	--// Cobalt-style батчинг канала: fire откладывается до конца кадра,
	--// реальный вызов ремоута уходит сразу (см. InstallChannelBatching)
	pcall(InstallChannelBatching, Communication)

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
