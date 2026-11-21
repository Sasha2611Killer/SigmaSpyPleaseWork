local Ui = {
	DefaultEditorContent = [=[--[[
	Sigma Spy, written by depso
	Hooks rewritten and many more fixes!

	Discord: https://discord.gg/bkUkm2vSbv
]]]=],
	LogLimit = 100,
    SeasonLabels = { 
        January = "⛄ %s ⛄", 
        February = "🌨️ %s 🏂", 
        March = "🌹 %s🌺 ", 
        April = "🐣 %s ✝️", 
        May = "🐝 %s 🌞", 
        June = "🌲 %s 🥕", 
        July = "🌊 %s 🌅", 
        August = "☀️ %s 🌞", 
        September = "🍁 %s 🍁", 
        October = "🎃 %s 🎃", 
        November = "🍂 %s 🍂", 
        December = "🎄 %s 🎁"
    },
	Scales = {
		["Mobile"] = UDim2.fromOffset(480, 280),
		["Desktop"] = UDim2.fromOffset(600, 400),
	},
    BaseConfig = {
        Theme = "SigmaSpy",
        NoScroll = true,
    },
	OptionTypes = {
		boolean = "Checkbox",
	},
	DisplayRemoteInfo = {
		"MetaMethod",
		"Method",
		"Remote",
		"SourceScript",
		"CallingScript",
		"CallerScript",
		"IsActor",
		"ScriptHash",
		"Id"
	},

    Window = nil,
    RandomSeed = Random.new(tick()),
	Logs = setmetatable({}, {__mode = "k"}),

	--// [FIX] Было {__mode = "v"}: слабые значения, и любой лог, на который
	--// больше никто не ссылается, мог быть собран GC ещё ДО отрисовки
	--// (то есть пропасть). Очередь должна держать логи сильно.
	LogQueue = {},
	LogQueueHead = 1,
	LogQueueTail = 0,

	--// Сколько логов от одного remote ждёт отрисовки. Спамер упирается
	--// в этот лимит и не вытесняет логи остальных remote.
	MaxPendingPerRemote = 32,

	--// Бюджет отрисовки на кадр (см. ProcessLogQueue)
	MaxLogsPerFrame = 32,

	PendingByRemote = {},
	DroppedByRemote = {},
} 

type table = {
	[any]: any
}

type Log = {
	Remote: Instance,
	Method: string,
	Args: table,
	IsReceive: boolean?,
	MetaMethod: string?,
	OrignalFunc: ((...any) -> ...any)?,
	CallingScript: Instance?,
	CallingFunction: ((...any) -> ...any)?,
	ClassData: table?,
	ReturnValues: table?,
	RemoteData: table?,
	Id: string,
	Selectable: table,
	HeaderData: table,
	ValueSwaps: table,
	Timestamp: number,
	IsExploit: boolean
}

--// Compatibility
local SetClipboard = setclipboard or toclipboard or set_clipboard

--// Libraries
local ReGui = nil

--// Modules
local Flags
local Generation
local Process
local Hook 
local Config
local Communication
local Files

local ActiveData = nil
local RemotesCount = 0

local TextFont = Font.fromEnum(Enum.Font.Code)
local FontSuccess = false
local CommChannel

function Ui:Init(Data)
    local Modules = Data.Modules

	--// Modules
	Flags = Modules.Flags
	Generation = Modules.Generation
	Process = Modules.Process
	Hook = Modules.Hook
	Config = Modules.Config
	Communication = Modules.Communication
	Files = Modules.Files

	--// ReGui
    ReGui = loadstring(game:HttpGet(`{Data.Configuration.RepoUrl}/ReGui.lua`), "ReGui")()
	self:LoadFont()
	self:LoadReGui()
	self:CheckScale()
end

function Ui:SetCommChannel(NewCommChannel: BindableEvent)
	CommChannel = NewCommChannel
end

function Ui:CheckScale()
	local BaseConfig = self.BaseConfig
	local Scales = self.Scales

	local IsMobile = ReGui:IsMobileDevice()
	local Device = IsMobile and "Mobile" or "Desktop"

	BaseConfig.Size = Scales[Device]
end

function Ui:SetClipboard(Content: string)
	SetClipboard(Content)
end

function Ui:TurnSeasonal(Text: string): string
    local SeasonLabels = self.SeasonLabels
    local Month = os.date("%B")
    local Base = SeasonLabels[Month]

    return Base:format(Text)
end

function Ui:LoadFont()
	local FontFile = self.FontJsonFile

	--// Get FontFace AssetId
	local AssetId = Files:LoadCustomasset(FontFile)
	if not AssetId then return end

	--// Create custom FontFace
	local NewFont = Font.new(AssetId)
	TextFont = NewFont
	FontSuccess = true
end

function Ui:SetFontFile(FontFile: string)
    if FontFile and type(FontFile) == "string" and FontFile ~= "" then
        local Success = pcall(function()
            self.FontJsonFile = FontFile
        end)
        if Success then
            return
        end
    end
    
    -- Если не сработало - базовый шрифт
    self.FontJsonFile = nil
end

function Ui:FontWasSuccessful()
	if FontSuccess then return end

	--// Error message
	self:ShowModal({
		"Unfortunately your executor was unable to download the font and therefore switched to the Dark theme",
		"\nIf you would like to use the ImGui theme, \nplease download the font (assets/ProggyClean.ttf)",
		"and put put it in your workspace folder\n(Sigma Spy/assets)"
	})
end

function Ui:LoadReGui()
	local ThemeConfig = Config.ThemeConfig
	ThemeConfig.TextFont = TextFont

	--// ReGui
	ReGui:DefineTheme("SigmaSpy", ThemeConfig)
end

type CreateButtons = {
	Base: table?,
	Buttons: table,
	NoTable: boolean?
}
function Ui:CreateButtons(Parent, Data: CreateButtons)
	local Base = Data.Base or {}
	local Buttons = Data.Buttons
	local NoTable = Data.NoTable

	--// Create table layout
	if not NoTable then
		Parent = Parent:Table({
			MaxColumns = 3
		}):NextRow()
	end

	--// Create buttons
	for _, Button in next, Buttons do
		local Container = Parent
		if not NoTable then
			Container = Parent:NextColumn()
		end

		ReGui:CheckConfig(Button, Base)
		Container:Button(Button)
	end
end

function Ui:CreateWindow(WindowConfig)
    local BaseConfig = self.BaseConfig
	local Config = Process:DeepCloneTable(BaseConfig)
	Process:Merge(Config, WindowConfig)

	--// Create Window
	local Window = ReGui:Window(Config)

	--// Switch to DarkTheme instead of the ImGui theme if the font cannot be loaded
	if not FontSuccess then 
		Window:SetTheme("DarkTheme")
	end
	
	--// Create Window
	return Window
end

