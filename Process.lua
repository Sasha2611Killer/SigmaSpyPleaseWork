--!nolint DeprecatedApi

type table = {
    [any]: any
}

type RemoteData = {
	Remote: Instance,
    NoBacktrace: boolean?,
	IsReceive: boolean?,
	Args: table,
    Id: string,
	Method: string,
    TransferType: string,
	ValueReplacements: table,
    ReturnValues: table,
    OriginalFunc: (Instance, ...any) -> ...any
}

--// Module
local Process = {
    --// Remote classes
    RemoteClassData = {
        ["RemoteEvent"] = {
            Send = {
                "FireServer",
                "fireServer",
				"fireserver",
            },
            Receive = {
                "OnClientEvent",
            }
        },
        ["RemoteFunction"] = {
            IsRemoteFunction = true,
            Send = {
                "InvokeServer",
                "invokeServer",
				"invokeserver",
            },
            Receive = {
                "OnClientInvoke",
            }
        },
        ["UnreliableRemoteEvent"] = {
            Send = {
                "FireServer",
                "fireServer",
				"fireserver",
            },
            Receive = {
                "OnClientEvent",
            }
        },
        ["BindableEvent"] = {
            NoReciveHook = true,
            Send = {
                "Fire",
				"fire",
            },
            Receive = {
                "Event",
            }
        },
        ["BindableFunction"] = {
            IsRemoteFunction = true,
            NoReciveHook = true,
            Send = {
                "Invoke",
				"invoke",
            },
            Receive = {
                "OnInvoke",
            }
        }
    },
    RemoteOptions = {},
    LoopingRemotes = {},

    --// Функции-логгеры Sigma Spy (не показывать в списке соединений)
    LogConnectionFunctions = setmetatable({}, {__mode = "k"}),
    ConfigOverwrites = {
        [{"sirhurt", "potassium", "wave"}] = {
            ForceUseCustomComm = true
        }
    }
}

--// Modules
local Hook
local Communication
local ReturnSpoofs
local Ui
local Config

--// Services
local HttpService: HttpService

--// Communication channel
local Channel
local WrappedChannel = false

local SigmaENV = getfenv(1)

type Event = RemoteEvent | RemoteFunction | UnreliableRemoteEvent | BindableEvent | BindableFunction
local InstanceCreatedRemotes: typeof(setmetatable({} :: {[Event]: true}, {__mode = "k"})) = setmetatable({}, {
    __mode = "k"
})

--// =====================================================================
--// Cobalt-style: ОЧЕРЕДЬ ЛОГОВ + ВОРКЕР (Src/Utils/Log.luau)
--// =====================================================================
--// Раньше на треде вызова ремоута делалось:
--//   1) разбор стека (16 уровней × getfenv)      <- тяжело
--//   2) копирование аргументов
--//   3) РЕАЛЬНЫЙ ВЫЗОВ РЕМОУТА                     <- отправка ЗДЕСЬ
--//   4) Communication:QueueLog(...)                 <- сериализация + UI, синхронно
--//
--// Из-за этого спам-ремоут (100+ вызовов/сек) задерживал отправку
--// остальных ремоутов: до реального FireServer стоял разбор стека,
--// а после него — тяжёлый QueueLog, блокирующий следующий вызов.
--//
--// Теперь:
--//   1) дёшево снимаем вызывающие функции (только debug.info)
--//   2) быстрый клон аргументов (фиксируем значения ДО отправки)
--//   3) РЕАЛЬНЫЙ ВЫЗОВ — СРАЗУ
--//   4) разбор стека + логирование — в воркере, сброс раз в кадр
local LogQueue = {}
local LogQueueTail = 0
local LogWorkerStarted = false

function Process:Merge(Base: table, New: table)
    if not New then return end
	for Key, Value in next, New do
		Base[Key] = Value
	end
end

