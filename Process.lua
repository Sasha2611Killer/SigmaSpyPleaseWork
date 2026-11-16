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
            --// [FIX] Раньше NoReciveHook = true полностью запрещал входящие
            --// BindableEvent.Event. Cobalt их хукает — теперь тоже.
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
            --// OnInvoke тоже должен логироваться (было запрещено)
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
    --// remote -> скрипт, назначивший OnClientInvoke/OnInvoke
    CallbackScripts = setmetatable({}, {__mode = "k"}),
    ConfigOverwrites = {
        [{"sirhurt", "potassium", "wave"}] = {
            ForceUseCustomComm = true
        }
    }
}

local ConnectionScripts = setmetatable({}, {__mode = "k"})

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

    self:BuildRemoteLookups()
end

--// [FIX] Быстрый lookup для __namecall-хука: какие методы вообще являются
--// отправкой. Строится из RemoteClassData, чтобы не дублировать список.
function Process:BuildRemoteLookups()
    local Lookup = {}

    for ClassName, Data in next, self.RemoteClassData do
        local Methods = {}
        for _, Method in next, Data.Send or {} do
            Methods[Method] = true
        end
        Lookup[ClassName] = Methods
    end

    self.RemoteSendLookup = Lookup
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

function Process:RememberConnection(Remote: Instance, Connection: RBXScriptConnection, Script: Instance?)
    if not Script then
        Script = getcallingscript()
    end
    if typeof(Script) ~= "Instance" then return end

    local RemoteCache = ConnectionScripts[Remote]
    if not RemoteCache then
        RemoteCache = setmetatable({}, {__mode = "k"})
        ConnectionScripts[Remote] = RemoteCache
    end

    RemoteCache[Connection] = Script
end

--// Достаём скрипт для сработавшего соединения
function Process:GetConnectionScript(Remote: Instance, Connection: RBXScriptConnection?): Instance?
    local RemoteCache = ConnectionScripts[Remote]
    if not RemoteCache then return nil end

    --// Если соединение известно — сразу отдаём
    if Connection and RemoteCache[Connection] then
        return RemoteCache[Connection]
    end

    --// Иначе первый попавшийся (обычно их мало на один Remote)
    for _, Script in next, RemoteCache do
        return Script
    end

    return nil
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
    if typeof(Remote) ~= "Instance" then return false end

    local IsDebug = Communication ~= nil and Communication.DebugIdRemote == Remote

    local ActiveChannel = Channel
    if WrappedChannel and typeof(ActiveChannel) == "table" then
        ActiveChannel = ActiveChannel.Channel
    end

    local IsChannel = ActiveChannel ~= nil and ActiveChannel == Remote

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

function Process:GetScriptFromSource(Source: string): Instance?
    if type(Source) ~= "string" or Source == "" or Source == "[C]" then
        return nil
    end

    --// Быстрый путь: точное совпадение GetFullName
    local Candidates = { game:GetDescendants() }
    if typeof(getloadedmodules) == "function" then
        table.insert(Candidates, getloadedmodules())
    end
    if typeof(getrunningscripts) == "function" then
        table.insert(Candidates, getrunningscripts())
    end
    if typeof(getscripts) == "function" then
        table.insert(Candidates, getscripts())
    end

    for _, List in Candidates do
        for _, Script in List do
            if not Script:IsA("LuaSourceContainer") then continue end
            local Ok, FullName = pcall(function()
                return Script:GetFullName()
            end)
            if Ok and FullName == Source then
                return Script
            end
        end
    end

    --// Fallback: по имени чанка (последний сегмент)
    local TargetName = Source:match("[%w_]+$")
    if TargetName then
        local Matches = {}
        for _, List in Candidates do
            for _, Script in List do
                if Script.Name == TargetName and Script:IsA("LuaSourceContainer") then
                    table.insert(Matches, Script)
                end
            end
        end
        if #Matches == 1 then
            return Matches[1]
        end
    end

    return nil
end