type AskConfig = {
	Title: string,
	Content: table,
	Options: table
}
function Ui:AskUser(Config: AskConfig): string
	local Window = self.Window
	local Answered = false

	--// Create modal
	local ModalWindow = Window:PopupModal({
		Title = Config.Title
	})
	ModalWindow:Label({
		Text = table.concat(Config.Content, "\n"),
		TextWrapped = true
	})
	ModalWindow:Separator()

	--// Answers
	local Row = ModalWindow:Row({
		Expanded = true
	})
	for _, Answer in next, Config.Options do
		Row:Button({
			Text = Answer,
			Callback = function()
				Answered = Answer
				ModalWindow:ClosePopup()
			end,
		})
	end

	repeat wait() until Answered
	return Answered
end

function Ui:CreateMainWindow()
	local Window = self:CreateWindow()
	self.Window = Window

	--// Check if the font was successfully downloaded
	self:FontWasSuccessful()
	self:AuraCounterService()

	--// UiVisible flag callback
	Flags:SetFlagCallback("UiVisible", function(self, Visible)
		Window:SetVisible(Visible)
	end)

	return Window
end

function Ui:ShowModal(Lines: table)
	local Window = self.Window
	local Message = table.concat(Lines, "\n")

	--// Modal Window
	local ModalWindow = Window:PopupModal({
		Title = "Sigma Spy"
	})
	ModalWindow:Label({
		Text = Message,
		RichText = true,
		TextWrapped = true
	})
	ModalWindow:Button({
		Text = "Okay",
		Callback = function()
			ModalWindow:ClosePopup()
		end,
	})
end

function Ui:ShowUnsupportedExecutor(Name: string)
	Ui:ShowModal({
		"Unfortunately Sigma Spy is not supported on your executor",
		"The best free option is Swift (discord.gg/getswiftgg)",
		`\nYour executor: {Name}`
	})
end

function Ui:ShowUnsupported(FuncName: string)
	Ui:ShowModal({
		"Unfortunately Sigma Spy is not supported on your executor",
		`\nMissing function: {FuncName}`
	})
end

function Ui:CreateOptionsForDict(Parent, Dict: table, Callback)
	local Options = {}

	--// Dictonary wrap
	for Key, Value in next, Dict do
		Options[Key] = {
			Value = Value,
			Label = Key,
			Callback = function(_, Value)
				Dict[Key] = Value

				--// Invoke callback
				if not Callback then return end
				Callback()
			end
		}
	end

	--// Create elements
	self:CreateElements(Parent, Options)
end

function Ui:CheckKeybindLayout(Container, KeyCode: Enum.KeyCode, Callback)
	if not KeyCode then return Container end

	--// Create Row layout
	Container = Container:Row({
		HorizontalFlex = Enum.UIFlexAlignment.SpaceBetween
	})

	--// Add Keybind element
	Container:Keybind({
		Label = "",
		Value = KeyCode,
		LayoutOrder = 2,
		IgnoreGameProcessed = false,
		Callback = function()
			--// Check if keybinds are enabled
			local Enabled = Flags:GetFlagValue("KeybindsEnabled")
			if not Enabled then return end

			--// Invoke callback
			Callback()
		end,
	})

	return Container
end

function Ui:CreateElements(Parent, Options)
	local OptionTypes = self.OptionTypes
	
	--// Create table layout
	local Table = Parent:Table({
		MaxColumns = 3
	}):NextRow()

	for Name, Data in Options do
		local Value = Data.Value
		local Type = typeof(Value)

		--// Add missing values into options table
		ReGui:CheckConfig(Data, {
			Class = OptionTypes[Type],
			Label = Name,
		})
		
		--// Check if a element type exists for value type
		local Class = Data.Class
		assert(Class, `No {Type} type exists for option`)

		local Container = Table:NextColumn()
		local Checkbox = nil

		--// Check for a keybind layout
		local Keybind = Data.Keybind
		Container = self:CheckKeybindLayout(Container, Keybind, function()
			Checkbox:Toggle()
		end)
		
		--// Create column and element
		Checkbox = Container[Class](Container, Data)
	end
end

--// Boiiii what did you say about Sigma Spy 💀💀
function Ui:DisplayAura()
    local Window = self.Window
    local Rand = self.RandomSeed

	--// Aura (boiiiii)
    local AURA = Rand:NextInteger(1, 9999999)
    local AURADELAY = Rand:NextInteger(1, 5)

	--// Title
	local Title = `Sigma Spy | AURA: {AURA}`
	local Seasonal = self:TurnSeasonal(Title)
    Window:SetTitle(Seasonal)

    wait(AURADELAY)
end

function Ui:AuraCounterService()
    task.spawn(function()
        while true do
            self:DisplayAura()
        end
    end)
end

function Ui:CreateWindowContent(Window)
    --// Window group
    local Layout = Window:List({
        UiPadding = 2,
        HorizontalFlex = Enum.UIFlexAlignment.Fill,
        VerticalFlex = Enum.UIFlexAlignment.Fill,
        FillDirection = Enum.FillDirection.Vertical,
        Fill = true
    })

	--// Remotes list
    self.RemotesList = Layout:Canvas({
        Scroll = true,
        UiPadding = 5,
        AutomaticSize = Enum.AutomaticSize.None,
        FlexMode = Enum.UIFlexMode.None,
        Size = UDim2.new(0, 130, 1, 0)
    })

	--// Tab box
	local InfoSelector = Layout:TabSelector({
        NoAnimation = true,
        Size = UDim2.new(1, -130, 0.4, 0),
    })

	self.InfoSelector = InfoSelector
	self.CanvasLayout = Layout

	--// Make tabs
	self:MakeEditorTab(InfoSelector)
	self:MakeOptionsTab(InfoSelector)
	
	if Config.Debug then
		self:ConsoleTab(InfoSelector)
	end
end

function Ui:ConsoleTab(InfoSelector)
	local Tab = InfoSelector:CreateTab({
		Name = "Console"
	})

	local Console
	local ButtonsRow = Tab:Row()

	ButtonsRow:Button({
		Text = "Clear",
		Callback = function()
			Console:Clear()
		end
	})
	ButtonsRow:Button({
		Text = "Copy",
		Callback = function()
			toclipboard(Console:GetValue())
		end
	})
	ButtonsRow:Button({
		Text = "Pause",
		Callback = function(self)
			local Enabled = not Console.Enabled
			local Text = Enabled and "Pause" or "Paused"
			self.Text = Text

			--// Update console
			Console.Enabled = Enabled
		end,
	})
	ButtonsRow:Expand()

	--// Create console
	Console = Tab:Console({
		Text = "-- Created by depso",
		ReadOnly = true,
		Border = false,
		Fill = true,
		Enabled = true,
		AutoScroll = true,
		RichText = true,
		MaxLines = 50
	})

	self.Console = Console
end

function Ui:ConsoleLog(...: string?)
	local Console = self.Console
	if not Console then return end

	Console:AppendText(...)