function Process:Init(Data)
    local Modules = Data.Modules
    local Services = Data.Services

    --// Services
    HttpService = Services.HttpService

    --// Modules
    Config = Modules.Config
    Ui = Modules.Ui
    Hook = Modules.Hook
    Communication = Modules.Communication
    ReturnSpoofs = Modules.ReturnSpoofs

	--// Воркер очереди логов (Cobalt: Heartbeat + LogNotificationQueue)
	if not LogWorkerStarted then
		LogWorkerStarted = true
		task.spawn(function()
			while true do
				task.wait()

				local Ok, Error = pcall(function()
					Process:FlushLogQueue()
				end)

				if not Ok then
					warn("Cobalt/Sigma: log queue flush failed:", Error)
				end
			end
		end)
	end
end

--// Сброс очереди логов. Вызывается воркером раз в кадр.
function Process:FlushLogQueue()
	if LogQueueTail == 0 then return end

	local Batch = LogQueue
	local Count = LogQueueTail
	LogQueue = {}
	LogQueueTail = 0

	for Index = 1, Count do
		local Entry = Batch[Index]
		Batch[Index] = nil

		if Entry then
			local Data = Entry.Data

			--// Разбор стека — здесь, в воркере (функции уже захвачены)
			if Entry.Functions then
				self:ResolveCallers(Data, Entry.Functions)
			end

			Communication:QueueLog(Data)
		end
	end
end

--// Communication
function Process:SetChannel(NewChannel: BindableEvent, IsWrapped: boolean)
    Channel = NewChannel
    WrappedChannel = IsWrapped
end

function Process:GetConfigOverwrites(Name: string)
    local ConfigOverwrites = self.ConfigOverwrites

    for List, Overwrites in next, ConfigOverwrites do
        if not table.find(List, Name) then continue end
        return Overwrites
    end
    return
end

function Process:CheckConfig(Config: table)
    local Name = identifyexecutor():lower()

    --// Force configuration overwrites for specific executors
    local Overwrites = self:GetConfigOverwrites(Name)
    if not Overwrites then return end

    self:Merge(Config, Overwrites)
end

function Process:CleanCError(Error: string): string
    Error = Error:gsub(":%d+: ", "")
    Error = Error:gsub(", got %a+", "")
    Error = Error:gsub("invalid argument", "missing argument")
    return Error
end

function Process:CountMatches(String: string, Match: string): number
	local Count = 0
	for _ in String:gmatch(Match) do
		Count +=1 
	end

	return Count
end

function Process:CheckValue(Value, Ignore: table?, Cache: table?)
    local Type = typeof(Value)
    Communication:WaitCheck()

    if Type == "table" then
        Value = self:DeepCloneTable(Value, Ignore, Cache)
    elseif Type == "Instance" then
        Value = cloneref(Value)
    end

    return Value
end

function Process:DeepCloneTable(Table, Ignore: table?, Visited: table?): table
    if typeof(Table) ~= "table" then return Table end
    local Cache = Visited or {}

    --// Check for cached
    if Cache[Table] then
        return Cache[Table]
    end

    local New = {}
    Cache[Table] = New

    for Key, Value in next, Table do
        --// Check if the value is ignored
        if Ignore and table.find(Ignore, Value) then continue end

        Key = self:CheckValue(Key, Ignore, Cache)
        New[Key] = self:CheckValue(Value, Ignore, Cache)
    end

    --// Master clear
    if not Visited then
        table.clear(Cache)
    end

    return New
end

--// =====================================================================
--// БЫСТРЫЙ КЛОН АРГУМЕНТОВ (горячий путь)
--// =====================================================================
--// Arguments надо зафиксировать ДО отправки (иначе игра успеет их
--// изменить после вызова). Но DeepCloneTable слишком тяжёлый: он зовёт
--// Communication:WaitCheck() на КАЖДОЕ значение. Здесь — лёгкий клон
--// без WaitCheck/cloneref: только структура таблиц, Instances по ссылке.
function Process:CloneValueFast(Value: any, Cache: table?): any
    if type(Value) ~= "table" then return Value end

    local New = {}
    Cache = Cache or {}

    if Cache[Value] then
        return Cache[Value]
    end
    Cache[Value] = New

    for Key, Item in next, Value do
        New[Key] = self:CloneValueFast(Item, Cache)
    end

    return New
