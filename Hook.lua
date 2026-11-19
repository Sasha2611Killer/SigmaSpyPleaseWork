--!nolint DeprecatedApi

--[[
	Taking my methods 💖💖
	I love a paster and a skid, puts disgust in my face
]]

local Hook = {
	OriginalNamecall = nil,
	OriginalIndex = nil,
	PreviousFunctions = {},
	--// [DIAG 2026-11-19] счётчики для проверки "чей VM ловит вызов"
	NamecallHits = 0,
	ProbeHits = 0,
	WatchProbe = false,
	HookKind = nil,
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

	--// [FIX 2026-11-19] Настоящий pcall — НЕ ХУКАЕМ его.
	local RealPcall = pcall
	local RealGetfenv = getfenv
	self.RealPcall = RealPcall
	self.RealGetfenv = RealGetfenv

	local NoPatch = (Configuration and Configuration.NoFunctionPatching)
		or (Config and Config.NoFunctionPatching)
	if NoPatch then
		print("[Sigma][Patch] SKIPPED: NoFunctionPatching = true")
		return
	end

	local GlobalEnv = nil
	do
		local OkEnv, Env = RealPcall(RealGetfenv, 0)
		if OkEnv and type(Env) == "table" then
			GlobalEnv = Env
		end
	end

	if GlobalEnv and rawget(GlobalEnv, "__SigmaFunctionPatched") then
		print("[Sigma][Patch] function patches уже стоят в этом Lua-state — пропускаю")
		return
	end

	local Unpack = table.unpack or unpack
	local HooksFired = 0

	--// [FIX 2026-11-19] ПОЧЕМУ НЕ hookfunction.
	--// Velocity на hookfunction(pcall, ...) сначала применяет детур,
	--// а потом бросает «ERROR: nil». Откат невозможен: любой сохранённый
	--// pcall (в т.ч. наш RealPcall) начинает указывать на хук → хук зовёт
	--// сам себя → C stack overflow → клиент кирпичится до реджойна.
	--// Поэтому builtin pcall остаётся нетронутым, а в глобальный env
	--// кладётся обёртка. Откат = одно присваивание.
	--// getfenv — по той же причине: только обёртка в env, без hookfunction.

	local function PatchMessage(Results, Func)
		local Error = Results[2]

		if type(Func) ~= "function" or iscclosure(Func) then return end
		if not string.find(Error, "C stack overflow", 1, true) then return end

		local Caller, Line = string.match(Error, "^(.-):(%d+): ")
		if not Caller then return end

		--// Раньше тут был gmatch по Caller как по паттерну — путь скрипта
		--// со спецсимволами ронял хук изнутри. Теперь только plain find.
		local Count, Start = 0, 1
		while true do
			local Found = string.find(Error, Caller, Start, true)
			if not Found then break end
			Count += 1
			Start = Found + 1
		end

		if Count ~= 196 then return end

		local Prefix = Caller .. ":" .. Line .. ": "
		if string.sub(Error, 1, #Prefix) ~= Prefix then return end

		Results[2] = Caller .. string.sub(Error, #Prefix + 1)
	end

	local function PcallWrapper(Func, ...)
		HooksFired += 1

		--// Настоящий pcall: ловит И C-ошибки, И Lua-ошибки, И ошибки
		--// движка. Наружу ничего не выйдет ни при каких условиях.
		local Results = table.pack(RealPcall(Func, ...))

		if Results[1] == false and type(Results[2]) == "string" then
			--// Патч сообщения не должен ломать сам pcall
			RealPcall(PatchMessage, Results, Func)
		end

		return Unpack(Results, 1, Results.n)
	end

	--// [FIX 2026-11-19] БЕЗ newcclosure.
	--// Проверено на Velocity: внутри newcclosure pcall перестаёт ловить
	--// ошибки Lua-функций (C-ошибки ловит: «pcall C error OK», а
	--// «pcall lua error FAIL»). Именно поэтому старый хук-обёртка
	--// newcclosure(...) терял защиту и ReGui-ошибки вылетали наружу.
	--// Обычная Lua-обёртка ведёт себя предсказуемо.
	local Wrapped = PcallWrapper

	--// Куда класть обёртку: настоящий глобальный env + env модуля
	--// (у некоторых загрузчиков это разные таблицы).
	local Targets = {}
	do
		local Seen = {}
		local OkModuleEnv, ModuleEnv = RealPcall(RealGetfenv, 1)

		for _, Env in next, {GlobalEnv, ModuleEnv} do
			if type(Env) == "table" and not Seen[Env] then
				Seen[Env] = true
				Targets[#Targets + 1] = Env
			end
		end
	end

	--// ── getfenv: ENV-escape защита (обычная Lua-обёртка) ────────────────
	--// [FIX 2026-11-19] БЕЗ hookfunction — как и pcall.
	--// Probe на Velocity подтвердил: обёртка со сдвигом +1 отдаёт ровно
	--// тот же env, что и настоящий getfenv, для уровней 1/2/0 и функции.
	--// Смысл: чужой скрипт не должен получить окружение исполнителя —
	--// там hookfunction, getgc, getrawmetatable и прочие маркеры.
	local GetfenvCalls = 0
	local EnvBlocked = 0
	local CheckCaller = (typeof(checkcaller) == "function") and checkcaller or nil

	--// КЛЮЧЕВОЕ: checkcaller должен возвращать true в НАШЕМ же потоке.
	--// Если исполнитель так не умеет — блокировка выключена целиком
	--// (fail-open), иначе мы заблокировали бы собственный env.
	local CanCheckCaller = false
	if CheckCaller then
		local OkCaller, Caller = RealPcall(CheckCaller)
		CanCheckCaller = OkCaller and Caller == true

		--// Второй замер — из loadstring-чанка (так грузятся ReGui/Ui).
		--// Если там checkcaller уже не наш, блокировать нельзя:
		--// мы бы роняли свои же библиотеки.
		if CanCheckCaller then
			local OkLoad, Chunk = RealPcall(loadstring,
				"return (typeof(checkcaller) == 'function') and checkcaller() == true")

			if OkLoad and type(Chunk) == "function" then
				local OkRun, IsOurs = RealPcall(Chunk)
				CanCheckCaller = OkRun and IsOurs == true
			else
				CanCheckCaller = false
			end
		end
	end

	local function IsExecutorEnv(Value)
		if type(Value) ~= "table" then return false end

		for _, Env in next, Targets do
			if Env == Value then return true end
		end

		return false
	end

	local function GetfenvWrapper(Target)
		GetfenvCalls += 1

		--// getfenv() без аргумента = уровень 1
		if Target == nil then Target = 1 end

		--// 0 = глобальное окружение; кадры обёртки тут не при чём
		if Target == 0 then
			return RealGetfenv(0)
		end

		local ENV
		if type(Target) == "number" then
			--// Заведомо невозможные уровни отбиваем сами: иначе настоящий
			--// getfenv бросит ошибку со ссылкой на наш чанк (утечка).
			if Target < 0 or Target > 250 then
				error("bad argument #1 to 'getfenv' (invalid level)", 2)
			end

			--// +1: один кадр стека — сама обёртка
			ENV = RealGetfenv(Target + 1)
		elseif type(Target) == "function" then
			--// функция — сдвиг не нужен
			ENV = RealGetfenv(Target)
		else
			error("bad argument #1 to 'getfenv' (number expected, got "
				.. type(Target) .. ")", 2)
		end

		if not IsExecutorEnv(ENV) then
			return ENV
		end

		--// Своим отдаём, чужим — нет.
		local IsOurs = true
		if CanCheckCaller then
			local OkCaller, Caller = RealPcall(CheckCaller)
			IsOurs = OkCaller and Caller == true
		end

		if not IsOurs then
			--// Запасной признак: наш колбэк, вызванный игровым потоком,
			--// живёт в окружении исполнителя — его не блокируем.
			--// level 2 = тот, кто позвал обёртку (level 1 — она сама).
			IsOurs = IsExecutorEnv(RealGetfenv(2))
		end

		if IsOurs then
			return ENV
		end

		EnvBlocked += 1

		--// Нативный текст, но без утечки имени нашего чанка:
		--// level 2 = тот, кто звал getfenv.
		error("bad argument #1 to 'getfenv' (invalid level)", 2)
	end

	local Previous = {}

	--// env с защищённым __newindex не должен ронять установку,
	--// поэтому каждое присваивание — отдельный pcall.
	for _, Env in next, Targets do
		local Old = {}

		RealPcall(function()
			Old.pcall = Env.pcall
			Env.pcall = Wrapped
		end)

		RealPcall(function()
			Old.getfenv = Env.getfenv
			Env.getfenv = GetfenvWrapper
		end)

		Previous[Env] = Old
	end

	local function Restore(Env, Name)
		local Old = Previous[Env]
		if not Old then return end

		local Value = Old[Name]
		if type(Value) ~= "function" then return end

		RealPcall(function()
			Env[Name] = Value
		end)
	end

	--// Внутренние модули берут настоящие функции через
	--// Hook:GetOriginalFunc(getfenv). Регистрируем обёртки как "хуки",
	--// иначе Process:FindCallingClosures на игровом потоке получил бы
	--// ошибку от env-защиты и зря поднял бы identity потока.
	self.PreviousFunctions[Wrapped] = RealPcall
	self.PreviousFunctions[GetfenvWrapper] = RealGetfenv

	print("[Sigma][Patch]  bind: pcall + getfenv -> wrappers (builtin не тронут)")

	if not CanCheckCaller then
		print("[Sigma][Patch]  checkcaller недоступен — env-защита в режиме fail-open")
	end

	--// ── Самопроверка ────────────────────────────────────────────────────
	local Checks = {}

	local function Report(Name, Ok, Detail)
		Checks[Name] = Ok and true or false

		local Line = string.format("[Sigma][Patch]  %-18s %s", Name, Ok and "OK" or "FAIL")
		if Detail ~= nil then
			Line ..= " (" .. tostring(Detail) .. ")"
		end
		print(Line)
	end

	--// 0. Builtin pcall вообще ловит Lua-ошибку в этом env?
	--// Если тут FAIL — в Lua-state уже сидит испорченный pcall,
	--// и никакая обёртка не поможет (нужен реджойн).
	local DirectA, DirectB = RealPcall(function()
		error("SIGMA_DIRECT_PROBE")
	end)
	Report("pcall direct", DirectA == false
		and type(DirectB) == "string"
		and string.find(DirectB, "SIGMA_DIRECT_PROBE", 1, true) ~= nil, DirectB)

	--// 1. Обёртка вообще используется?
	local HitsBefore = HooksFired
	RealPcall(function()
		pcall(function() return 1 end)
	end)
	local Live = HooksFired > HitsBefore
	Report("pcall live", Live, string.format("hits=%d", HooksFired - HitsBefore))

	--// 2. Несколько возвращаемых значений
	local OkAmount, Amount = RealPcall(function()
		return select("#", pcall(function() return 1, 2, 3 end))
	end)
	Report("pcall returns", OkAmount and Amount == 4, Amount)

	--// 3. Ошибка из Lua-функции
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
	local EscapeDetail = nil
	if Escaped ~= true then
		EscapeDetail = "ошибка вышла наружу"
	end
	Report("pcall no escape", Escaped == true, EscapeDetail)

	--// 8. Видна ли обёртка НОВЫМ чанкам — так грузится ReGui
	--// (loadstring получает глобальный env, а не env модуля)
	local ChunkHits = HooksFired
	local ChunkLive, ChunkOk, ChunkErr = false, nil, nil

	local OkChunk, Chunk = RealPcall(loadstring,
		[[return pcall(function() error("SIGMA_CHUNK_PROBE") end)]])

	if OkChunk and type(Chunk) == "function" then
		local OkRun, RunOk, RunErr = RealPcall(Chunk)
		ChunkLive = OkRun == true and HooksFired > ChunkHits
		ChunkOk = RunOk
		ChunkErr = RunErr
	end

	Report("pcall new chunk", ChunkLive
		and ChunkOk == false
		and type(ChunkErr) == "string"
		and string.find(ChunkErr, "SIGMA_CHUNK_PROBE", 1, true) ~= nil, ChunkErr)

	--// ── getfenv: проверки ───────────────────────────────────────────────
	--// Ожидание: env этого модуля, полученный без обёртки.
	local ExpectedEnv = RealGetfenv(1)

	local GfHits = GetfenvCalls
	local OkG1, Gf1 = RealPcall(function()
		return getfenv(1)
	end)
	Report("getfenv live", GetfenvCalls > GfHits,
		string.format("hits=%d", GetfenvCalls - GfHits))

	local Detail1 = nil
	if not OkG1 then
		Detail1 = Gf1
	elseif Gf1 ~= ExpectedEnv then
		Detail1 = "чужой env"
	end
	Report("getfenv(1)", OkG1 and Gf1 == ExpectedEnv, Detail1)

	--// Уровень 2: 1 = сама функция, 2 = тот, кто её вызвал
	local OkG2, Gf2 = RealPcall(function()
		local function Inner()
			return getfenv(2)
		end
		return Inner()
	end)
	local Detail2 = nil
	if not OkG2 then
		Detail2 = Gf2
	elseif Gf2 ~= ExpectedEnv then
		Detail2 = "сдвиг +1 неверен"
	end
	Report("getfenv(2)", OkG2 and Gf2 == ExpectedEnv, Detail2)

	--// 0 = глобальное окружение, без сдвига
	local OkG0, Gf0 = RealPcall(function()
		return getfenv(0)
	end)
	local Detail0 = nil
	if not OkG0 then
		Detail0 = Gf0
	elseif Gf0 ~= GlobalEnv then
		Detail0 = "0 уехал на другой env"
	end
	Report("getfenv(0)", OkG0 and Gf0 == GlobalEnv, Detail0)

	--// getfenv(function) — без сдвига, env свой
	local Marker = {}
	local ProbeFunc = function() end
	local OkSetFenv = RealPcall(setfenv, ProbeFunc, Marker)
	local OkGf, GfFunc = RealPcall(getfenv, ProbeFunc)

	local DetailFunc = nil
	if not OkSetFenv then
		DetailFunc = "setfenv недоступен"
	elseif not OkGf then
		DetailFunc = GfFunc
	elseif GfFunc ~= Marker then
		DetailFunc = "env функции не совпал"
	end
	Report("getfenv(func)", OkSetFenv and OkGf and GfFunc == Marker, DetailFunc)

	--// ReGui/Ui грузятся через loadstring и зовут getfenv() —
	--// обёртка не должна блокировать чанки самого исполнителя.
	local OkGChunk, GChunk = RealPcall(loadstring, "return getfenv()")
	local GChunkOk, GChunkDetail = false, nil

	if OkGChunk and type(GChunk) == "function" then
		local OkRun, Env = RealPcall(GChunk)
		GChunkOk = OkRun and type(Env) == "table"
		if not GChunkOk then
			GChunkDetail = Env
		end
	else
		GChunkDetail = GChunk
	end

	Report("getfenv in chunk", GChunkOk, GChunkDetail)

	local Healthy = Checks["pcall direct"]
		and Checks["pcall returns"]
		and Checks["pcall lua error"]
		and Checks["pcall native error"]
		and Checks["pcall C error"]
		and Checks["pcall nested"]
		and Checks["pcall no escape"]
		and Checks["pcall new chunk"]

	--// ── Вердикт ─────────────────────────────────────────────────────────
	if Live and not Healthy then
		if not Checks["pcall direct"] then
			print("[Sigma][Patch] ВНИМАНИЕ: builtin pcall испорчен ещё до нас — перезайди в игру")
		end

		print("[Sigma][Patch] ROLLBACK: обёртка pcall некорректна — возвращаю ссылки")

		for Env in next, Previous do
			Restore(Env, "pcall")
			Restore(Env, "getfenv")
		end

		print("[Sigma][Patch] pcall восстановлен, function patches отключены")
		return
	end

	if not Live then
		print("[Sigma][Patch] обёртка не видна в env модуля — function patches не применены")

		--// Ссылки, которые успели подменить, возвращаем назад.
		for Env in next, Previous do
			Restore(Env, "pcall")
			Restore(Env, "getfenv")
		end

		print("[Sigma][Patch] builtin pcall не тронут — клиент в безопасности")
		return
	end

	--// getfenv проверяется отдельно: если он не сошёлся, снимаем ТОЛЬКО его.
	local GfHealthy = Checks["getfenv live"]
		and Checks["getfenv(1)"]
		and Checks["getfenv(2)"]
		and Checks["getfenv(0)"]
		and Checks["getfenv(func)"]
		and Checks["getfenv in chunk"]

	if not GfHealthy then
		print("[Sigma][Patch] ROLLBACK: getfenv-обёртка некорректна — возвращаю ссылку")

		for Env in next, Previous do
			Restore(Env, "getfenv")
		end

		print("[Sigma][Patch] getfenv восстановлен, ENV-защита выключена (pcall-патч остался)")
	end

	if GlobalEnv then
		RealPcall(function()
			GlobalEnv.__SigmaFunctionPatched = true
		end)
	end

	print(string.format(
		"[Sigma][Patch] function patches активны | env-защита=%s | executor=%s",
		GfHealthy and "вкл" or "выкл",
		tostring(identifyexecutor and identifyexecutor() or (getexecutorname and getexecutorname()) or "?")
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

	local Success, Env = pcall(self.RealGetfenv or getfenv, Function)
	return Success
		and typeof(Env) == "table"
		and rawget(Env, "__SigmaSpyLogger") == SpyVerificationToken
end

function Hook:RunOnActors(Code: string, ChannelId: number)
	if not getactors or not run_on_actor then return end

	--// [FIX 2026-11-19] strong-реестр. Weak-ключи (__mode="k") теряли
	--// Instance-ключ: актор держится только движком, Lua-ссылки нет,
	--// GC уносил запись → watchdog каждые 3 сек инжектил бандл заново
	--// (в акторе накапливалось 6+ копий модулей, простыня "hooked:").
	--// Instance как ключ в обычной таблице — это одна ссылка, утечки нет:
	--// после Destroy ключ остаётся, но акторов за сессию единицы.
	self._HookedActors = self._HookedActors or {}
	self._ActorPending = self._ActorPending or {}

	local function GetKey(Actor)
		--// GetFullName надёжнее ссылки: переживает клонирование/пересоздание
		local Ok, Name = pcall(function() return Actor:GetFullName() end)
		return Ok and Name or Actor
	end

	local function IsHooked(Actor)
		return self._HookedActors[GetKey(Actor)] == true
	end

	local function TryHook(Actor)
		if not Actor or IsHooked(Actor) then return true end

		local Ok = pcall(run_on_actor, Actor, Code, ChannelId)
		if Ok then
			self._HookedActors[GetKey(Actor)] = true
			print("[Sigma][Actor] hooked:", tostring(Actor))
		end

		return Ok
	end

	local function HookActor(Actor)
		if not Actor then return end

		local Key = GetKey(Actor)
		if self._HookedActors[Key] or self._ActorPending[Key] then return end
		self._ActorPending[Key] = true

		task.spawn(function()
			local Attempts = 0

			repeat
				Attempts += 1
				if TryHook(Actor) then break end
				task.wait(0.25)
			until Attempts >= 8

			self._ActorPending[Key] = nil
		end)
	end

	--// Современная библиотека: getactorstates может возвращать НЕ Actor-инстансы,
	--// а состояния — треды (run_on_thread) или LuaStateProxy (:Execute).
	local SkipClassic = false
	if typeof(getactorstates) == "function" then
		local Ok, States = pcall(getactorstates)
		if Ok and type(States) == "table" then
			local First = next(States)
			if type(First) == "thread" and typeof(run_on_thread) == "function" then
				for _, State in next, States do
					pcall(run_on_thread, State, Code, ChannelId)
				end
				SkipClassic = true
			elseif (type(First) == "userdata" or type(First) == "table") and First.IsActorState then
				local HookedAny = false
				for _, Proxy in next, States do
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
		for _, Category in {getactors(), typeof(getdeletedactors) == "function" and getdeletedactors() or {}} do
			if Category then
				for _, Actor in next, Category do
					HookActor(Actor)
				end
			end
		end
	end

	--// Акторы, созданные ПОЗЖЕ
	local StateCreated = typeof(on_actor_state_created) == "RBXScriptSignal" and on_actor_state_created or nil
	if StateCreated then
		StateCreated:Connect(function(State)
			if typeof(State) == "Instance" and State:IsA("Actor") then
				HookActor(State)
			elseif type(State) == "thread" and typeof(run_on_thread) == "function" then
				pcall(run_on_thread, State, Code, ChannelId)
			end
		end)
	else
		game.DescendantAdded:Connect(function(Instance)
			if typeof(Instance) == "Instance" and Instance:IsA("Actor") then
				HookActor(Instance)
			end
		end)
	end

	--// Watchdog: инстанс актора может появиться раньше своего LuaState
	if SkipClassic or self._ActorWatchdog then return end
	self._ActorWatchdog = true

	task.spawn(function()
		while true do
			task.wait(3)

			local Ok, List = pcall(getactors)
			if Ok and type(List) == "table" then
				for _, Actor in next, List do
					if not IsHooked(Actor) then
						HookActor(Actor)
					end
				end
			end
		end
	end)
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

--// [FIX 2026-11-19] Установка namecall-хука в ТЕКУЩЕМ Lua-state
--// (главный VM или actor-VM) с САМОПРОВЕРКОЙ.
--//
--// Почему не ReplaceMetaMethod напрямую:
--//   в actor-VM Velocity метатаблица Instance отдаётся readonly,
--//   а makewriteable там ОТСУТСТВУЕТ (probe v7: makewrite=nil).
--//   Старый код писал `Metatable[Call] = ...` после setreadonly —
--//   в акторе это тихо не срабатывало, и логи отправки из актора
--//   не появлялись вообще.
--//
--// Функция ставит хук и САМА ПРОВЕРЯЕТ его временным BindableEvent:
--//   1) пишем __namecall (через setreadonly + rawset);
--//   2) если счётчик не вырос — снимаем __namecall и подсовываем
--//      __index-обёртку (fallback namecall -> index);
--//   3) если и это не ловится — возвращаем false и откатываем всё.
--//
--// Handler(OriginalFunc, MetaMethod, Self, Method, ...) — общий обработчик.
function Hook:InstallNamecallHook(Handler)
	local GameMT = getrawmetatable(game)
	if type(GameMT) ~= "table" then
		return false, "getrawmetatable(game) вернул не таблицу"
	end

	local OldNamecall = rawget(GameMT, "__namecall")
	if typeof(OldNamecall) ~= "function" then
		return false, "__namecall в метатаблице не функция"
	end

	--// setreadonly есть и в главном VM, и в акторе; makewriteable —
	--// только в главном, поэтому он опционален.
	local function Unlock(MT)
		if type(MT) ~= "table" then return end
		if typeof(setreadonly) == "function" then
			pcall(setreadonly, MT, false)
		end
		if typeof(makewriteable) == "function" then
			pcall(makewriteable, MT)
		end
	end

	local function Write(MT, Key, Value)
		Unlock(MT)

		local Ok = pcall(function() MT[Key] = Value end)
		local Back = false
		pcall(function() Back = rawget(MT, Key) == Value end)

		if not Back then
			pcall(rawset, MT, Key, Value)
			pcall(function() Back = rawget(MT, Key) == Value end)
		end

		return Back, Ok
	end

	local function Lock(MT)
		if type(MT) ~= "table" then return end
		if typeof(makereadonly) == "function" then
			pcall(makereadonly, MT)
		elseif typeof(setreadonly) == "function" then
			pcall(setreadonly, MT, true)
		end
	end

	local Probe = Instance.new("BindableEvent")

	--// ── стратегия 1: __namecall ────────────────────────────────────────
	local Hits1 = 0
	local ProbeMethod = nil

	local Wrapper1 = newcclosure(function(Self, ...)
		if rawequal(Self, Probe) or Self == Probe then
			Hits1 += 1
			ProbeMethod = getnamecallmethod()
			return OldNamecall(Self, ...)
		end

		local Method = getnamecallmethod()
		if not Method then
			--// namecall без имени метода логировать нельзя — пропускаем
			return OldNamecall(Self, ...)
		end

		return Handler(OldNamecall, "__namecall", Self, Method, ...)
	end)

	local Back1 = Write(GameMT, "__namecall", Wrapper1)
	local FireOk1 = pcall(function() Probe:Fire("probe") end)

	--// Важно: имя метода должно читаться. Если getnamecallmethod()
	--// в этом VM возвращает nil — стратегия 1 бесполезна (логи без Method).
	if Back1 and FireOk1 and Hits1 > 0 and ProbeMethod == "Fire" then
		Lock(GameMT)
		pcall(function() Probe:Destroy() end)
		return true, "namecall"
	end

	--// откат стратегии 1
	Write(GameMT, "__namecall", OldNamecall)
	Lock(GameMT)

	--// ── стратегия 2: __namecall = nil + __index-обёртка ────────────────
	local OldIndex = rawget(GameMT, "__index")
	if typeof(OldIndex) ~= "function" then
		pcall(function() Probe:Destroy() end)
		return false, "__namecall не ловится, а __index не функция"
	end

	--// имена методов отправки берём из Process.RemoteClassData
	local SendNames = {}
	do
		local RemoteClassData = Process and Process.RemoteClassData
		if type(RemoteClassData) == "table" then
			for _, ClassData in next, RemoteClassData do
				local Send = ClassData and ClassData.Send
				if type(Send) == "table" then
					for _, Name in next, Send do
						SendNames[Name] = true
					end
				end
			end
		end
	end

	local Hits2 = 0

	local function WrapMethod(Key, Value)
		return newcclosure(function(Self, ...)
			if rawequal(Self, Probe) or Self == Probe then
				Hits2 += 1
				return Value(Self, ...)
			end

			return Handler(Value, "__index", Self, Key, ...)
		end)
	end

	local Wrapper2 = newcclosure(function(Self, Key)
		local Value = OldIndex(Self, Key)

		if SendNames[Key] and typeof(Self) == "Instance" and typeof(Value) == "function" then
			return WrapMethod(Key, Value)
		end

		return Value
	end)

	local BackIdx = Write(GameMT, "__index", Wrapper2)
	local BackNC = false
	if BackIdx then
		BackNC = Write(GameMT, "__namecall", nil)
	end

	local FireOk2 = false
	if BackIdx and BackNC then
		FireOk2 = pcall(function() Probe:Fire("probe") end)
	end

	if BackIdx and BackNC and FireOk2 and Hits2 > 0 then
		Lock(GameMT)
		pcall(function() Probe:Destroy() end)
		return true, "__index"
	end

	--// полный откат стратегии 2
	if BackIdx then
		pcall(function() rawset(GameMT, "__index", OldIndex) end)
	end
	Write(GameMT, "__namecall", OldNamecall)
	Lock(GameMT)

	--// ── стратегия 3: настоящая метатаблица в getgc/getreg ─────────────
	--// getrawmetatable в actor-VM может отдавать КОПИЮ метатаблицы.
	--// Настоящая метатаблица при этом остаётся обычным GC-объектом —
	--// находим её перебором таблиц с __namecall и проверяем выстрелом.
	local GcProbed, GcWritten, GcHit = 0, 0, nil

	if typeof(getgc) == "function" then
		local Candidates, Seen = {}, {}
		local function AddList(List)
			if type(List) ~= "table" then return end
			for _, V in next, List do
				if type(V) ~= "table" or Seen[V] then continue end
				Seen[V] = true
				if typeof(rawget(V, "__namecall")) == "function" then
					Candidates[#Candidates + 1] = V
				end
			end
		end

		pcall(function() AddList(getgc(true)) end)
		if typeof(getreg) == "function" then
			pcall(function() AddList(getreg()) end)
		end

		for _, TV in next, Candidates do
			if GcProbed >= 400 then break end
			GcProbed += 1

			local NC = rawget(TV, "__namecall")
			if typeof(NC) ~= "function" then continue end

			local Hits3 = 0
			local ProbeWrap = newcclosure(function(Self, ...)
				Hits3 += 1
				return NC(Self, ...)
			end)

			local Back3 = Write(TV, "__namecall", ProbeWrap)
			if not Back3 then continue end
			GcWritten += 1

			local Ok3 = pcall(function() Probe:Fire("probe") end)
			Write(TV, "__namecall", NC)

			if Ok3 and Hits3 > 0 then
				GcHit = TV

				--// нашли настоящую метатаблицу — ставим рабочий обработчик
				local Installed = newcclosure(function(Self, ...)
					if rawequal(Self, Probe) or Self == Probe then
						return NC(Self, ...)
					end

					local Method = getnamecallmethod()
					if not Method then return NC(Self, ...) end

					return Handler(NC, "__namecall", Self, Method, ...)
				end)

				if Write(TV, "__namecall", Installed) then
					Lock(TV)
					pcall(function() Probe:Destroy() end)
					return true, "gc"
				end

				GcHit = nil
			end
		end
	end

	pcall(function() Probe:Destroy() end)
	return false, string.format(
		"namecall: write=%s hits=%d method=%s fire=%s | index: write=%s nc_nil=%s hits=%d fire=%s | gc: cand=%d write=%d hit=%s",
		tostring(Back1), Hits1, tostring(ProbeMethod), tostring(FireOk1),
		tostring(BackIdx), tostring(BackNC), Hits2, tostring(FireOk2),
		GcProbed, GcWritten, tostring(GcHit ~= nil))
end

--// [DIAG 2026-11-19] Механизмы установки, которых НЕ было в прошлой сборке:
--//   1) hookmetamethod(game, "__namecall", ...)
--//   2) hookfunction(__namecall)
--//   3) setrawmetatable(game, proxy)
--// Каждый проверяется реальным выстрелом BindableEvent: "успех" = поймали.
function Hook:TryNamecallAlternatives(Handler)
	if typeof(getrawmetatable) ~= "function" then
		return false, "нет getrawmetatable"
	end

	local GameMT = getrawmetatable(game)
	if type(GameMT) ~= "table" then
		return false, "getrawmetatable(game) не table"
	end

	local OldNamecall = rawget(GameMT, "__namecall")
	if typeof(OldNamecall) ~= "function" then
		return false, "__namecall не function"
	end

	local Probe = Instance.new("BindableEvent")
	Probe.Name = "SigmaProbeAlt"

	local Hits = 0
	local function GetMethod()
		local Ok, Method = pcall(getnamecallmethod)
		return Ok and Method or nil
	end
	local function FireProbe()
		Hits = 0
		local Ok = pcall(function() Probe:Fire("probe") end)
		return Ok and Hits > 0
	end
	local function Pass(OriginalCall, Self, ...)
		if rawequal(Self, Probe) or Self == Probe then
			Hits += 1
			return OriginalCall(Self, ...)
		end
		local Method = GetMethod()
		if not Method then
			return OriginalCall(Self, ...)
		end
		return Handler(OriginalCall, "__namecall", Self, Method, ...)
	end

	--// 1) hookmetamethod
	do
		local Tramp = OldNamecall
		local Ok = false
		if typeof(hookmetamethod) == "function" then
			local Success, Result = pcall(hookmetamethod, game, "__namecall", newcclosure(function(Self, ...)
				return Pass(Tramp, Self, ...)
			end))
			Ok = Success
			if Success and typeof(Result) == "function" then
				Tramp = Result
			end
		end

		if Ok and FireProbe() then
			pcall(function() Probe:Destroy() end)
			return true, "hookmetamethod"
		end

		if Ok then
			pcall(function()
				if typeof(restorefunction) == "function" then
					restorefunction(Tramp)
				end
			end)
		end
	end

	--// 2) hookfunction(__namecall)
	do
		if typeof(hookfunction) == "function" then
			local Tramp = OldNamecall
			local Success, Result = pcall(hookfunction, OldNamecall, newcclosure(function(Self, ...)
				return Pass(Tramp, Self, ...)
			end))
			if Success and typeof(Result) == "function" then
				Tramp = Result
			end

			if Success and FireProbe() then
				pcall(function() Probe:Destroy() end)
				return true, "hookfunction"
			end

			if Success then
				pcall(function()
					if typeof(restorefunction) == "function" then
						restorefunction(OldNamecall)
					elseif typeof(hookfunction) == "function" then
						hookfunction(OldNamecall, Tramp)
					end
				end)
			end
		end
	end

	--// 3) setrawmetatable(game, proxy)
	do
		if typeof(setrawmetatable) == "function" then
			local Proxy = {}
			for Key, Value in next, GameMT do
				Proxy[Key] = Value
			end
			Proxy.__namecall = newcclosure(function(Self, ...)
				return Pass(OldNamecall, Self, ...)
			end)

			local Ok = pcall(setrawmetatable, game, Proxy)
			if Ok and FireProbe() then
				pcall(function() Probe:Destroy() end)
				return true, "setrawmetatable"
			end

			pcall(setrawmetatable, game, GameMT)
		end
	end

	pcall(function() Probe:Destroy() end)
	return false, "alt: hookmetamethod / hookfunction / setrawmetatable — мимо"
end

--// [DIAG 2026-11-19] Диагностика прямо в VM актора. Возвращает текст,
--// каждая строка печатается и уходит в main через comm-канал.
function Hook:ActorDiagnostics(): string
	local Lines = {}
	local function Put(Format, ...)
		local Ok, Text = pcall(string.format, Format, ...)
		Lines[#Lines + 1] = Ok and Text or tostring(Format)
	end

	local Env
	pcall(function()
		Env = getgenv()
	end)
	Env = Env or _G

	local function ApiType(Name)
		local Value = Env[Name]
		if Value == nil then
			pcall(function() Value = rawget(_G, Name) end)
		end
		return typeof(Value)
	end

	Put(
		"vm actor=%s main_token=%s hook=%s ident=%s caller=%s parallel=%s",
		tostring(Env.__SigmaActorVM),
		tostring(Env.__SigmaMainToken),
		tostring(self.HookKind),
		tostring(getthreadidentity and getthreadidentity()),
		tostring(checkcaller and checkcaller()),
		tostring(isparallel and isparallel())
	)

	Put("api " .. table.concat({
		"getrawmetatable=" .. ApiType("getrawmetatable"),
		"setrawmetatable=" .. ApiType("setrawmetatable"),
		"hookmetamethod=" .. ApiType("hookmetamethod"),
		"hookfunction=" .. ApiType("hookfunction"),
		"restorefunction=" .. ApiType("restorefunction"),
		"isfunctionhooked=" .. ApiType("isfunctionhooked"),
		"getgc=" .. ApiType("getgc"),
		"getreg=" .. ApiType("getreg"),
		"setreadonly=" .. ApiType("setreadonly"),
		"makereadonly=" .. ApiType("makereadonly"),
		"makewriteable=" .. ApiType("makewriteable"),
		"getreadonly=" .. ApiType("getreadonly"),
		"getnamecallmethod=" .. ApiType("getnamecallmethod"),
		"oth=" .. ApiType("oth"),
		"getconnections=" .. ApiType("getconnections"),
		"getscriptfromthread=" .. ApiType("getscriptfromthread"),
		"getcallingscript=" .. ApiType("getcallingscript"),
	}, " "))

	local MT = getrawmetatable(game)
	if type(MT) ~= "table" then
		Put("mt НЕ table: %s", typeof(MT))
		return table.concat(Lines, "\n")
	end

	local OldNC = rawget(MT, "__namecall")
	local OldIdx = rawget(MT, "__index")
	local WasReadonly
	pcall(function()
		if typeof(getreadonly) == "function" then
			WasReadonly = getreadonly(MT)
		end
	end)

	local function Unlock(Target)
		if typeof(setreadonly) == "function" then
			pcall(setreadonly, Target, false)
		end
		if typeof(makewriteable) == "function" then
			pcall(makewriteable, Target)
		end
	end
	local function Lock(Target)
		if WasReadonly == false then return end
		if typeof(makereadonly) == "function" then
			pcall(makereadonly, Target)
		elseif typeof(setreadonly) == "function" then
			pcall(setreadonly, Target, true)
		end
	end

	local Probe = Instance.new("BindableEvent")
	Probe.Name = "SigmaProbeActor"
	local ProbeMT
	pcall(function()
		ProbeMT = getrawmetatable(Probe)
	end)

	Put(
		"mt type=%s stable=%s same_probe=%s nc=%s idx=%s ni=%s ro=%s",
		typeof(MT),
		tostring(getrawmetatable(game) == MT),
		tostring(ProbeMT == MT),
		typeof(OldNC),
		typeof(OldIdx),
		typeof(rawget(MT, "__newindex")),
		tostring(WasReadonly)
	)

	--// T1: __index — свойство Instance вообще проходит через метатаблицу?
	do
		local Hits = 0
		local Wrote = false
		local Wrapper = newcclosure(function(Self, Key)
			if rawequal(Self, Probe) or Self == Probe then
				Hits += 1
			end
			return OldIdx(Self, Key)
		end)

		Unlock(MT)
		pcall(function()
			rawset(MT, "__index", Wrapper)
			Wrote = rawget(MT, "__index") == Wrapper
		end)
		local ReadName = pcall(function() return Probe.Name end)
		local ReadClass = pcall(function() return Probe.ClassName end)
		pcall(rawset, MT, "__index", OldIdx)
		Lock(MT)

		Put("T1 index write=%s name=%s class=%s hits=%d", tostring(Wrote), tostring(ReadName), tostring(ReadClass), Hits)
	end

	--// T2: __namecall — основной путь отправки.
	do
		local Hits, Methods = 0, {}
		local Wrote = false
		local Fresh = false
		local Wrapper

		Wrapper = newcclosure(function(Self, ...)
			Hits += 1
			if #Methods < 8 then
				local Ok, Method = pcall(getnamecallmethod)
				Methods[#Methods + 1] = Ok and tostring(Method) or "err"
			end
			return OldNC(Self, ...)
		end)

		Unlock(MT)
		pcall(function()
			rawset(MT, "__namecall", Wrapper)
			Wrote = rawget(MT, "__namecall") == Wrapper
		end)

		pcall(function()
			Fresh = rawget(getrawmetatable(game), "__namecall") == Wrapper
		end)

		local FullName = pcall(function() return Probe:GetFullName() end)
		local Fire = pcall(function() Probe:Fire("probe") end)
		local Service = pcall(function() return game:GetService("Players") end)

		pcall(rawset, MT, "__namecall", OldNC)
		Lock(MT)

		Put(
			"T2 namecall write=%s fresh=%s gfn=%s fire=%s svc=%s hits=%d m=%s",
			tostring(Wrote),
			tostring(Fresh),
			tostring(FullName),
			tostring(Fire),
			tostring(Service),
			Hits,
			table.concat(Methods, ",")
		)
	end

	--// T3: hookfunction на самой функции __namecall.
	do
		local Hits = 0
		local Trampoline = OldNC
		local State = "нет hookfunction"

		if typeof(hookfunction) == "function" then
			local Success, Result = pcall(hookfunction, OldNC, newcclosure(function(Self, ...)
				Hits += 1
				return Trampoline(Self, ...)
			end))
			if Success and typeof(Result) == "function" then
				Trampoline = Result
			end

			local Hooked = false
			pcall(function()
				if typeof(isfunctionhooked) == "function" then
					Hooked = isfunctionhooked(OldNC) == true
				end
			end)

			local Fire = pcall(function() Probe:Fire("probe") end)

			pcall(function()
				if typeof(restorefunction) == "function" then
					restorefunction(OldNC)
				elseif Success then
					hookfunction(OldNC, Trampoline)
				end
			end)

			State = string.format("ok=%s hooked=%s fire=%s", tostring(Success), tostring(Hooked), tostring(Fire))
		end

		Put("T3 hookfn %s hits=%d", State, Hits)
	end

	--// T4: hookmetamethod на объекте (не на game).
	do
		local Hits = 0
		local State = "нет hookmetamethod"

		if typeof(hookmetamethod) == "function" then
			local Trampoline = OldNC
			local Success, Result = pcall(hookmetamethod, Probe, "__namecall", newcclosure(function(Self, ...)
				Hits += 1
				return Trampoline(Self, ...)
			end))
			if Success and typeof(Result) == "function" then
				Trampoline = Result
			end

			local Hooked = false
			pcall(function()
				if typeof(isfunctionhooked) == "function" then
					Hooked = isfunctionhooked(Trampoline) == true
				end
			end)

			local Fire = pcall(function() Probe:Fire("probe") end)

			pcall(function()
				if Success and typeof(restorefunction) == "function" then
					restorefunction(Trampoline)
				end
			end)

			State = string.format("ok=%s hooked=%s fire=%s", tostring(Success), tostring(Hooked), tostring(Fire))
		end

		Put("T4 hmm(obj) %s hits=%d", State, Hits)
	end

	--// T5: setrawmetatable(Probe, proxy) — замена метатаблицы объекта.
	do
		local State = "нет setrawmetatable"
		local Hits = 0

		if typeof(setrawmetatable) == "function" then
			local Proxy = {}
			for Key, Value in next, MT do
				Proxy[Key] = Value
			end
			Proxy.__namecall = newcclosure(function(Self, ...)
				Hits += 1
				return OldNC(Self, ...)
			end)

			local Ok = pcall(setrawmetatable, Probe, Proxy)
			local Fire = false
			if Ok then
				Fire = pcall(function() Probe:Fire("probe") end)
			end
			pcall(setrawmetatable, Probe, MT)

			State = string.format("ok=%s fire=%s", tostring(Ok), tostring(Fire))
		end

		Put("T5 setrawmt(obj) %s hits=%d", State, Hits)
	end

	--// T6: поиск настоящей метатаблицы в getgc / getreg.
	do
		local Total, SameFunc, SameTable = 0, 0, 0
		local Seen = {}

		local function Scan(List)
			if type(List) ~= "table" then return end
			for _, Value in next, List do
				if type(Value) ~= "table" or Seen[Value] then continue end
				Seen[Value] = true
				if rawequal(Value, MT) then
					SameTable += 1
				end
				local NC = rawget(Value, "__namecall")
				if typeof(NC) == "function" then
					Total += 1
					if rawequal(NC, OldNC) then
						SameFunc += 1
					end
				end
			end
		end

		pcall(function() Scan(getgc(true)) end)
		pcall(function() Scan(getreg and getreg() or nil) end)
		Put("T6 gc tables=%d same_fn=%d same_mt=%d", Total, SameFunc, SameTable)
	end

	--// T7: базовые вещи — не заглушки ли.
	do
		local Plain = {}
		pcall(rawset, Plain, "a", 1)
		local Locks = "n/a"
		if typeof(setreadonly) == "function" then
			pcall(setreadonly, Plain, true)
			Locks = tostring(not pcall(function() rawset(Plain, "b", 2) end))
			pcall(setreadonly, Plain, false)
		end
		Put("T7 rawget=%s readonly_blocks=%s getmt=%s dbgmt=%s", tostring(rawget(Plain, "a")), Locks, type(getmetatable(Probe)), tostring(debug and typeof(debug.getmetatable)))
	end

	pcall(function() Probe:Destroy() end)
	return table.concat(Lines, "\n")
end

function Hook:BeginHooks()
	--// [FIX 2026-11-19] Идемпотентность: BeginHooks срабатывает дважды
	--// (main + actor), повторная установка = двойные логи и двойной
	--// ProcessRemote на каждый вызов.
	if self.OriginalNamecall then
		print("[Sigma][Patch] BeginHooks: __namecall уже стоит — пропускаю")
		return
	end

	--// Общий обработчик для всех стратегий.
	local function Handler(OriginalFunc, MetaMethod, Self, Method, ...)
		self.NamecallHits = (self.NamecallHits or 0) + 1

		--// [DIAG] ловим "чужие" вызовы (из актора) по имени пробника
		if self.WatchProbe and typeof(Self) == "Instance" then
			local OkName, Name = pcall(function()
				return Self.Name
			end)
			if OkName and typeof(Name) == "string" and string.sub(Name, 1, 10) == "SigmaProbe" then
				self.ProbeHits = (self.ProbeHits or 0) + 1
				print("[SigmaMain] probe-namecall:", Name, tostring(Method))
			end
		end

		local Ok, ReturnValues = pcall(ProcessRemote, OriginalFunc, MetaMethod, Self, Method, ...)
		if Ok and ReturnValues then
			return Process:Unpack(ReturnValues)
		end

		return OriginalFunc(Self, ...)
	end

	--// oth есть только в главном VM; в акторе его нет.
	local UseOth = typeof(oth) == "table" and typeof(oth.hook) == "function"
		and (not Configuration or Configuration.UseOthHooks ~= false)

	if UseOth then
		local OthOriginal
		OthOriginal = oth.hook(getrawmetatable(game).__namecall, function(self, ...)
			return Handler(OthOriginal, "__namecall", self, getnamecallmethod(), ...)
		end)

		self.OriginalNamecall = OthOriginal
		return
	end

	--// Прямая установка с самопроверкой (работает и в main, и в actor).
	--// Сначала — механизмы, которых не было в прошлой сборке
	--// (hookmetamethod / hookfunction / setrawmetatable), потом старый набор.
	local Ok, Kind = self:TryNamecallAlternatives(Handler)
	if not Ok then
		Ok, Kind = self:InstallNamecallHook(Handler)
	end

	self.HookKind = Ok and tostring(Kind) or nil
	if Ok then
		self.OriginalNamecall = true
		print("[Sigma][Patch] namecall-хук активен: " .. tostring(Kind))
	else
		print("[Sigma][Patch] namecall-хук НЕ встал: " .. tostring(Kind))
	end
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
		OriginalEnv = (self.RealGetfenv or getfenv)(Function)
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
	local OriginalEnv = (self.RealGetfenv or getfenv)(Callback)
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

	--// [DIAG 2026-11-19] В каком VM мы находимся + мост "main -> actor"
	local IsActorVM = (ExtraData and ExtraData.IsActor) == true
	do
		local GlobalEnv
		pcall(function()
			GlobalEnv = getgenv()
		end)

		if type(GlobalEnv) == "table" then
			if IsActorVM then
				GlobalEnv.__SigmaActorVM = true
			else
				GlobalEnv.__SigmaMainToken = tostring(tick()):gsub("%.", "") .. "_" .. tostring(math.random(100000, 999999))
			end
		end
	end

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
		end,
		--// ── [DIAG 2026-11-19] мост main -> actor ─────────────────────────
		--// main кидает "SigmaDiag"/"SigmaEval", актор выполняет и отвечает
		--// построчно. Пуш нужен ОДИН раз, дальше тесты гоняются из консоли.
		["SigmaDiag"] = function(Id)
			if not IsActorVM then return end

			local Text = tostring(self:ActorDiagnostics())
			for Line in string.gmatch(Text, "[^\n]+") do
				print("[SigmaDiag] " .. Line)
				pcall(function()
					Communication:Communicate("SigmaDiagLine", tostring(Id), Line)
				end)
			end
			pcall(function()
				Communication:Communicate("SigmaDiagLine", tostring(Id), "__END__")
			end)
		end,
		["SigmaDiagLine"] = function(Id, Line)
			if IsActorVM then return end
			print("[SigmaDiag] " .. tostring(Line))
		end,
		["SigmaEval"] = function(Id, Code)
			if not IsActorVM then return end

			local Chunk, LoadError = loadstring(tostring(Code), "SigmaEval")
			local Ok, Result
			if Chunk then
				Ok, Result = pcall(Chunk)
			else
				Ok, Result = false, LoadError
			end

			Result = tostring(Result)
			if #Result > 1200 then
				Result = string.sub(Result, 1, 1200) .. "..."
			end

			pcall(function()
				Communication:Communicate("SigmaEvalResult", tostring(Id), tostring(Ok), Result)
			end)
		end,
		["SigmaEvalResult"] = function(Id, Ok, Result)
			if IsActorVM then return end
			print(string.format("[SigmaEval] %s ok=%s | %s", tostring(Id), tostring(Ok), tostring(Result)))
		end
	})
	
	--// Process configuration
	ProcessLib:SetChannel(Channel, IsWrapped)
	ProcessLib:SetExtraData(ExtraData)

	--// Hook configuration
	self:Init(InitData)

	--// [DIAG 2026-11-19] консольные хелперы (только main VM)
	if not IsActorVM then
		local GlobalEnv
		pcall(function()
			GlobalEnv = getgenv()
		end)

		if type(GlobalEnv) ~= "table" then
			GlobalEnv = _G
		end

		GlobalEnv.SigmaActorDiag = function()
			local Id = tostring(math.random(100000, 999999))
			print("[SigmaDiag] request " .. Id)
			pcall(function()
				Communication:Communicate("SigmaDiag", Id)
			end)
			return Id
		end

		GlobalEnv.SigmaActorEval = function(Code)
			local Id = tostring(math.random(100000, 999999))
			print("[SigmaEval] request " .. Id)
			pcall(function()
				Communication:Communicate("SigmaEval", Id, tostring(Code))
			end)
			return Id
		end

		GlobalEnv.SigmaActorStats = function()
			self.WatchProbe = true
			print(string.format(
				"[SigmaMain] namecall_hits=%d probe_hits=%d hook=%s",
				self.NamecallHits or 0,
				self.ProbeHits or 0,
				tostring(self.HookKind)
			))
		end
	end

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