end

function Ui:MakeOptionsTab(InfoSelector)
	local Tab = InfoSelector:CreateTab({
		Name = "Options"
	})

	--// Add global options
	Tab:Separator({Text="Logs"})
	self:CreateButtons(Tab, {
		Base = {
			Size = UDim2.new(1, 0, 0, 20),
			AutomaticSize = Enum.AutomaticSize.Y,
		},
		Buttons = {
			{
				Text = "Clear logs",
				Callback = function()
					local Tab = ActiveData and ActiveData.Tab or nil

					--// Remove the Remote tab
					if Tab then
						InfoSelector:RemoveTab(Tab)
					end

					--// Clear all log elements
					ActiveData = nil
					self:ClearLogs()
				end,
			},
			{
				Text = "Clear blocks",
				Callback = function()
					Process:UpdateAllRemoteData("Blocked", false)
				end,
			},
			{
				Text = "Clear excludes",
				Callback = function()
					Process:UpdateAllRemoteData("Excluded", false)
				end,
			},
			{
				Text = "Join Discord",
				Callback = function()
					Process:PromptDiscordInvite("s9ngmUDWgb")
					self:SetClipboard("https://discord.gg/s9ngmUDWgb")
				end,
			},
			{
				Text = "Copy Github",
				Callback = function()
					self:SetClipboard("https://github.com/depthso/Sigma-Spy")
				end,
			},
			{
				Text = "Edit Spoofs",
				Callback = function()
					self:EditFile("Return spoofs.lua", true, function(Window, Content: string)
						Window:Close()
						CommChannel:Fire("UpdateSpoofs", Content)
					end)
				end,
			}
		}
	})

	--// Flag options
	Tab:Separator({Text="Settings"})
	self:CreateElements(Tab, Flags:GetFlags())

	self:AddDetailsSection(Tab)
end

function Ui:AddDetailsSection(OptionsTab)
	OptionsTab:Separator({Text="Information"})
	OptionsTab:BulletText({
		Rows = {
			"Sigma spy - Written by depso!",
			"Libraries: Roblox-Parser, Dear-ReGui",
			"Thank you syn.lua for suggesting I make this",
			"Someone??? Reuploaded sigma spy shit to vps so it works"
		}
	})
end

local function MakeActiveDataCallback(Name: string)
	return function(...)
		if not ActiveData then return end
		return ActiveData[Name](ActiveData, ...)
	end
end

function Ui:MakeEditorTab(InfoSelector)
	local Default = self.DefaultEditorContent
	local SyntaxColors = Config.SyntaxColors

	--// Create tab
	local EditorTab = InfoSelector:CreateTab({
		Name = "Editor"
	})

	--// IDE
	local CodeEditor = EditorTab:CodeEditor({
		Fill = true,
		Editable = true,
		FontSize = 13,
		Colors = SyntaxColors,
		FontFace = TextFont,
		Text = Default
	})

	--// Buttons
	local ButtonsRow = EditorTab:Row()
	self:CreateButtons(ButtonsRow, {
		NoTable = true,
		Buttons = {
			{
				Text = "Copy",
				Callback = function()
					local Script = CodeEditor:GetText()
					self:SetClipboard(Script)
				end
			},
			{
				Text = "Run",
				Callback = function()
					local Script = CodeEditor:GetText()
					local Func, Error = loadstring(Script, "SigmaSpy-USERSCRIPT")

					--// Syntax check
					if not Func then
						self:ShowModal({"Error running script!\n", Error})
						return
					end

					Func()
				end
			},
			{
				Text = "Get return",
				Callback = MakeActiveDataCallback("GetReturn")
			},
			{
				Text = "Script",
				Callback = MakeActiveDataCallback("ScriptOptions")
			},
			{
				Text = "Build",
				Callback = MakeActiveDataCallback("BuildScript")
			},
			{
				Text = "Pop-out",
				Callback = function()
					local Script = CodeEditor:GetText()
					local Tile = ActiveData and ActiveData.Task or "Sigma Spy"
					self:MakeEditorPopoutWindow(Script, {
						Title = Tile
					})
				end
			},
		}
	})
	
	self.CodeEditor = CodeEditor
end

function Ui:ShouldFocus(Tab): boolean
	local InfoSelector = self.InfoSelector
	local ActiveTab = InfoSelector.ActiveTab

	--// If there is an empty tab
	if not ActiveTab then
		return true
	end

	return InfoSelector:CompareTabs(ActiveTab, Tab)
end

function Ui:MakeEditorPopoutWindow(Content: string, WindowConfig: table)
	local Window = self:CreateWindow(WindowConfig)
	local Buttons = WindowConfig.Buttons or {}
	local Colors = Config.SyntaxColors

	local CodeEditor = Window:CodeEditor({
		Text = Content,
		Editable = true,
		Fill = true,
		FontSize = 13,
		Colors = Colors,
		FontFace = TextFont
	})

	--// Default buttons
	table.insert(Buttons, {
		Text = "Copy",
		Callback = function()
			local Script = CodeEditor:GetText()
			self:SetClipboard(Script)
		end
	})

	--// Buttons
	local ButtonsRow = Window:Row()
	self:CreateButtons(ButtonsRow, {
		NoTable = true,
		Buttons = Buttons
	})

	Window:Center()
	return CodeEditor, Window
end

function Ui:EditFile(FilePath: string, InFolder: boolean, OnSaveFunc: ((table, string) -> nil)?)
	local Folder = Files.FolderName
	local CodeEditor, Window

	--// Relative to Sigma Spy folder
	if InFolder then
		FilePath = `{Folder}/{FilePath}`
	end

	--// Get file content
	local Content = readfile(FilePath)
	Content = Content:gsub("\r\n", "\n")
	
	local Buttons = {
		{
			Text = "Save",
			Callback = function()
				local Script = CodeEditor:GetText()
				local Success, Error = loadstring(Script, "SigmaSpy-Editor")

				--// Syntax check
				if not Success then
					self:ShowModal({"Error saving file!\n", Error})
					return
				end
				
				--// Save contents
				writefile(FilePath, Script)

				--// Invoke on save function
				if OnSaveFunc then
					OnSaveFunc(Window, Script)
				end
			end
		}
	}

	--// Create Editor Window
	CodeEditor, Window = self:MakeEditorPopoutWindow(Content, {
		Title = `Editing: {FilePath}`,
		Buttons = Buttons
	})
end

type MenuOptions = {
	[string]: (GuiButton, ...any) -> nil
}
function Ui:MakeButtonMenu(Button: Instance, Unpack: table, Options: MenuOptions)
	local Window = self.Window
	local Popup = Window:PopupCanvas({
		RelativeTo = Button,
		MaxSizeX = 500,
	})

	--// Create Selectables for string, function
	for Name, Func in Options do
		 Popup:Selectable({
			Text = Name,
			Callback = function()
				Func(Process:Unpack(Unpack))
			end,
		})
	end