end

function Process:CloneArgs(...)
    local Packed = table.pack(...)
    local Result = table.create(Packed.n)

    for Index = 1, Packed.n do
        Result[Index] = self:CloneValueFast(Packed[Index])
    end

    return Result
end

--// Глубокое сравнение для дедупликации логов (Detect Spam).
--// Таблицы сравниваем рекурсивно, остальное — по ==.
function Process:DeepEquals(A, B): boolean
    if A == B then return true end
    if typeof(A) ~= typeof(B) then return false end

    if typeof(A) == "table" then
        for Key, Value in next, A do
            if not self:DeepEquals(Value, B[Key]) then return false end
        end
        for Key in next, B do
            if A[Key] == nil then return false end
        end
        return true
    end

    return false
end

function Process:Unpack(Table: table)
    if not Table then return Table end
	local Length = table.maxn(Table)
	return unpack(Table, 1, Length)
end

function Process:PushConfig(Overwrites)
    self:Merge(self, Overwrites)
end

function Process:FuncExists(Name: string)
	return SigmaENV[Name]
end

function Process:CheckExecutor(): boolean
    local Blacklisted = {
        "xeno",
        "solara",
        "jjsploit"
    }

    local Name = identifyexecutor():lower()
    local IsBlacklisted = table.find(Blacklisted, Name)

    --// Some executors have broken functionality
    if IsBlacklisted then
        Ui:ShowUnsupportedExecutor(Name)
        return false
    end

    return true
end

function Process:CheckFunctions(): boolean
    local CoreFunctions = {
        "hookmetamethod",
        "hookfunction",
        "getrawmetatable",
        "setreadonly"
    }

    --// Check if the functions exist in the ENV
    for _, Name in CoreFunctions do
        local Func = self:FuncExists(Name)
        if Func then continue end

        --// Function missing!
        Ui:ShowUnsupported(Name)
        return false
    end

    return true
end

function Process:CheckIsSupported(): boolean
    --// Check if the executor is blacklisted
    local ExecutorSupported = self:CheckExecutor()
    if not ExecutorSupported then
        return false
    end

    --// Check if the core functions exist
    local FunctionsSupported = self:CheckFunctions()
    if not FunctionsSupported then
        return false
    end

    return true
end

function Process:GetClassData(Remote: Instance): table?
    local RemoteClassData = self.RemoteClassData
    local ClassName = Hook:Index(Remote, "ClassName")

    return RemoteClassData[ClassName]
end

function Process:IsProtectedRemote(Remote: Instance): boolean
    local IsDebug = Remote == Communication.DebugIdRemote
    local IsChannel = Remote == (WrappedChannel and Channel.Channel or Channel)

    return IsDebug or IsChannel
end

function Process:RemoteAllowed(Remote: Event, TransferType: string, Method: string?): boolean?
    if typeof(Remote) ~= 'Instance' then return end

    --// Check if the Remote is protected
    if self:IsProtectedRemote(Remote) then return end

    --// Fetch class table
	local ClassData = self:GetClassData(Remote)
	if not ClassData then return end

    --// Check if the transfer type has data
    local Allowed = ClassData[TransferType]
    if not Allowed then return end

    --// Check if the method is allowed
	if Method then
		return table.find(Allowed, Method) ~= nil
	end

	return true
end

function Process:SetExtraData(Data: table)
    if not Data then return end
    self.ExtraData = Data
end