--// [FIX] ВСЕ не-Sigma Lua-фреймы + script-хинты с C-фреймов.
--// Probe v6 (2026-11-03): стек на Delta ДОСТУПЕН. C-фреймы имеют l == -1,
--// но это НЕ конец стека — идём, пока debug.info(Level,"f") не nil.
--// C-фреймы в Result не добавляем, но их env.script (владелец потока/
--// загрузчик) собираем в Hints. identity 8 поднимается ЛЕНИВО — только
--// если getfenv упал. Страховка на executor'ы без identity-функций.
function Process:FindCallingClosures(_Offset: number?): (table, table)
    local Result = {}
    local Hints = {}
    local Seen = {}

    for Level = 1, 16 do
        local Function = debug.info(Level, "f")
        if not Function then break end
        if Seen[Function] then continue end
        Seen[Function] = true

        local Source = debug.info(Function, "s")
        local IsC = Source == "[C]"

        --// Hints: script из env (если есть)
        local Success, Env = pcall(getfenv, Function)
        if Success and type(Env) == "table" then
            local ScriptHint = rawget(Env, "script")
            if typeof(ScriptHint) == "Instance" then
                table.insert(Hints, ScriptHint)
            end
        end

        if IsC then continue end

        --// Lua-фрейм: берём Source (путь) как строку
        if type(Source) == "string" and #Source > 0 then
            table.insert(Result, { Function = Function, Source = Source })
        end
        if #Result >= 8 then break end
    end

    return Result, Hints
end
--// Обратная совместимость: первый (ближайший) вызывающий closure
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
            ["Content-Type"] = "text/plain"
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

--// [FIX] Receive-атрибуция: какой скрипт владеет конкретным соединением.
--// Connection.Thread — самый надёжный путь; Function/env — fallback.
function Process:GetScriptFromConnection(Connection: table): Instance?
    if typeof(Connection) ~= "table" then return nil end

    if typeof(Connection.Script) == "Instance" then
        return Connection.Script
    end

    local Thread = Connection.Thread
    if Thread and typeof(getscriptfromthread) == "function" then
        local Ok, Script = pcall(getscriptfromthread, Thread)
        if Ok and typeof(Script) == "Instance" then
            return Script
        end
    end

    local Function = Connection.Function
    if typeof(Function) == "function" then
        return self:GetScriptFromFunc(Function)
    end

    return nil
end

--// Скрипт внутри Actor? (LocalScript внутри Actor'а)
function Process:GetActorFromScript(Script: Instance): Instance?
    if typeof(Script) ~= "Instance" then return nil end

    local Ok, Actor = pcall(function()
        return Script:FindFirstAncestorOfClass("Actor")
    end)

    if Ok and typeof(Actor) == "Instance" then
        return Actor
    end

    return nil
end

--// [FIX] Определяем Actor по скрипту-источнику. Это нужно, когда вызов
--// из actor-VM поймал общий oth-хук главного VM (там ExtraData = nil,
--// и без этой проверки в логе всегда было IsActor = false).
function Process:ResolveActor(CallingScript, SourceScript, CallerScript, CallingFunction): Instance?
    for _, Script in {CallingScript, SourceScript, CallerScript} do
        local Actor = self:GetActorFromScript(Script)
        if Actor then return Actor end
    end

    if typeof(CallingFunction) == "function" then
        local Script = self:GetScriptFromFunc(CallingFunction)
        local Actor = self:GetActorFromScript(Script)
        if Actor then return Actor end
    end

    if typeof(get_current_actor) == "function" then
        local Ok, Actor = pcall(get_current_actor)
        if Ok and typeof(Actor) == "Instance" then
            return Actor
        end
    end

    return nil
end