end

function Ui:RemovePreviousTab(Title: string): boolean
	--// No previous tabs
	if not ActiveData then 
		return false 
	end

	--// TabSelector
	local InfoSelector = self.InfoSelector

	--// Previous elements
	local PreviousTab = ActiveData.Tab
	local PreviousSelectable = ActiveData.Selectable

	--// Remove previous tab and set selectable focus
	local TabFocused = self:ShouldFocus(PreviousTab)
	InfoSelector:RemoveTab(PreviousTab)
	PreviousSelectable:SetSelected(false)

	--// Create new tab
	return TabFocused
end

function Ui:MakeTableHeaders(Table, Rows: table)
	local HeaderRow = Table:HeaderRow()
	for _, Catagory in Rows do
		local Column = HeaderRow:NextColumn()
		Column:Label({Text=Catagory})
	end
end

function Ui:Decompile(Editor: table, Script: Script)
	local Header = "--BOOIIII THIS IS SO TUFF FLIPPY SKIBIDI AURA (SIGMA SPY)"
	Editor:SetText("--Decompiling... +9999999 AURA (mango phonk)")

	--// Decompile script
	local Decompiled, IsError = Process:Decompile(Script)

	--// Add header for successful decompilations
	if not IsError then
		Decompiled = `{Header}\n{Decompiled}`
	end

	Editor:SetText(Decompiled)
end

type DisplayTableConfig = {
	Rows: table,
	Flags: table?,
	ToDisplay: table,
	Table: table
}
function Ui:DisplayTable(Parent, Config: DisplayTableConfig): table
	--// Configuration
	local Rows = Config.Rows
	local Flags = Config.Flags
	local DataTable = Config.Table
	local ToDisplay = Config.ToDisplay

	Flags.MaxColumns = #Rows

	--// Create table
	local Table = Parent:Table(Flags)

	--// Table headers
	self:MakeTableHeaders(Table, Rows)

	--// Table layout
	for RowIndex, Name in ToDisplay do
		local Row = Table:Row()
		
		--// Create Columns
		for Count, Catagory in Rows do
			local Column = Row:NextColumn()
			
			--// Value text. false/0 тоже отображаем (только nil пропускаем) —
			--// иначе IsActor=false исчезал из таблицы
			local Value = Catagory == "Name" and Name or DataTable[Name]
			if Value == nil then continue end

			--// Create filtered label
			local String = self:FilterName(`{Value}`, 150)
			Column:Label({Text=String})
		end
	end

	return Table
end