function Process:GetRemoteSpoof(Remote: Instance, Method: string, ...): table?
    local Spoof = ReturnSpoofs[Remote]

    if not Spoof then return end
    if Spoof.Method ~= Method then return end

    local ReturnValues = Spoof.Return

    --// Call the ReturnValues function type
    if typeof(ReturnValues) == "function" then
        ReturnValues = ReturnValues(...)
    end

	return ReturnValues
end

function Process:SetNewReturnSpoofs(NewReturnSpoofs: table)
    ReturnSpoofs = NewReturnSpoofs
end

--// =====================================================================
--// РАЗБОР ВЫЗЫВАЮЩИХ (перенесён с горячего пути в воркер)
--// =====================================================================
--// [FIX] ВСЕ не-Sigma Lua-фреймы + script-хинты с C-фреймов.
--// Probe v6 (2026-11-03): стек на Delta ДОСТУПЕН. C-фреймы имеют l == -1,
--// но это НЕ конец стека — идём, пока debug.info(Level,"f") не nil.
--// C-фреймы в Result не добавляем, но их env.script (владелец потока/
--// загрузчик) собираем в Hints. identity 8 поднимается ЛЕНИВО — только
--// если getfenv упал. Страховка на executor'ы без identity-функций.
function Process:ResolveClosures(Functions: { any }): (table, table)
    local Getfenv = Hook:GetOriginalFunc(getfenv)
    local Result = {}
    local Hints = {}
    local Seen = {}

    local HasIdentity = typeof(getthreadidentity) == "function"
        and typeof(setthreadidentity) == "function"
    local Identity = HasIdentity and getthreadidentity() or nil
    local Raised = false

    local function RaiseIdentity()
        if Raised or not HasIdentity then return end
        Raised = true
        setthreadidentity(8)
    end

    for _, Function in Functions do
        if Seen[Function] then continue end
        Seen[Function] = true

        local Source = debug.info(Function, "s")
        local IsC = Source == "[C]"

        local Success, Env = pcall(Getfenv, Function)
        if not Success then
            --// Ленивый подъём identity: второй шанс для getfenv
            RaiseIdentity()
            Success, Env = pcall(Getfenv, Function)
            if not Success then continue end
        end

        if Env == SigmaENV then continue end

        --// script-хинт с ЛЮБОГО не-Sigma фрейма (C-фреймы Delta
        --// несут env.script игры — это загрузчик/владелец потока)
        if type(Env) == "table" then
            local ScriptHint = rawget(Env, "script")
            if typeof(ScriptHint) == "Instance" then
                table.insert(Hints, ScriptHint)
            end
        end

        --// C-фреймы как closures не подходят (нет Lua-локалов/констант)
        if IsC then continue end

        table.insert(Result, Function)
        if #Result >= 8 then break end
    end

    if Raised then
        setthreadidentity(Identity)
    end
    return Result, Hints
end

--// Дёшево снимает список вызывающих функций (только debug.info).
--// Вызывается НА ГОРЯЧЕМ ПУТИ, до реального вызова ремоута:
--// стек здесь ещё живой, а getfenv/скрипты — уже нет.
--// ВАЖНО: диапазон уровней 1..16 — как в оригинальной FindCallingClosures
--// (там Offset был помечен "_" и игнорировался). Не сужать диапазон,
--// иначе изменится атрибуция SourceScript/CallerScript.
function Process:GetCallingFunctions(Offset: number?): { any }
    local Functions = {}
    local Seen = {}

    for Level = 1, 16 do
        local Function = debug.info(Level, "f")
        if not Function then break end
        if Seen[Function] then continue end
        Seen[Function] = true

        table.insert(Functions, Function)
    end

    return Functions
end

