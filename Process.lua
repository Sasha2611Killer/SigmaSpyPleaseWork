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

    local OldInstancenew; OldInstancenew = hookfunction(getrenv().Instance.new, newcclosure(function(...)
        local Inst = OldInstancenew(...)
        if typeof(Inst) == "Instance" and Process.RemoteClassData[Inst.ClassName] then
            InstanceCreatedRemotes[Inst :: Event] = true
        end
        return Inst
    end))
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

--// [FIX] ВСЕ не-Sigma и не-C Lua-фреймы, начиная с первого.
--// Старая версия стартовала с (Offset - 2) и не отсекала C-функции/дубли,
--// из-за чего SourceScript мог оказаться загрузчиком, C-функцией или nil.
--// Теперь: старт с уровня 1, фильтр по [C] ДО getfenv, дедупликация, до 8.
function Process:FindCallingClosures(_Offset: number): {(...any) -> ...any}
    local Getfenv = Hook:GetOriginalFunc(getfenv)
    local Result = {}
    local Seen = {}

    for Level = 1, 64 do
        --// Конец стека — выходим
        if debug.info(Level, "l") == -1 then break end

        local Function = debug.info(Level, "f")
        if not Function then break end

        --// Дубликат (newcclosure/trampoline) — пропускаем
        if Seen[Function] then continue end
        Seen[Function] = true

        --// C-функция — отсекаем ДО getfenv (иначе getfenv может
        --// вернуть env вызывающего и C-функция «притворится» игрой)
        local SrcOk, Source = pcall(debug.info, Function, "s")
        if SrcOk and Source == "[C]" then continue end

        local Success, Env = pcall(Getfenv, Function)
        if not Success then continue end
        if Env == SigmaENV then continue end

        table.insert(Result, Function)
        if #Result >= 8 then break end
    end

    return Result
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

--// [FIX] Выбор SourceScript/CallerScript по критерию (валидный Instance,
--// отличается от SourceScript), а не по индексам [1]/[2].
function Process:ProcessRemote(Data: RemoteData, Remote, ...): table?
	local Method = Data.Method
    local TransferType = Data.TransferType
    local IsReceive = Data.IsReceive

	if TransferType and not self:RemoteAllowed(Remote, TransferType, Method) then return end

    local Id = Communication:GetDebugId(Remote)
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
    end

    --// [FIX] SourceScript = первый фрейм с валидным Instance;
    --// CallerScript = первый после него с ДРУГИМ скриптом.
    if not IsReceive then
        local Closures = self:FindCallingClosures(6)

        local SourceIndex = nil
        for i, F in Closures do
            local S = self:GetScriptFromFunc(F)
            if typeof(S) == "Instance" then
                CallingFunction = F
                SourceScript = S
                SourceIndex = i
                break
            end
        end

        if SourceIndex then
            for i = SourceIndex + 1, #Closures do
                local S = self:GetScriptFromFunc(Closures[i])
                if typeof(S) == "Instance" and S ~= SourceScript then
                    CallerFunction = Closures[i]
                    CallerScript = S
                    break
                end
            end
        end
    end

    self:Merge(Data, {
        Remote = cloneref(Remote),
		CallingScript = getcallingscript(),
        CallingFunction = CallingFunction,
        SourceScript = SourceScript,
        CallerScript = CallerScript,
        Id = Id,
		ClassData = ClassData,
        Timestamp = Timestamp,
        Args = {...}
    })

    local ReturnValues = ProcessCallback(Data, Remote, ...)
    Data.ReturnValues = ReturnValues

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

return Process