function Ui:SetFocusedRemote(Data)
	--// Unpack remote data
	local Remote = Data.Remote
	local Method = Data.Method
	local IsReceive = Data.IsReceive
	local Script = Data.CallingScript
	local ClassData = Data.ClassData
	local HeaderData = Data.HeaderData
	local ValueSwaps = Data.ValueSwaps
	local Args = Data.Args
	local Id = Data.Id

	--// Flags
	local TableArgs = Flags:GetFlagValue("TableArgs")
	local NoVariables = Flags:GetFlagValue("NoVariables")

	--// IsActor нормализуем в явный boolean (иначе в таблице пустота)
	Data.IsActor = Data.IsActor == true

	--// Unpack info
	local RemoteData = Process:GetRemoteData(Id)
	local IsRemoteFunction = ClassData.IsRemoteFunction
	local RemoteName = self:FilterName(`{Remote}`, 50)

	--// UI data
	local CodeEditor = self.CodeEditor
	local ToDisplay = self.DisplayRemoteInfo
	local InfoSelector = self.InfoSelector

	local TabFocused = self:RemovePreviousTab()
	local Tab = InfoSelector:CreateTab({
		Name = self:FilterName(`Remote: {RemoteName}`, 50),
		Focused = TabFocused
	})

	--// Create new parser
	local Module = Generation:NewParser({
		NoVariables = NoVariables
	})
	local Parser = Module.Parser
	local Formatter = Module.Formatter
	Formatter:SetValueSwaps(ValueSwaps)

	--// Set this log to be selected
	ActiveData = Data
	Data.Tab = Tab
	Data.Selectable:SetSelected(true)

	local function SetIDEText(Content: string, Task: string?)
		Data.Task = Task or "Sigma Spy"
		CodeEditor:SetText(Content)
	end
	local function DataConnection(Name, ...)
		local Args = {...}
		return function()
			return Data[Name](Data, Process:Unpack(Args))
		end
	end
	local function ScriptCheck(Script, NoMissingCheck: boolean): boolean?
		--// Reject client events
		if IsReceive then 
			Ui:ShowModal({
				"Recieves do not have a script because it's a Connection"
			})
			return 
		end

		--// Check if script exists
		if not Script and not NoMissingCheck then 
			Ui:ShowModal({"The Script has been destroyed by the game (-9999999 AURA)"})
			return
		end

		return true
	end

	--// Functions
	function Data:ScriptOptions(Button: GuiButton)
		Ui:MakeButtonMenu(Button, {self}, {
			["Caller Info"] = DataConnection("GenerateInfo"),
			["Decompile"] = DataConnection("Decompile", "SourceScript"),
			["Decompile Calling"] = DataConnection("Decompile", "CallingScript"),
			["Repeat Call"] = DataConnection("RepeatCall"),
			["Save Bytecode"] = DataConnection("SaveBytecode"),
		})
	end
	function Data:BuildScript(Button: GuiButton)
		Ui:MakeButtonMenu(Button, {self}, {
			["Save"] = DataConnection("SaveScript"),
			["Call Remote"] = DataConnection("MakeScript", "Remote"),
			["Block Remote"] = DataConnection("MakeScript", "Block"),
			["Repeat For"] = DataConnection("MakeScript", "Repeat"),
			["Spam Remote"] = DataConnection("MakeScript", "Spam")
		})
	end
	function Data:SaveScript()
		local FilePath = Generation:TimeStampFile(self.Task)
		writefile(FilePath, CodeEditor:GetText())

		Ui:ShowModal({"Saved script to", FilePath})
	end
	function Data:SaveBytecode()
		--// Problem check
		if not ScriptCheck(Script, true) then return end

		--// getscriptbytecode
    	local Success, Bytecode = pcall(getscriptbytecode, Script)
		if not Success then
			Ui:ShowModal({"Failed to get Scripte bytecode (-9999999 AURA)"})
			return
		end

		--// Save file
		local PathBase = `{Script} %s.txt`
		local FilePath = Generation:TimeStampFile(PathBase)
		writefile(FilePath, Bytecode)

		Ui:ShowModal({"Saved bytecode to", FilePath})
	end
	function Data:MakeScript(ScriptType: string)
		local Script = Generation:RemoteScript(Module, self, ScriptType)
		SetIDEText(Script, `Editing: {RemoteName}.lua`)
	end
	function Data:RepeatCall()
		local Signal = Hook:Index(Remote, Method)

		if IsReceive then
			firesignal(Signal, Process:Unpack(Args))
		else
			Signal(Remote, Process:Unpack(Args))
		end
	end
	function Data:GetReturn()
		local ReturnValues = self.ReturnValues

		--// Error messages
		if not IsRemoteFunction then
			Ui:ShowModal({"The Remote is not a Remote Function (-9999999 AURA)"})
			return
		end
		if not ReturnValues then
			Ui:ShowModal({"No return values (-9999999 AURA)"})
			return
		end

		--// Generate script
		local Script = Generation:TableScript(Module, ReturnValues)
		SetIDEText(Script, `Return Values for: {RemoteName}`)
	end
	function Data:GenerateInfo()
		--// Problem check
		if not ScriptCheck(nil, true) then return end

		--// Generate script
		local Script = Generation:AdvancedInfo(Module, self)
		SetIDEText(Script, `Advanced Info for: {RemoteName}`)
	end
	function Data:Decompile(WhichScript: string)
		--// Receive: у события нет одного скрипта, но обработчики видны
		--// через getconnections — открываем список соединений с Decompile
		--// для каждого (Cobalt-style attribution)
		if IsReceive then
			local RecvMethod = ClassData.Receive[1]
			local Signal
			if IsRemoteFunction then
				--// OnClientInvoke — callback-значение: читать Remote[..]
				--// запрещено движком ("get is not available") — только
				--// getcallbackvalue
				local Ok, CallbackValue = pcall(getcallbackvalue, Remote, RecvMethod)
				Signal = Ok and CallbackValue or nil
			else
				Signal = Hook:Index(Remote, RecvMethod)
			end
			Ui:ViewConnections(RemoteName, Signal)
			return
		end

		local DecompilePopout = Flags:GetFlagValue("DecompilePopout")
		local ToDecompile = nil
		local UsedFallback = false

		--// SourceScript = модуль-источник вызова (может быть удалён, но
		--// загружен — IsScriptAvailable это пропускает). Если модуль не
		--// найден — fallback на CallerScript (загрузчик).
		--// "CallingScript"-ветка = именно загрузчик (второй не-Sigma
		--// фрейм), fallback — getcallingscript().
		if WhichScript == "SourceScript" then
			ToDecompile = Data.SourceScript
			if not ToDecompile then
				ToDecompile = Data.CallerScript
				UsedFallback = true
			end
		else
			ToDecompile = Data.CallerScript
			if not ToDecompile then
				ToDecompile = Data.CallingScript
				UsedFallback = true
			end
		end

		--// Ничего не нашли — честное сообщение вместо ошибки байткода
		if not ToDecompile then
			Ui:ShowModal({"Script not found: neither source nor caller could be resolved"})
			return
		end

		--// Полностью мёртвые ссылки отсекаем, НО загруженные-через-другой-
		--// скрипт-и-удалённые остаются доступными (getscriptbytecode их отдаёт)
		if typeof(ToDecompile) == "Instance" and not Process:IsScriptAvailable(ToDecompile) then
			Ui:ShowModal({"The Script has been destroyed by the game (-9999999 AURA)"})
			return
		end

		local Editor = CodeEditor

		--// Problem check
		if not ScriptCheck(ToDecompile, true) then return end
		local Task = Ui:FilterName(`Viewing: {ToDecompile}.lua`, 200)
		if WhichScript == "CallingScript" then
			Task = `{Task} (caller)`
		end
		if UsedFallback then
			Task = `{Task} (fallback)`
		end
		
		--// Automatically Pop-out the editor for decompiling if enabled
		if DecompilePopout then
			Editor = Ui:MakeEditorPopoutWindow("", {
				Title = Task
			})
		end

		Ui:Decompile(Editor, ToDecompile)
	end
	
	--// RemoteOptions (изолировано: внутренние ошибки ReGui при
	--// построении таблицы опций не должны ронять всю вкладку remote)
	xpcall(function()
		self:CreateOptionsForDict(Tab, RemoteData, function()
			Process:UpdateRemoteData(Id, RemoteData)
			--// Блок входящих: реально отключаем игровые соединения
			--// сигнала (Cobalt-style), а не только помечаем флагом
			pcall(function()
				Process:SetIncomingBlocked(Remote, RemoteData.Blocked == true)
			end)
		end)
	end, function(Err)
		-- не warn: консоль игры сканируется АС, шум не нужен
		self:ConsoleLog("RemoteOptions:", tostring(Err):sub(1, 160))
	end)

	--// Instance options
	self:CreateButtons(Tab, {
		Base = {
			Size = UDim2.new(1, 0, 0, 20),
			AutomaticSize = Enum.AutomaticSize.Y,
		},
		Buttons = {
			{
				Text = "Copy script hash",
				Callback = function()
					SetClipboard(Data.ScriptHash or "N/A (hash unavailable)")
				end,
			},
			{
				Text = "Copy script path",
				Callback = function()
					--// CallingScript может быть nil/уничтожен —
					--// фолбэк на SourceScript, затем tostring
					local Target = Script
					if typeof(Target) ~= "Instance" then
						Target = Data.SourceScript
					end

					local Ok, Path = pcall(function()
						return Parser:MakePathString({
							Object = Target,
							NoVariables = true
						})
					end)

					if Ok and Path then
						SetClipboard(Path)
					else
						SetClipboard(tostring(Target))
					end
				end,
			},
			{
				Text = "Copy remote path",
				Callback = function()
					SetClipboard(Parser:MakePathString({
						Object = Remote,
						NoVariables = true
					}))
				end,
			},
			{
				Text = "Remove log",
				Callback = function()
					InfoSelector:RemoveTab(Tab)
					Data.Selectable:Remove()
					HeaderData:Remove()
					ActiveData = nil
				end,
			},
			{
				Text = "Dump logs",
				Callback = function()
					local Logs = HeaderData.Entries
					local FilePath = Generation:DumpLogs(Logs)
					self:ShowModal({"Saved dump to", FilePath})
				end,
			},
			{
				Text = "View Connections",
				Callback = function()
					local RecvMethod = ClassData.Receive[1]
					local Signal
					if IsRemoteFunction then
						--// Чтение OnClientInvoke запрещено движком —
						--// только getcallbackvalue
						local Ok, CallbackValue = pcall(getcallbackvalue, Remote, RecvMethod)
						Signal = Ok and CallbackValue or nil
					else
						Signal = Remote[RecvMethod]
					end
					self:ViewConnections(RemoteName, Signal)
				end,
			}
		}
	})

	--// Хеш скрипта (getscripthash): SourceScript, иначе CallingScript.
	--// Показывается в инфо-таблице, копируется кнопкой ниже.
	local HashSource = Data.SourceScript or Data.CallerScript
	Data.ScriptHash = HashSource and Process:GetScriptHash(HashSource) or nil

	--// Remote information table
	self:DisplayTable(Tab, {
		Rows = {"Name", "Value"},
		Table = Data,
		ToDisplay = ToDisplay,
		Flags = {
			Border = true,
			RowBackground = true,
			MaxColumns = 2
		}
	})
	
	--// Arguments table script
	if TableArgs then
		local Parsed = Generation:TableScript(Module, Args)
		SetIDEText(Parsed, `Arguments for {RemoteName}`)
		return
	end

	--// Remote call script
	Data:MakeScript("Remote")