--// Разбор вызывающих — уже в воркере (функции захвачены заранее).
function Process:ResolveCallers(Data: RemoteData, Functions: { any })
    --// Fallback: если стек пуст — getcallingscript() (владелец потока)
    if not Data.SourceScript then
        Data.SourceScript = Data.CallingScript
    end

    local Closures, Hints = self:ResolveClosures(Functions)

    local SourceIndex = nil
    for i, F in Closures do
        local S = self:GetScriptFromFunc(F)
        if typeof(S) == "Instance" then
            Data.CallingFunction = F
            Data.SourceScript = S
            SourceIndex = i
            break
        end
    end

    if not SourceIndex then return end

    --// 1) хинты (C-фреймы: владелец потока/загрузчик)
    for _, Hint in Hints do
        if typeof(Hint) == "Instance" and Hint ~= Data.SourceScript then
            Data.CallerScript = Hint
            break
        end
    end

    --// 2) fallback: скрипт следующего Lua-фрейма
    if not Data.CallerScript then
        for i = SourceIndex + 1, #Closures do
            local S = self:GetScriptFromFunc(Closures[i])
            if typeof(S) == "Instance" and S ~= Data.SourceScript then
                Data.CallerFunction = Closures[i]
                Data.CallerScript = S
                break
            end
        end
    end
end

--// Обратная совместимость: первый (ближайший) вызывающий closure
function Process:FindCallingClosures(Offset: number?): (table, table)
    return self:ResolveClosures(self:GetCallingFunctions(Offset))
end

function Process:FindCallingLClosure(Offset: number)
    return self:FindCallingClosures(Offset)[1]
end

function Process:Decompile(Script: LocalScript | ModuleScript): string
    local KonstantAPI = "http://api.plusgiant5.com/konstant/decompile"
    local ForceKonstant = Config.ForceKonstantDecompiler

    --// Use built-in decompiler if the executor supports it
    if decompile and not ForceKonstant then 
        return decompile(Script)
    end

    --// getscriptbytecode
    local Success, Bytecode = pcall(getscriptbytecode, Script)
    if not Success then
        local Error = `--Failed to get script bytecode, error:\n`
        Error ..= `\n--[[\n{Bytecode}\n]]`
        return Error, true
    end

    --// Send POST request to the API
    local Responce = request({
        Url = KonstantAPI,
        Body = Bytecode,
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json"
        },
    })

    --// Error check
    if Responce.StatusCode ~= 200 then
        local Error = `--[KONSTANT] Error occured while requesting the API, error:\n`
        Error ..= `\n--[[\n{Responce.Body}\n]]`
        return Error, true
    end

    return Responce.Body
end

--// [FIX] Хвост GetScriptFromFunc: второй проход по getloadedmodules
--// возвращает ТОЛЬКО если кандидат единственный — иначе nil,
--// чтобы не отдать чужой модуль с тем же именем.
function Process:GetScriptFromFunc(Func: (...any) -> ...any)
    if not Func then return end

    local Success, ENV = pcall(getfenv, Func)
    if Success then
        if not self:IsSigmaSpyENV(ENV) then
            local Script = rawget(ENV, "script")
            if typeof(Script) == "Instance" then
                return Script
            end
        end
    end

    --// Fallback: env без "script". Имя чанка = GetFullName скрипта.
    --// Ищем по descendants + getloadedmodules + getrunningscripts + getscripts.
    local SourceOk, Source = pcall(debug.info, Func, "s")
    if SourceOk and type(Source) == "string" and Source ~= "[C]" and #Source > 0 then
        local TargetName = Source:match("[%w_]+$")
        if TargetName then
            local Candidates = {game:GetDescendants()}
            if typeof(getloadedmodules) == "function" then
                table.insert(Candidates, getloadedmodules())
            end
            if typeof(getrunningscripts) == "function" then
                table.insert(Candidates, getrunningscripts())
            end
            if typeof(getscripts) == "function" then
                table.insert(Candidates, getscripts())
            end

            --// Проход 1: точное совпадение GetFullName (per-candidate pcall)
            for _, List in Candidates do
                for _, Script in List do
                    if Script.Name ~= TargetName then continue end
                    if not Script:IsA("LuaSourceContainer") then continue end

                    local OkName, FullName = pcall(function()
                        return Script:GetFullName()
                    end)
                    if OkName and FullName == Source then
                        return Script
                    end
                end
            end

            --// Проход 2: для удалённых-но-загруженных — по имени,
            --// только если кандидат ЕДИНСТВЕННЫЙ
            if typeof(getloadedmodules) == "function" then
                local LoadedOk, Loaded = pcall(getloadedmodules)
                if LoadedOk and type(Loaded) == "table" then
                    local Matches = {}
                    for _, ModuleScript in Loaded do
                        if ModuleScript.Name == TargetName
                            and ModuleScript:IsA("LuaSourceContainer")
                        then
                            table.insert(Matches, ModuleScript)
                        end
                    end
                    if #Matches == 1 then
                        return Matches[1]
                    end
                end
            end
        end
    end

    return
