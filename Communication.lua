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

--// Services
local CoreGui

--// Modules
local Hook
local Channel
local Config
local Process

--// Forward declaration: Init() запускает флашер логов (определён ниже)
local EnsureFlusher

function Module:Init(Data)
    local Modules = Data.Modules
    local Services = Data.Services

    Hook = Modules.Hook
    Process = Modules.Process
    Config = Modules.Config or Config
    CoreGui = Services.CoreGui

    --// Флашер логов поднимаем ОТДЕЛЬНО от хуков, чтобы первый QueueLog
    --// уже не выполнял сериализацию внутри обработчика remote-события.
    task.defer(function()
        EnsureFlusher(Module)
    end)
end

function CommWrapper:Fire(...)
    local Tail = (self.Tail or 0) + 1
    self.Tail = Tail
    self.Queue[Tail] = {...}
end

function CommWrapper:ProcessArguments(Arguments) 
    local Channel = self.Channel
    Channel:Fire(Process:Unpack(Arguments))
end

--// [FIX] Было: for Index = 1, #Queue + table.remove(Queue) — это LIFO
--// (забирали с конца) и таблица ужималась на каждом шаге. Теперь head/tail:
--// честный FIFO, O(1) на элемент, без переиндексации.
function CommWrapper:ProcessQueue(MaxItems: number?)
    local Queue = self.Queue
    local Head = self.Head or 1
    local Tail = self.Tail or 0
    local Limit = MaxItems or 64
    local Processed = 0

    while Head <= Tail and Processed < Limit do
        local Arguments = Queue[Head]
        Queue[Head] = nil
        Head += 1
        Processed += 1

        if Arguments then
            pcall(function()
                self:ProcessArguments(Arguments)
            end)
        end
    end

    if Head > Tail then
        Queue = {}
        Head, Tail = 1, 0
    end

    self.Queue, self.Head, self.Tail = Queue, Head, Tail
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
        --// [FIX] Было {__mode = "v"} — слабые значения, сообщения могли
        --// исчезнуть из очереди при сборке мусора до отправки.
        Queue = {},
        Head = 1,
        Tail = 0,
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

function Module:CreateCommChannel(): (number, BindableEvent)
    --// Use native if it exists
    local Force = Config.ForceUseCustomComm
    if create_comm_channel and not Force then
        return create_comm_channel()
    end

    local Parent = self:GetHiddenParent()
    local ChannelId = math.random(1, 10000000)

    --// BindableEvent
    local Channel = Instance.new("BindableEvent", Parent)
    Channel.Name = ChannelId

    return ChannelId, Channel
end

function Module:GetCommChannel(ChannelId: number): BindableEvent?
    --// Use native if it exists
    local Force = Config.ForceUseCustomComm
    if get_comm_channel and not Force then
        local Channel = get_comm_channel(ChannelId)
        return Channel, false
    end

    local Parent = self:GetHiddenParent()
    local Channel = Parent:FindFirstChild(ChannelId)

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

--// [FIX] Здесь был wait() каждые 40 значений. Это yield, а yield внутри
--// обработчика OnClientEvent/__namecall останавливает поток, в котором
--// движок раздаёт сетевые события: пока мы сериализуем спам одного remote,
--// вызовы ДРУГИХ remote не доставляются вообще (отсюда "приходит с задержкой").
--// Cobalt в этом месте не уступает поток никогда.
--// Функция оставлена как API-заглушка: бюджет уже ограничен размером батча
--// в QueueLog (см. MaxLogsPerFrame).
function Module:WaitCheck()
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
    self:Communicate("Print", ...)
end

--// =====================================================================
--// [Cobalt-style] Конвейер логов
--// =====================================================================
--// КАК У COBALT:
--//   хук -> Log:Call -> дописать запись в лог remote + крошечная
--//   нотификация в очередь. Ни сериализации аргументов, ни UI, ни yield
--//   в хуке. Очередь нотификаций выливается ОДНИМ Fire на Heartbeat.
--//
--// КАК БЫЛО ТУТ:
--//   task.spawn() в QueueLog выполняет тело НЕМЕДЛЕННО (до первого yield),
--//   т.е. вся сериализация + wait() из WaitCheck крутилась внутри
--//   обработчика OnClientEvent. OnClientEvent спамера не отпускал поток,
--//   движок не раздавал следующие сетевые события -> вызов другого remote
--//   "приходил с задержкой". Плюс wait() = yield внутри сетевого колбэка.
--//
--// СТАЛО:
--//   QueueLog - чистый enqueue (O(1), без spawn/Fire/serialize);
--//   один постоянный флашер на VM забирает не больше N логов за кадр;
--//   per-remote лимит ожидающих: спамер не может занять канал целиком.
local LogQueue = {}
local LogQueueHead = 1
local LogQueueTail = 0
local PendingById = {}
local DroppedById = {}

local FlusherStarted = false