end

--// Окно для callback-значений (OnClientInvoke / OnInvoke):
--// показываем скрипт-владельца колбэка с кнопкой Decompile
function Ui:ViewCallback(RemoteName: string, Callback: any)
	local Window = self:CreateWindow({
		Title = `Callback for: {RemoteName}`,
		Size = UDim2.fromOffset(450, 110)
	})

	local Script = nil
	if typeof(Callback) == "function" then
		Script = Process:GetScriptFromFunc(Callback)
	end

	local Row = Window:Row()
	Row:Label({
		Text = `Script: {Script and Script:GetFullName() or "Unknown (no script in env)"}`
	})

	if Script and Process:IsScriptAvailable(Script) then
		Row:Button({
			Text = "Decompile",
			Callback = function()
				local Task = self:FilterName(`Viewing: {Script}.lua`, 200)
				local Editor = self:MakeEditorPopoutWindow(nil, {
					Title = Task
				})
				self:Decompile(Editor, Script)
			end
		})
	end

	Window:Center()
	return Window
end

function Ui:ViewConnections(RemoteName: string, Signal: RBXScriptSignal)
	if typeof(Signal) ~= "RBXScriptSignal" then
		return self:ViewCallback(RemoteName, Signal)
	end

	-- // Колонки. WrittenIn — синтетическая, её нельзя слать в FilterConnections
	local ToDisplay = {
		"Enabled", "ForeignState", "LuaConnection", "Function", "Thread", "Script", "WrittenIn",
	}
	local Properties = {
		"Enabled", "ForeignState", "LuaConnection", "Function", "Thread", "Script",
	}

	local Connections = Process:FilterConnections(Signal, Properties)
	local Count = #Connections

	local Window = self:CreateWindow({
		Title = `Connections for: {RemoteName} ({Count})`,
		Size = UDim2.fromOffset(1000, 400),
	})

	-- // Тулбар: всего подписок + массовое снятие
	local Toolbar = Window:Row()
	Toolbar:Label({ Text = `Total: {Count}` })
	Toolbar:Expand()

	-- // Скролл: 24+ коннектов листаются колесом, шапка окна остаётся на месте
	local Scroll = Window:Canvas({
		Scroll = true,
		UiPadding = 5,
		AutomaticSize = Enum.AutomaticSize.None,
		Size = UDim2.new(1, 0, 1, 0),
	})

	local Table = Scroll:Table({
		Border = true,
		RowBackground = true,
		MaxColumns = 7,
	})

	-- // Короткий текст для ячейки (в буфер идёт полное значение)
	local CellLimit = 18
	local function ShortText(Value)
		local String = tostring(Value):gsub("[\n\r\t]+", " ")
		if #String > CellLimit then
			String = String:sub(1, CellLimit - 1) .. "…"
		end
		return String
	end

	local function HexTail(Value, Prefix)
		local Hex = tostring(Value):match("0x(%x+)")
		return Hex and (Prefix .. "…" .. Hex:sub(-4)) or "?"
	end

	local Display = {
		Function  = function(v) return HexTail(v, "fn ") end,          -- fn …e5ba
		Thread    = function(v) return HexTail(v, "th ") end,          -- th …17e8
		Script    = function(v) return typeof(v) == "Instance" and v.Name or "?" end,
		WrittenIn = function(v)                                        -- MatchController:31
			local String = tostring(v)
			local Path, Line = String:match("^(.-):(%d+)")
			if not Path then return ShortText(String) end
			local Last = Path:match("([^%.]+)$") or Path
			return ShortText(`{Last}:{Line}`)
		end,
	}

	local function SafeDecompile(Value)
		if typeof(Value) ~= "Instance" then return end
		local Task = self:FilterName(`Viewing: {Value.Name}.lua`, 200)
		local Editor = self:MakeEditorPopoutWindow(nil, { Title = Task })
		self:Decompile(Editor, Value)
	end

	local function CopyButton(Row, Value)
		if Value == nil then return end
		Row:Button({
			Text = "Copy",
			Callback = function()
				local Text = tostring(Value)
				local Ok = pcall(function()
					self:SetClipboard(Text)
				end)
				if not Ok then
					self:ConsoleLog("Clipboard unavailable:", Text)
				end
			end,
		})
	end

	local ButtonsForValues = {
		["Script"] = function(Row, Value)
			if typeof(Value) ~= "Instance" then return end
			Row:Button({
				Text = "Decompile",
				Callback = function() SafeDecompile(Value) end,
			})
			CopyButton(Row, Value:GetFullName())
		end,

		["Enabled"] = function(Row, Enabled, Connection)
			Row:Button({
				Text = Enabled and "Disable" or "Enable",
				Callback = function(self)
					Enabled = not Enabled
					self.Text = Enabled and "Disable" or "Enable"
					if Enabled then Connection:Enable() else Connection:Disable() end
				end,
			})
		end,

		["Thread"]    = function(Row, Value) CopyButton(Row, Value) end,
		["Function"]  = function(Row, Value) CopyButton(Row, Value) end,
		["WrittenIn"] = function(Row, Value) CopyButton(Row, Value) end,
	}

	-- // Скрипт-источник соединения: 3 захода
	local function GetConnectionScript(Connection)
		if typeof(Connection.Script) == "Instance" then
			return Connection.Script
		end

		if Connection.Thread and typeof(getscriptfromthread) == "function" then
			local Ok, Script = pcall(getscriptfromthread, Connection.Thread)
			if Ok and typeof(Script) == "Instance" then
				return Script
			end
		end

		local Fn = Connection.Function
		if typeof(Fn) == "function" then
			local Ok, FromEnv = pcall(function()
				return Process:GetScriptFromFunc(Fn)
			end)
			if Ok and typeof(FromEnv) == "Instance" then
				return FromEnv
			end
		end

		return nil
	end

	-- // Путь из debug.info (строка) — отдельная колонка
	local function GetWrittenIn(Connection)
		local Fn = Connection.Function
		if typeof(Fn) ~= "function" then
			return typeof(Fn) == "nil" and "?" or `<{typeof(Fn)}>`
		end
		local Ok, Src, Line, Name = pcall(debug.info, Fn, "sln")
		if not Ok or not Src then return "?" end
		local NameStr = (type(Name) == "string" and Name ~= "") and Name or "<anonymous>"
		return `{Src}:{Line} ({NameStr})`
	end

	-- // Заголовки
	self:MakeTableHeaders(Table, ToDisplay)

	for _, Connection in Connections do
		local Row = Table:Row()

		for _, Property in ToDisplay do
			local Column = Row:NextColumn()

			local Value
			if Property == "Script" then
				Value = GetConnectionScript(Connection)
			elseif Property == "WrittenIn" then
				Value = GetWrittenIn(Connection)
			else
				Value = Connection[Property]
			end

			local Shown = Display[Property] and Display[Property](Value) or ShortText(Value)

			-- // Текст сверху
			Column:Label({
				Text = Shown,
				TextXAlignment = Enum.TextXAlignment.Left,
			})

			-- // Кнопки снизу, своей строкой
			local Callback = ButtonsForValues[Property]
			if Callback then
				Callback(Column:Row(), Value, Connection)
			end
		end
	end

	Window:Center()