end

--// Хеш скрипта (getscripthash)
function Process:GetScriptHash(Script: Instance): string?
    if typeof(Script) ~= "Instance" then return nil end
    if typeof(getscripthash) ~= "function" then return nil end

    local Ok, Hash = pcall(getscripthash, Script)
    if Ok and type(Hash) == "string" then
        return Hash
    end
    return nil
end

--// [FIX] Мягкая проверка: удалённый-но-загруженный модуль тоже считаем
--// доступным. Полностью мёртвый тоже разрешаем — pcall(getscriptbytecode)
--// сам вернёт ошибку, а Decompile покажет её текстом.
function Process:IsScriptAvailable(Script: Instance): boolean
    if typeof(Script) ~= "Instance" then return false end

    local OkAlive, Alive = pcall(function()
        return Script:IsDescendantOf(game)
    end)
    if OkAlive and Alive then
        return true
    end

    --// Не отсекаем удалённые: getscriptbytecode может отдать байткод
    --// для require'd-модуля, уже удалённого из дерева.
    return true
end

function Process:ConnectionIsValid(Connection: table): boolean
    if Connection.Function == nil then
        return false
    end

    return true
end

function Process:FilterConnections(Signal: RBXScriptSignal): table
    local Processed = {}

    for _, Connection in getconnections(Signal) do
        if self.LogConnectionFunctions[Connection.Function] then continue end
        if Hook.IsSpyConnectionFunction and Hook:IsSpyConnectionFunction(Connection.Function) then continue end
        if not self:ConnectionIsValid(Connection) then continue end
        table.insert(Processed, Connection)
    end

    return Processed
end

function Process:IsSigmaSpyENV(Env: table): boolean
    return Env == SigmaENV
end

function Process:GetRemoteData(Id: string)
    local RemoteOptions = self.RemoteOptions

	local Existing = RemoteOptions[Id]
	if Existing then return Existing end

	local Data = {
		Excluded = false,
		Blocked = false
	}

	RemoteOptions[Id] = Data
	return Data
end

function Process:CallDiscordRPC(Body: table)
    request({
        Url = "http://127.0.0.1:6463/rpc?v=1",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Origin"] = "https://discord.com/"
        },
        Body = HttpService:JSONEncode(Body)
    })
end

function Process:PromptDiscordInvite(InviteCode: string)
    self:CallDiscordRPC({
        cmd = "INVITE_BROWSER",
        nonce = HttpService:GenerateGUID(false),
        args = {
            code = InviteCode
        }
    })
end

local ProcessCallback = newcclosure(function(Data: RemoteData, Remote, ...): table?
    local OriginalFunc = Data.OriginalFunc
    local Id = Data.Id
    local Method = Data.Method

    local RemoteData = Process:GetRemoteData(Id)
    if RemoteData.Blocked then return {} end

    local Spoof = Process:GetRemoteSpoof(Remote, Method, OriginalFunc, ...)
    if Spoof then return Spoof end

    if not OriginalFunc then return end

    return {
        OriginalFunc(Remote, ...)
    }
end)