local function GetLimit(Name: string, Default: number): number
    local Value = Config and (Config :: any)[Name]
    return typeof(Value) == "number" and Value or Default
end

local function FlushBatch(self)
    local MaxPerFrame = GetLimit("MaxLogsPerFrame", 48)
    local Batch, BatchSize = {}, 0

    while LogQueueHead <= LogQueueTail and BatchSize < MaxPerFrame do
        local Item = LogQueue[LogQueueHead]
        LogQueue[LogQueueHead] = nil
        LogQueueHead += 1

        if Item then
            local Id = Item.Id or 0
            local Pending = (PendingById[Id] or 1) - 1
            PendingById[Id] = if Pending > 0 then Pending else nil

            local Ok, Serialized = pcall(self.SerializeTable, self, Item.Args)
            if Ok then
                Item.Args = Serialized
                BatchSize += 1
                Batch[BatchSize] = Item
            end
            --// Один битый лог не должен убить весь батч — просто пропускаем
        end
    end

    --// Очередь опустела — обнуляем указатели (как у Cobalt)
    if LogQueueHead > LogQueueTail then
        LogQueue = {}
        LogQueueHead, LogQueueTail = 1, 0
    end

    if BatchSize <= 0 then return end

	if rawget(_G, "SIGMA_ACTOR_DEBUG") then
        print("[Dbg] flush:", BatchSize, typeof(Channel))
    end

		if rawget(_G, "SIGMA_ACTOR_DEBUG") then
		for i = 1, BatchSize do
			local It = Batch[i]
			print("[Dbg] send", i, It.Method, typeof(It.Remote), It.Id)
		end
	end

   local Ok, Err = pcall(function()
		local Packet = { "QueueLog", Batch }
		for i = 1, BatchSize do
			Packet[#Packet + 1] = Batch[i].Remote
		end
		self:Communicate(self, table.unpack(Packet))
	end)

    if rawget(_G, "SIGMA_ACTOR_DEBUG") then
        print("[Dbg] flush result:", Ok, Err)
    end
		
    if not Ok then
        -- не warn: строка ошибки может содержать имена функций из списка АС
        self:ConsolePrint("QueueLog error:", tostring(Err):sub(1, 120))
    end

    --// Батч уже скопирован каналом (BindableEvent), ссылки не держим
    table.clear(Batch)
end

EnsureFlusher = function(self)
    if FlusherStarted then return end
    FlusherStarted = true

    task.spawn(function()
		 while true do
            if LogQueueHead <= LogQueueTail then
                pcall(FlushBatch, self)
            end
			task.wait()
		end
	end)
end

function Module:QueueLog(Data)
    --// [FIX] Только enqueue. Никаких Fire, spawn и сериализации в хуке.
    local Id = Data.Id or 0
    local MaxPending = GetLimit("MaxPendingPerRemote", 24)
    local Pending = (PendingById[Id] or 0) + 1

    if Pending > MaxPending then
        --// Этот remote уже переполнил очередь — не пускаем его дальше.
        --// Остальные remote при этом ходят свободно (главная цель).
        DroppedById[Id] = (DroppedById[Id] or 0) + 1
        return
    end

    PendingById[Id] = Pending

    LogQueueTail += 1
    LogQueue[LogQueueTail] = Data
	 if rawget(_G, "SIGMA_ACTOR_DEBUG") then
        print("[Dbg] queue:", Data.Method, Id)
    end
end

--// Сколько вызовов отброшено лимитом (для UI/консоли)
function Module:GetDroppedCount(Id: string?): number
    if Id then return DroppedById[Id] or 0 end
    local Total = 0
    for _, Count in next, DroppedById do
        Total += Count
    end
    return Total
end

function Module:ResetDroppedCount(Id: string?)
    if Id then DroppedById[Id] = nil else DroppedById = {} end
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
    local IsInstance = typeof(Channel) == "Instance"
    local Fire = self:ChannelIndex(Channel, "Fire")

    if not IsInstance then
        --// CommWrapper: Fire(...) — self = Channel (Wrapped), аргументы — ...
        local Ok, Err = pcall(Fire, Channel, ...)
        if not Ok then error(Err, 0) end
        return
    end

    --// Instance: Fire(Channel, ...)
    if typeof(getthreadidentity) ~= "function" or typeof(setthreadidentity) ~= "function" then
        Fire(Channel, ...)
        return
    end

    local Identity = getthreadidentity()
    local Raised = pcall(setthreadidentity, 8)
    local Ok, Err = pcall(Fire, Channel, ...)
    if Raised then pcall(setthreadidentity, Identity) end
    if not Ok then error(Err, 0) end
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
    Event.Event:Connect(function(Type: string, ...)
        local Callback = self:GetCommCallback(Type)
        if Callback then
            Callback(...)
        end
    end)

    return ChannelID, Event
end

Module:MakeDebugIdHandler()

return Module