--// [FIX] BindableEvent между actor-VM и main-VM НЕ умеет передавать
--// функции и таблицы с метатаблицами (Cobalt конвертирует их в метаданные
--// вручную). Без этого весь actor-лог падал на Fire и не доходил до UI —
--// отсюда "isActor не пишет" и пропавшие actor-вызовы.
function Process:MakeChannelSafe(Value, Seen)
    local ValueType = typeof(Value)

    if ValueType == "function" then
        local Ok, Name = pcall(debug.info, Value, "n")
        if Ok and type(Name) == "string" and #Name > 0 then
            return `[function {Name}]`
        end
        return "[function]"
    elseif ValueType == "thread" then
        return "[thread]"
    elseif ValueType ~= "table" then
        if ValueType == "userdata" then
            local Ok, Text = pcall(tostring, Value)
            return Ok and Text or "[userdata]"
        end
        return Value
    end

    local Cache = Seen or {}
    local Existing = Cache[Value]
    if Existing then return Existing end

    local Copy = {}
    Cache[Value] = Copy

    for Key, Item in next, Value do
        Copy[self:MakeChannelSafe(Key, Cache)] = self:MakeChannelSafe(Item, Cache)
    end

    return Copy
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
	--// [FIX] Не требуем Function: строка коннекта полезна и без него
	--// (Enabled / Thread / принадлежность actor'у).
	if typeof(Connection) ~= "table" then
		return false
	end

	return Connection.Enabled ~= nil
		or Connection.Function ~= nil
		or Connection.Thread ~= nil
end

function Process:FilterConnections(Signal: RBXScriptSignal): table
	local Processed = {}

	local Ok, Connections = pcall(getconnections, Signal)
	if not Ok or typeof(Connections) ~= "table" then
		return Processed
	end

	for _, Connection in Connections do
		local Function = Connection.Function

		--// Свои логгеры не показываем (они и так в реестре/env-токене)
		if Function and self.LogConnectionFunctions[Function] then
			continue
		end
		if Function and Hook.IsSpyConnectionFunction and Hook:IsSpyConnectionFunction(Function) then
			continue
		end

		if not self:ConnectionIsValid(Connection) then
			continue
		end

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

    local Results = { OriginalFunc(Remote, ...) }

    --// [FIX] RemoteFunction: ответ сервера логируем как Incoming (Cobalt-style)
    local ClassData = Data.ClassData
    if ClassData and ClassData.IsRemoteFunction and not Data.IsReceive then
        local ReceiveMethod = ClassData.Receive and ClassData.Receive[1]
        if ReceiveMethod then
            local ResultData = {
                Remote = Remote,
                Method = ReceiveMethod,
                IsReceive = true,
                MetaMethod = "Callback",
                TransferType = "Receive",
                IsExploit = checkcaller(),
                InvokeKind = "Request",
                Id = Id,
                ClassData = ClassData,
                Timestamp = tick(),
                Args = Data.Args or {},
                InvokeResult = Results,
                CallingScript = Data.CallingScript,
                SourceScript = Data.SourceScript,
                CallerScript = Data.CallerScript,
                CallingFunction = nil,
                IsActor = Data.IsActor,
                Actor = Data.Actor,
            }
            Communication:QueueLog(ResultData)
        end
    end

    return Results
end)

