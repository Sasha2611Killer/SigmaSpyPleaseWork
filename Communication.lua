type table = {
    [any]: any
}

--// Module
local Module = {
    CommCallbacks = {}
}

local CommWrapper = {}
CommWrapper.__index = CommWrapper

--// Serializer cache
local SerializeCache = setmetatable({}, {__mode = "k"})
local DeserializeCache = setmetatable({}, {__mode = "k"})

--// Предел очереди: при флуде дропаем новые пакеты, а не копим бесконечно
--// (переполненная очередь = захламление главного потока = залипание GUI)
local MaxQueueSize = 200

--// Файл отладки: ошибки пишутся на диск, чтобы не нужно было копировать
--// из GUI, когда GUI залагало
local DebugFile = "SigmaSpy-debug.log"
--// Лимиты: файловый IO в главном потоке сам по себе лагает,
--// поэтому не более 5 записей/сек и 300 строк на сессию
local DebugRate = {Count = 0, Window = tick()}
local DebugLines = 0
local MaxDebugLines = 300

local function DebugLog(...)
    if DebugLines >= MaxDebugLines then return end

    local Now = tick()
    if Now - DebugRate.Window < 1 then
        DebugRate.Count += 1
        if DebugRate.Count > 5 then return end
    else
        DebugRate.Count = 1
        DebugRate.Window = Now
    end
    DebugLines += 1

    local Parts = {}
    for _, Value in {...} do
        table.insert(Parts, tostring(Value))
    end

    local Line = os.date("%X") .. " | " .. table.concat(Parts, " ") .. "\n"
    pcall(appendfile, DebugFile, Line)
end

--// Services
local CoreGui

--// Modules
local Hook
local Channel
local Config
local Process

--// ИЗМЕНЕНО: native comm-функции ищутся сначала в библиотеке Actors,
--// затем в легаси-глобалах (старые executor'ы).
local function GetNativeCommFuncs()
    --// Современная библиотека Actors
    if typeof(Actors) == "table" then
        local Create = Actors.create_comm_channel
        local Get = Actors.get_comm_channel
        if typeof(Create) == "function" and typeof(Get) == "function" then
            return Create, Get
        end
    end

    --// Легаси-глобалы (xAPI-style)
    return create_comm_channel, get_comm_channel
end

function Module:Init(Data)
    local Modules = Data.Modules
    local Services = Data.Services

    Hook = Modules.Hook
    Process = Modules.Process
    Config = Modules.Config or Config
    CoreGui = Services.CoreGui
end

function CommWrapper:Fire(...)
    local Queue = self.Queue

    --// При переполнении дропаем пакет: лучше потерять лог, чем заморозить UI
    if #Queue >= MaxQueueSize then
        return
    end

    table.insert(Queue, {...})
end

function CommWrapper:ProcessArguments(Arguments)
    local Channel = self.Channel
    Channel:Fire(Process:Unpack(Arguments))
end

function CommWrapper:ProcessQueue()
    local Queue = self.Queue

    for _ = 1, #Queue do
        local Arguments = table.remove(Queue, 1)
        if Arguments == nil then break end

        local Ok, Err = pcall(function()
            self:ProcessArguments(Arguments)
        end)
        if not Ok then
            DebugLog("CommWrapper error:", Err)
        end
    end
end

function CommWrapper:BeginQueueService()
    coroutine.wrap(function()
        while wait() do
            self:ProcessQueue()
        end
    end)()
end

function Module:NewCommWrap(Channel: BindableEvent)
    local Base = {
        Queue = setmetatable({}, {__mode = "v"}),
        Channel = Channel,
        Event = Channel.Event
    }

    --// Create new wrapper class
    local Wrapped = setmetatable(Base, CommWrapper)
    Wrapped:BeginQueueService()

    return Wrapped
end

function Module:MakeDebugIdHandler(): BindableFunction
    --// Using BindableFunction as it does not require a thread permission change
    local Remote = Instance.new("BindableFunction")
    function Remote.OnInvoke(Object: Instance): string
        return Object:GetDebugId()
    end

    self.DebugIdRemote = Remote
    self.DebugIdInvoke = Remote.Invoke

    return Remote
end

function Module:GetDebugId(Object: Instance): string
    local Invoke = self.DebugIdInvoke
    local Remote = self.DebugIdRemote
	return Invoke(Remote, Object)
end

function Module:GetHiddenParent(): Instance
    --// Use gethui if it exists
    if gethui then return gethui() end
    return CoreGui
end

function Module:CreateCommChannel(): (number, any)
    --// Use native if it exists (Actors library → legacy globals)
    local Force = Config.ForceUseCustomComm
    local CreateComm = select(1, GetNativeCommFuncs())

    if CreateComm and not Force then
        local Success, ChannelId, Channel = pcall(CreateComm)
        if Success and Channel then
            return ChannelId, Channel
        end
    end

    local Parent = self:GetHiddenParent()
    local ChannelId = math.random(1, 10000000)

    --// BindableEvent
    local Channel = Instance.new("BindableEvent", Parent)
    Channel.Name = ChannelId

    return ChannelId, Channel
end