end

function Ui:GetRemoteHeader(Data: Log)
	local LogLimit = self.LogLimit
	local Logs = self.Logs
	local RemotesList = self.RemotesList

	--// Remote info
	local Id = Data.Id
	local Remote = Data.Remote
	local RemoteName = self:FilterName(`{Remote}`, 30)

	--// NoTreeNodes
	local NoTreeNodes = Flags:GetFlagValue("NoTreeNodes")

	--// Check for existing TreeNode
	local Existing = Logs[Id]
	if Existing then return Existing end

	--// Header data
	local HeaderData = {	
		LogCount = 0,
		Data = Data,
		Entries = {}
	}

	--// Increment treenode count
	RemotesCount += 1

	--// Create new treenode element
	if not NoTreeNodes then
		HeaderData.TreeNode = RemotesList:TreeNode({
			LayoutOrder = -1 * RemotesCount,
			Title = RemoteName
		})
	end

	function HeaderData:CheckLimit()
		local Entries = self.Entries
		if #Entries < LogLimit then return end
			
		--// Get and remove last element
		local Log = table.remove(Entries, 1)
		Log.Selectable:Remove()
	end

	function HeaderData:LogAdded(Data)
		--// Increment log count
		self.LogCount += 1
		self:CheckLimit()

		--// Add entry
		local Entries = self.Entries
		table.insert(Entries, Data)
		
		return self
	end

	function HeaderData:Remove()
		--// Remove TreeNode
		local TreeNode = self.TreeNode
		if TreeNode then
			TreeNode:Remove()
		end

		--// Clear tables from memory
		Logs[Id] = nil
		table.clear(HeaderData)
	end

	Logs[Id] = HeaderData
	return HeaderData
end

function Ui:ClearLogs()
	local Logs = self.Logs
	local RemotesList = self.RemotesList

	--// Clear all elements
	RemotesCount = 0
	RemotesList:ClearChildElements()

	--// Ранний дедуп-счётчик тоже сбрасываем
	self.DedupStore = nil

	--// [FIX] Очередь отрисовки и лимиты тоже чистим, иначе после Clear
	--// в очередь вываливались все накопленные спам-логи.
	self.LogQueue = {}
	self.LogQueueHead = 1
	self.LogQueueTail = 0
	self.PendingByRemote = {}
	self.DroppedByRemote = {}

	--// Clear logs from memory
	table.clear(Logs)
end

function Ui:QueueLog(Data)
	--// [FIX] Communication теперь шлёт БАТЧ (Cobalt-style), а не одиночный
	--// лог. Раньше батч прилетал в Ui:QueueLog как один Data, guard ниже
	--// видел Data.Remote == nil и молча выбрасывал ВСЁ. Принимаем оба вида.
	if Data[1] ~= nil then
		for Index = 1, #Data do
			self:QueueLog(Data[Index])
		end
		return
	end

	--// [FIX] Actor-логи: Remote может быть nil на входе (инстанс не
	--// пережил границу Lua-state), но Id есть — пускаем дальше.
	--// CreateLog подставит заглушку, если нужно.
	if not Data.Id then return end

	--// [OPT] Дешёвые фильтры ДО тяжёлых копий аргументов
	if Flags:GetFlagValue("Paused") then return end
	if Data.IsReceive and not Flags:GetFlagValue("LogRecives") then return end
	if Data.IsExploit and not Data.IsActor and not Flags:GetFlagValue("LogExploit") then return end

	--// [FIX] Проверки, требующие валидный Remote — только если он есть
	if typeof(Data.Remote) == "Instance" then
		if Flags:GetFlagValue("IgnoreNil") and Hook:Index(Data.Remote, "Parent") == nil then
			return
		end
	end

	if Process:GetRemoteData(Data.Id).Excluded then return end

	--// [OPT] Ранний дедуп (IgnoreDuplicates): сравниваем СЫРЫЕ
	--// сериализованные аргументы до десериализации/DeepClone/UI.
	if Flags:GetFlagValue("IgnoreDuplicates") then
		local Store = self.DedupStore
		if not Store then
			Store = {}
			self.DedupStore = Store
		end

		local ById = Store[Data.Id]
		if not ById then
			ById = {}
			Store[Data.Id] = ById
		end

		if Process:DeepEquals(Data.Args, ById[Data.Method]) then
			return
		end
		ById[Data.Method] = Data.Args
	end

	--// [FIX] Per-remote лимит ожидающих. Флуд одного remote упирается
	--// в собственный счётчик и НЕ вытесняет логи остальных remote.
	local Pending = self.PendingByRemote
	local Count = Pending[Data.Id] or 0
	if Count >= self.MaxPendingPerRemote then
		self.DroppedByRemote[Data.Id] = (self.DroppedByRemote[Data.Id] or 0) + 1
		return
	end
	Pending[Data.Id] = Count + 1

	--// Args оставляем сериализованными: свежую таблицу всё равно создаёт
	--// DeserializeTable в CreateLog. Лишний DeepClone на каждый лог убран.
	if Data.ReturnValues then
		Data.ReturnValues = Process:DeepCloneTable(Data.ReturnValues)
	end

	local Tail = self.LogQueueTail + 1
	self.LogQueueTail = Tail
	self.LogQueue[Tail] = Data
end