function Process:ProcessRemote(Data: RemoteData, Remote, ...): table?
	local Method = Data.Method
    local TransferType = Data.TransferType
    local IsReceive = Data.IsReceive

	if TransferType and not self:RemoteAllowed(Remote, TransferType, Method) then return end

    local Id
	do
		local identity = getthreadidentity()
		setthreadidentity(8)
		local OkDid, Did = pcall(Remote.GetDebugId, Remote)
		setthreadidentity(identity)
		Id = (OkDid and Did) or tostring(Remote):sub(-12)
	end
    local ClassData = self:GetClassData(Remote)
    local Timestamp = tick()

    if IsReceive then
        local RemoteData = self:GetRemoteData(Id)
        if RemoteData.Blocked then
            return
        end
    end

    --// ------------------------------------------------------------------
    --// ГОРЯЧИЙ ПУТЬ. Здесь допустимо только ДЁШЕВОЕ.
    --// ------------------------------------------------------------------

    --// 1) Снимаем вызывающие функции (только debug.info — стек ещё живой).
    --//    Разбор env/скриптов делается позже, в воркере.
    local CallingFunctions = self:GetCallingFunctions(6)

    --// 2) Фиксируем аргументы ДО отправки (иначе игра успеет их изменить)
    local Args = self:CloneArgs(...)

    local ExtraData = self.ExtraData
    if ExtraData then
        self:Merge(Data, ExtraData)
    end

    local CallingScript = getcallingscript()
    self:Merge(Data, {
        Remote = cloneref(Remote),
		CallingScript = CallingScript,
        --// CallingFunction/SourceScript/CallerScript — заполняются
        --// в воркере (ResolveCallers), после реального вызова.
        CallingFunction = nil,
        SourceScript = nil,
        CallerScript = nil,
        Id = Id,
		ClassData = ClassData,
        Timestamp = Timestamp,
        Args = Args
    })

    --// 3) РЕАЛЬНЫЙ ВЫЗОВ РЕМОУТА — СРАЗУ.
    --//    Ни разбора стека, ни сериализации до него: спам-ремоут
    --//    не должен задерживать отправку остальных.
    local ReturnValues = ProcessCallback(Data, Remote, ...)
    Data.ReturnValues = ReturnValues

    --// 4) Логирование — в очередь. Разбор стека + сериализация + UI
    --//    выполняются в воркере (Process:FlushLogQueue), раз в кадр.
    LogQueueTail += 1
    LogQueue[LogQueueTail] = {
        Data = Data,
        Functions = CallingFunctions,
    }

    return ReturnValues
end

function Process:SetAllRemoteData(Key: string, Value)
    local RemoteOptions = self.RemoteOptions
	for RemoteID, Data in next, RemoteOptions do
		Data[Key] = Value
	end
end

function Process:SetRemoteData(Id: string, RemoteData: table)
    local RemoteOptions = self.RemoteOptions
    RemoteOptions[Id] = RemoteData
end

function Process:UpdateRemoteData(Id: string, RemoteData: table)
    Communication:Communicate("RemoteData", Id, RemoteData)
end

function Process:UpdateAllRemoteData(Key: string, Value)
    Communication:Communicate("AllRemoteData", Key, Value)
end

function Process:SetIncomingBlocked(Remote: Instance, Blocked: boolean)
    local ClassData = self:GetClassData(Remote)
    if not ClassData then return end
    if ClassData.IsRemoteFunction then return end
    if ClassData.NoReciveHook then return end

    local Method = ClassData.Receive[1]
    local Signal = Hook:Index(Remote, Method)

    for _, Connection in getconnections(Signal) do
        if self.LogConnectionFunctions[Connection.Function] then continue end
        if Hook.IsSpyConnectionFunction and Hook:IsSpyConnectionFunction(Connection.Function) then continue end

        if Blocked then
            Connection:Disable()
        else
            Connection:Enable()
        end
    end
end

return Process