function Module:GetCommChannel(ChannelId: number): (any, boolean)
    --// Use native if it exists (Actors library → legacy globals)
    local Force = Config.ForceUseCustomComm
    local _, GetComm = GetNativeCommFuncs()

    if GetComm and not Force then
        local Success, NativeChannel = pcall(GetComm, ChannelId)
        if Success and NativeChannel then
            return NativeChannel, false
        end
    end

    local Parent = self:GetHiddenParent()
    local Channel = Parent:FindFirstChild(ChannelId)

    --// Канал не найден (например, ещё не создан актором)
    if not Channel then return nil, false end

    --// Wrap the channel (Prevents thread permission errors)
    local Wrapped = self:NewCommWrap(Channel)
    return Wrapped, true
end

function Module:CheckValue(Value, Inbound: boolean?)
     --// No serializing  needed
    if typeof(Value) ~= "table" then
        return Value
    end

    --// Deserialize
    if Inbound then
        return self:DeserializeTable(Value)
    end

    --// Serialize
    return self:SerializeTable(Value)
end

local Tick = 0
function Module:WaitCheck()
    Tick += 1
    if Tick > 40 then
        Tick = 0
        wait()
    end
end

function Module:MakePacket(Index, Value): table
    self:WaitCheck()
    return {
        Index = self:CheckValue(Index),
        Value = self:CheckValue(Value)
    }
end

function Module:ReadPacket(Packet: table): (any, any)
    if typeof(Packet) ~= "table" then return Packet end

    local Key = self:CheckValue(Packet.Index, true)
    local Value = self:CheckValue(Packet.Value, true)
    self:WaitCheck()

    return Key, Value
end

function Module:SerializeTable(Table: table): table
    --// Check cache for existing
    local Cached = SerializeCache[Table]
    if Cached then return Cached end

    local Serialized = {}
    SerializeCache[Table] = Serialized

    for Index, Value in next, Table do
        local Packet = self:MakePacket(Index, Value)
        table.insert(Serialized, Packet)
    end

    return Serialized
end

function Module:DeserializeTable(Serialized: table): table
    --// Check for cached
    local Cached = DeserializeCache[Serialized]
    if Cached then return Cached end

    local Table = {}
    DeserializeCache[Serialized] = Table

    for _, Packet in next, Serialized do
        local Index, Value = self:ReadPacket(Packet)
        if Index == nil then continue end

        Table[Index] = Value
    end

    return Table
end

function Module:SetChannel(NewChannel: number)
    Channel = NewChannel
end

function Module:ConsolePrint(...)
    local Ok, Err = pcall(self.Communicate, self, "Print", ...)
    if not Ok then
        DebugLog("ConsolePrint error:", Err)
    end
end

--// ИЗМЕНЕНО: xpcall + запись ошибки в файл. Если GUI залагало, ошибки
--// всё равно можно прочитать из workspace-файла SigmaSpy-debug.log
function Module:QueueLog(Data)
    task.spawn(function()
        local Ok, Err = xpcall(function()
            local SerializedArgs = self:SerializeTable(Data.Args)
            Data.Args = SerializedArgs

            self:Communicate("QueueLog", Data)
        end, debug.traceback)

        if not Ok then
            DebugLog("QueueLog error:", Err)
        end
    end)
end

function Module:AddCommCallback(Type: string, Callback: (...any) -> ...any)
    local CommCallbacks = self.CommCallbacks
    CommCallbacks[Type] = Callback
end

function Module:GetCommCallback(Type: string): (...any) -> ...any
    local CommCallbacks = self.CommCallbacks
    return CommCallbacks[Type]
end

function Module:ChannelIndex(Channel, Property: string)
    if typeof(Channel) == "Instance" then
        return Hook:Index(Channel, Property)
    end

    --// Some executors return a UserData type
    return Channel[Property]
end

function Module:Communicate(...)
    local Fire = self:ChannelIndex(Channel, "Fire")
    local identity = getthreadidentity()
    setthreadidentity(8)
    Fire(Channel, ...)
    setthreadidentity(identity)
end

function Module:AddConnection(Callback): RBXScriptConnection
    local Event = self:ChannelIndex(Channel, "Event")
    return Event:Connect(Callback)
end

function Module:AddTypeCallback(Type: string, Callback): RBXScriptConnection
    local Event = self:ChannelIndex(Channel, "Event")
    return Event:Connect(function(RecivedType: string, ...)
        if RecivedType ~= Type then return end
        Callback(...)
    end)
end

function Module:AddTypeCallbacks(Types: table)
    for Type: string, Callback in next, Types do
        self:AddTypeCallback(Type, Callback)
    end
end

function Module:CreateChannel(): number
    local ChannelID, Event = self:CreateCommChannel()

    --// Connect GetCommCallback function
    local ConnectedEvent = self:ChannelIndex(Event, "Event")
    ConnectedEvent:Connect(function(Type: string, ...)
        --// xpcall вызывается с аргументами: внутренняя функция — vararg,
        --// иначе "Cannot use '...' outside of a vararg function"
        local Ok, Err = xpcall(function(...)
            local Callback = self:GetCommCallback(Type)
            if Callback then
                Callback(...)
            end
        end, debug.traceback, ...)

        if not Ok then
            DebugLog("CommCallback error (" .. tostring(Type) .. "):", Err)
        end
    end)

    return ChannelID, Event
end

Module:MakeDebugIdHandler()

return Module