function Process:ProcessRemote(Data: RemoteData, Remote, ...): table?
	local Method = Data.Method
    local TransferType = Data.TransferType
    local IsReceive = Data.IsReceive

	if TransferType and not self:RemoteAllowed(Remote, TransferType, Method) then return end

    local Id
	do
		local HasIdentity = typeof(getthreadidentity) == "function"
			and typeof(setthreadidentity) == "function"
		local Identity = HasIdentity and getthreadidentity() or nil

		if HasIdentity then setthreadidentity(8) end
		local OkDid, Did = pcall(Remote.GetDebugId, Remote)
		if HasIdentity then setthreadidentity(Identity) end

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

    local CallingFunction
    local SourceScript
    local CallerScript = nil
    local CallerFunction = nil

    local ExtraData = self.ExtraData
    if ExtraData then
        self:Merge(Data, ExtraData)
        if Data.IsActor == nil and ExtraData.IsActor then
            Data.IsActor = true
            Data.Actor = ExtraData.Actor
        end
    end

    if not IsReceive then
        local Closures, Hints = self:FindCallingClosures(6)

        for _, Entry in Closures do
            local F = Entry.Function
            local Src = Entry.Source

            --// 1) env.script
            local S = self:GetScriptFromFunc(F)
            if typeof(S) == "Instance" then
                CallingFunction = F
                SourceScript = S
                break
            end

            --// 2) debug.info source -> GetFullName
            local BySource = self:GetScriptFromSource(Src)
            if typeof(BySource) == "Instance" then
                CallingFunction = F
                SourceScript = BySource
                break
            end
        end

        --// 3) fallback: Hints (C-фреймы несут env.script загрузчика)
        if not SourceScript and #Hints > 0 then
            for _, Hint in Hints do
                if typeof(Hint) == "Instance" then
                    SourceScript = Hint
                    break
                end
            end
        end

        --// 4) CallerScript: следующий Lua-фрейм или второй Hint
        if SourceScript then
            for _, Entry in Closures do
                local S = self:GetScriptFromFunc(Entry.Function)
                    or self:GetScriptFromSource(Entry.Source)
                if typeof(S) == "Instance" and S ~= SourceScript then
                    CallerScript = S
                    CallerFunction = Entry.Function
                    break
                end
            end
            if not CallerScript and #Hints > 0 then
                for _, Hint in Hints do
                    if typeof(Hint) == "Instance" and Hint ~= SourceScript then
                        CallerScript = Hint
                        break
                    end
                end
            end
        end
    else
        local ReceiveMethod = ClassData and ClassData.Receive and ClassData.Receive[1]

        if ClassData and ReceiveMethod then
            if ClassData.IsRemoteFunction then
                local CachedScript = self.CallbackScripts[Remote]
                if typeof(CachedScript) == "Instance" then
                    SourceScript = CachedScript
                end

                if typeof(getcallbackvalue) == "function" then
                    local OkCallback, Callback = pcall(getcallbackvalue, Remote, ReceiveMethod)
                    if OkCallback and typeof(Callback) == "function" then
                        CallingFunction = Callback
                        local Script = self:GetScriptFromFunc(Callback)
                        if typeof(Script) == "Instance" and not SourceScript then
                            SourceScript = Script
                        end
                    end
                end
            else
                local OkSignal, Signal = pcall(Hook.Index, Hook, Remote, ReceiveMethod)
                if OkSignal and typeof(Signal) == "RBXScriptSignal" then
                    local Connections = self:FilterConnections(Signal)
                    for _, Connection in Connections do
                        local Script = self:GetScriptFromConnection(Connection)
                        if typeof(Script) == "Instance" then
                            if not SourceScript then
                                SourceScript = Script
                                CallingFunction = Connection.Function
                            elseif Script ~= SourceScript and not CallerScript then
                                CallerScript = Script
                                CallerFunction = Connection.Function
                            end
                        end
                    end
                end
            end
        end
    end

    local CallingScript = getcallingscript()

    local IsActor = ExtraData and ExtraData.IsActor or false
    local Actor = ExtraData and ExtraData.Actor or nil

    if not IsActor then
        local DetectedActor = self:ResolveActor(CallingScript, SourceScript, CallerScript, CallingFunction)
        if DetectedActor then
            IsActor = true
            Actor = Actor or DetectedActor
        end
    end

    if IsReceive and not CallingScript then
        CallingScript = SourceScript
    end

    self:Merge(Data, {
        Remote = cloneref(Remote),
		CallingScript = CallingScript,
        CallingFunction = CallingFunction,
        SourceScript = SourceScript or CallingScript,
        CallerScript = CallerScript,
        Id = Id,
		ClassData = ClassData,
        Timestamp = Timestamp,
        IsActor = IsActor == true,
        Actor = Actor,
        Args = {...}
    })

    local ReturnValues = ProcessCallback(Data, Remote, ...)
    Data.ReturnValues = ReturnValues

    if ExtraData and ExtraData.IsActor then
        Data.OriginalFunc = nil
        Data.CallingFunction = nil
        Data.CallerFunction = nil
        Data.Args = self:MakeChannelSafe(Data.Args)
        Data.ReturnValues = self:MakeChannelSafe(Data.ReturnValues)
    end

    Communication:QueueLog(Data)

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

--// Lookup нужен Hook:BeginHooks ещё до Process:Init
Process:BuildRemoteLookups()

return Process