function Ui:ProcessLogQueue()
	local Queue = self.LogQueue
	local Head = self.LogQueueHead or 1
	local Tail = self.LogQueueTail or 0
	if Head > Tail then return end

	--// [FIX] Было: for Index, Data in next, Queue + table.remove(Queue, Index)
	--// — O(n^2), и из-за сдвига индексов через next обрабатывалась только
	--// половина очереди (логи терялись). Теперь head/tail FIFO.
	--// Плюс бюджет на кадр: один спамер не может занять весь кадр.
	local Budget = self.MaxLogsPerFrame
	local Pending = self.PendingByRemote
	local Processed = 0

	while Head <= Tail and Processed < Budget do
		local Data = Queue[Head]
		Queue[Head] = nil

		--// Сдвигаем указатель ДО отрисовки: CreateLog может уступать поток
		--// (декомпиляция/запросы), а очередь в это время пополняется.
		Head += 1
		self.LogQueueHead = Head
		Processed += 1

		if Data then
			local RemoteId = Data.Id or 0
			local PendingCount = (Pending[RemoteId] or 1) - 1
			Pending[RemoteId] = if PendingCount > 0 then PendingCount else nil

			--// Один кривой лог не должен ронять обработку остальных
			pcall(self.CreateLog, self, Data)
		end
	end

	self.LogQueueHead = Head

	--// Полностью опустели и новых вставок не было — обнуляем очередь
	if self.LogQueueHead > self.LogQueueTail then
		self.LogQueue = {}
		self.LogQueueHead = 1
		self.LogQueueTail = 0
	end
end

function Ui:BeginLogService()
	coroutine.wrap(function()
		while true do
			self:ProcessLogQueue()
			task.wait()
		end
	end)()
end

function Ui:FilterName(Name: string, CharacterLimit: number?): string
	local Trimmed = Name:sub(1, CharacterLimit or 20)
	local Filtred = Trimmed:gsub("[\n\r]", " ")
	Filtred = Generation:MakePrintable(Filtred)

	return Filtred
end

function Ui:CreateLog(Data: Log)
	--// [FIX] Восстанавливаем Remote из сериализованной таблицы (actor-логи)
	if type(Data.Remote) == "table" and Data.Remote.__RemoteInstance then
		local DebugId = Data.Remote.DebugId
		local Name = Data.Remote.Name or "Remote"
		local ClassName = Data.Remote.ClassName or "RemoteEvent"
		local Found = nil
		
		--// Ищем инстанс по DebugId в main-state (только для actor-логов)
		local SearchOk = pcall(function()
			for _, Remote in next, game:GetDescendants() do
				if typeof(Remote) == "Instance" and Remote.Name == Name then
					local ok, id = pcall(function()
						return Remote:GetDebugId()
					end)
					if ok and id == DebugId then
						Found = Remote
						break
					end
				end
			end
		end)
		
		if Found then
			Data.Remote = cloneref(Found)
		else
			--// Не нашли — заглушка с метаданными
			Data.Remote = setmetatable({
				Name = Name,
				ClassName = ClassName,
			}, {
				__tostring = function() return Name end,
				__index = function(_, key)
					if key == "GetDebugId" then return function() return DebugId end end
					if key == "Parent" then return game:GetService("ReplicatedStorage") end
					if key == "Name" then return Name end
					if key == "ClassName" then return ClassName end
					return nil
				end,
			})
		end
	end

	--// Guard: если Remote всё ещё не валиден — пропускаем
	if typeof(Data.Remote) ~= "Instance" and type(Data.Remote) ~= "table" then
		return
	end

	--// Unpack log data
    local Remote = Data.Remote
	local Method = Data.Method
    local Args = Data.Args
    local IsReceive = Data.IsReceive
	local Id = Data.Id
	local Timestamp = Data.Timestamp
	local IsExploit = Data.IsExploit
	
	local IsNilParent = false
	if typeof(Remote) == "Instance" then
		IsNilParent = Hook:Index(Remote, "Parent") == nil
	end
	local RemoteData = Process:GetRemoteData(Id)

	--// Paused
	local Paused = Flags:GetFlagValue("Paused")
	if Paused then return end

	--// Check caller (Ignore exploit calls)
	--// [FIX] Actor-вызовы НЕ считаем exploit — они из игрового контекста
	local LogExploit = Flags:GetFlagValue("LogExploit")
	if not LogExploit and IsExploit and not Data.IsActor then return end

	--// IgnoreNil
	local IgnoreNil = Flags:GetFlagValue("IgnoreNil")
	if IgnoreNil and IsNilParent then return end

    --// LogRecives check
	local LogRecives = Flags:GetFlagValue("LogRecives")
	if not LogRecives and IsReceive then return end

	local SelectNewest = Flags:GetFlagValue("SelectNewest")
	local NoTreeNodes = Flags:GetFlagValue("NoTreeNodes")

    --// Excluded check
    if RemoteData.Excluded then return end

	--// Deserialize arguments (DeserializeTable уже создаёт новые таблицы,
	--// третий DeepClone на каждый вызов был лишним)
	Args = Communication:DeserializeTable(Args)
	local ClonedArgs = Args
	Data.Args = ClonedArgs
	Data.ValueSwaps = Generation:MakeValueSwapsTable(Timestamp)

	--// Generate log title
	local Color = Config.MethodColors[Method:lower()]
	local Text = NoTreeNodes and `{Remote} | {Method}` or Method

	--// FindStringForName check
	local FindString = Flags:GetFlagValue("FindStringForName")
	if FindString then
		for _, Arg in next, ClonedArgs do
			if typeof(Arg) == "string" then
				local Filtred = self:FilterName(Arg)
				Text = `{Filtred} | {Text}`
				break
			end
		end
	end

	--// Fetch HeaderData by the RemoteID used for stacking
	local Header = self:GetRemoteHeader(Data)

	--// IgnoreDuplicates (Detect Spam): вызовы с теми же Method и
	--// аргументами не логируются повторно. Храним последние аргументы
	--// ПО КАЖДОМУ Method отдельно: игры часто пинг-понгят send/receive
	--// (GetPing → OnClientPing) — сравнение с предыдущим вызовом их
	--// пропускало, т.к. Method чередуется.
	local IgnoreDuplicates = Flags:GetFlagValue("IgnoreDuplicates")
	if IgnoreDuplicates then
		local LastByMethod = Header.LastByMethod
		if not LastByMethod then
			LastByMethod = {}
			Header.LastByMethod = LastByMethod
		end

		if Process:DeepEquals(ClonedArgs, LastByMethod[Method]) then
			return
		end
		LastByMethod[Method] = ClonedArgs
	end

	local RemotesList = self.RemotesList

	local LogCount = Header.LogCount
	local TreeNode = Header.TreeNode 
	local Parent = TreeNode or RemotesList

	--// Increase log count - TreeNodes are in GetRemoteHeader function
	if NoTreeNodes then
		RemotesCount += 1
		LogCount = RemotesCount
	end

    --// Create focus button
	Data.HeaderData = Header
	Data.Selectable = Parent:Selectable({
		Text = Text,
        LayoutOrder = -1 * LogCount,
		TextColor3 = Color,
		TextXAlignment = Enum.TextXAlignment.Left,
		Callback = function()
			self:SetFocusedRemote(Data)
		end,
    })

	Header:LogAdded(Data)

	--// Auto select check
	local GroupSelected = ActiveData and ActiveData.HeaderData == Header
	if SelectNewest and GroupSelected then
		self:SetFocusedRemote(Data)
	end
end

return Ui
