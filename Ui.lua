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
		"CallingScript",
		"CallerScript",
		"IsActor",
		"ScriptHash",
		"Id"
	},

    Window = nil,
    RandomSeed = Random.new(tick()),
	Logs = setmetatable({}, {__mode = "k"}),
	LogQueue = setmetatable({}, {__mode = "v"}),
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

local SetClipboard = setclipboard or toclipboard or set_clipboard

local ReGui = nil

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

	Flags = Modules.Flags
	Generation = Modules.Generation
	Process = Modules.Process
	Hook = Modules.Hook
	Config = Modules.Config
	Communication = Modules.Communication
	Files = Modules.Files

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
	local AssetId = Files:LoadCustomasset(FontFile)
	if not AssetId then return end
	local NewFont = Font.new(AssetId)
	TextFont = NewFont
	FontSuccess = true
end

function Ui:SetFontFile(FontFile: string)
    if FontFile and type(FontFile) == "string" and FontFile ~= "" then
        local Success = pcall(function() self.FontJsonFile = FontFile end)
        if Success then return end
    end
    self.FontJsonFile = nil
end

function Ui:FontWasSuccessful()
	if FontSuccess then return end
	self:ShowModal({
		"Unfortunately your executor was unable to download the font and therefore switched to the Dark theme",
		"\nIf you would like to use the ImGui theme, \nplease download the font (assets/ProggyClean.ttf)",
		"and put put it in your workspace folder\n(Sigma Spy/assets)"
	})
end

function Ui:LoadReGui()
	local ThemeConfig = Config.ThemeConfig
	ThemeConfig.TextFont = TextFont
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

	if not NoTable then
		Parent = Parent:Table({ MaxColumns = 3 }):NextRow()
	end

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
	local Window = ReGui:Window(Config)
	if not FontSuccess then Window:SetTheme("DarkTheme") end
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
	local ModalWindow = Window:PopupModal({ Title = Config.Title })
	ModalWindow:Label({ Text = table.concat(Config.Content, "\n"), TextWrapped = true })
	ModalWindow:Separator()
	local Row = ModalWindow:Row({ Expanded = true })
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
	self:FontWasSuccessful()
	self:AuraCounterService()
	Flags:SetFlagCallback("UiVisible", function(self, Visible)
		Window:SetVisible(Visible)
	end)
	return Window
end

function Ui:ShowModal(Lines: table)
	local Window = self.Window
	local Message = table.concat(Lines, "\n")
	local ModalWindow = Window:PopupModal({ Title = "Sigma Spy" })
	ModalWindow:Label({ Text = Message, RichText = true, TextWrapped = true })
	ModalWindow:Button({
		Text = "Okay",
		Callback = function() ModalWindow:ClosePopup() end,
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
	for Key, Value in next, Dict do
		Options[Key] = {
			Value = Value,
			Label = Key,
			Callback = function(_, Value)
				Dict[Key] = Value
				if not Callback then return end
				Callback()
			end
		}
	end
	self:CreateElements(Parent, Options)
end

function Ui:CheckKeybindLayout(Container, KeyCode: Enum.KeyCode, Callback)
	if not KeyCode then return Container end
	Container = Container:Row({ HorizontalFlex = Enum.UIFlexAlignment.SpaceBetween })
	Container:Keybind({
		Label = "",
		Value = KeyCode,
		LayoutOrder = 2,
		IgnoreGameProcessed = false,
		Callback = function()
			local Enabled = Flags:GetFlagValue("KeybindsEnabled")
			if not Enabled then return end
			Callback()
		end,
	})
	return Container
end

function Ui:CreateElements(Parent, Options)
	local OptionTypes = self.OptionTypes
	local Table = Parent:Table({ MaxColumns = 3 }):NextRow()
	for Name, Data in Options do
		local Value = Data.Value
		local Type = typeof(Value)
		ReGui:CheckConfig(Data, { Class = OptionTypes[Type], Label = Name })
		local Class = Data.Class
		assert(Class, `No {Type} type exists for option`)
		local Container = Table:NextColumn()
		local Checkbox = nil
		local Keybind = Data.Keybind
		Container = self:CheckKeybindLayout(Container, Keybind, function()
			Checkbox:Toggle()
		end)
		Checkbox = Container[Class](Container, Data)
	end
end

function Ui:DisplayAura()
    local Window = self.Window
    local Rand = self.RandomSeed
    local AURA = Rand:NextInteger(1, 9999999)
    local AURADELAY = Rand:NextInteger(1, 5)
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
    local Layout = Window:List({
        UiPadding = 2,
        HorizontalFlex = Enum.UIFlexAlignment.Fill,
        VerticalFlex = Enum.UIFlexAlignment.Fill,
        FillDirection = Enum.FillDirection.Vertical,
        Fill = true
    })

    self.RemotesList = Layout:Canvas({
        Scroll = true,
        UiPadding = 5,
        AutomaticSize = Enum.AutomaticSize.None,
        FlexMode = Enum.UIFlexMode.None,
        Size = UDim2.new(0, 130, 1, 0)
    })

	local InfoSelector = Layout:TabSelector({
        NoAnimation = true,
        Size = UDim2.new(1, -130, 0.4, 0),
    })

	self.InfoSelector = InfoSelector
	self.CanvasLayout = Layout

	self:MakeEditorTab(InfoSelector)
	self:MakeOptionsTab(InfoSelector)
	
	if Config.Debug then
		self:ConsoleTab(InfoSelector)
	end
end

function Ui:ConsoleTab(InfoSelector)
	local Tab = InfoSelector:CreateTab({ Name = "Console" })
	local Console
	local ButtonsRow = Tab:Row()
	ButtonsRow:Button({ Text = "Clear", Callback = function() Console:Clear() end })
	ButtonsRow:Button({ Text = "Copy", Callback = function() toclipboard(Console:GetValue()) end })
	ButtonsRow:Button({
		Text = "Pause",
		Callback = function(self)
			local Enabled = not Console.Enabled
			local Text = Enabled and "Pause" or "Paused"
			self.Text = Text
			Console.Enabled = Enabled
		end,
	})
	ButtonsRow:Expand()
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
	local Tab = InfoSelector:CreateTab({ Name = "Options" })
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
					if Tab then InfoSelector:RemoveTab(Tab) end
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
	local EditorTab = InfoSelector:CreateTab({ Name = "Editor" })
	local CodeEditor = EditorTab:CodeEditor({
		Fill = true,
		Editable = true,
		FontSize = 13,
		Colors = SyntaxColors,
		FontFace = TextFont,
		Text = Default
	})

	local ButtonsRow = EditorTab:Row()
	self:CreateButtons(ButtonsRow, {
		NoTable = true,
		Buttons = {
			{ Text = "Copy", Callback = function()
				local Script = CodeEditor:GetText()
				self:SetClipboard(Script)
			end },
			{ Text = "Run", Callback = function()
				local Script = CodeEditor:GetText()
				local Func, Error = loadstring(Script, "SigmaSpy-USERSCRIPT")
				if not Func then
					self:ShowModal({"Error running script!\n", Error})
					return
				end
				Func()
			end },
			{ Text = "Get return", Callback = MakeActiveDataCallback("GetReturn") },
			{ Text = "Script", Callback = MakeActiveDataCallback("ScriptOptions") },
			{ Text = "Build", Callback = MakeActiveDataCallback("BuildScript") },
			{ Text = "Pop-out", Callback = function()
				local Script = CodeEditor:GetText()
				local Tile = ActiveData and ActiveData.Task or "Sigma Spy"
				self:MakeEditorPopoutWindow(Script, { Title = Tile })
			end },
		}
	})
	
	self.CodeEditor = CodeEditor
end

function Ui:ShouldFocus(Tab): boolean
	local InfoSelector = self.InfoSelector
	local ActiveTab = InfoSelector.ActiveTab
	if not ActiveTab then return true end
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

	table.insert(Buttons, {
		Text = "Copy",
		Callback = function()
			local Script = CodeEditor:GetText()
			self:SetClipboard(Script)
		end
	})

	local ButtonsRow = Window:Row()
	self:CreateButtons(ButtonsRow, { NoTable = true, Buttons = Buttons })
	Window:Center()
	return CodeEditor, Window
end

function Ui:EditFile(FilePath: string, InFolder: boolean, OnSaveFunc: ((table, string) -> nil)?)
	local Folder = Files.FolderName
	local CodeEditor, Window
	if InFolder then FilePath = `{Folder}/{FilePath}` end

	local Content = readfile(FilePath)
	Content = Content:gsub("\r\n", "\n")
	
	local Buttons = {
		{
			Text = "Save",
			Callback = function()
				local Script = CodeEditor:GetText()
				local Success, Error = loadstring(Script, "SigmaSpy-Editor")
				if not Success then
					self:ShowModal({"Error saving file!\n", Error})
					return
				end
				writefile(FilePath, Script)
				if OnSaveFunc then OnSaveFunc(Window, Script) end
			end
		}
	}

	CodeEditor, Window = self:MakeEditorPopoutWindow(Content, {
		Title = `Editing: {FilePath}`,
		Buttons = Buttons
	})
end

type MenuOptions = { [string]: (GuiButton, ...any) -> nil }
function Ui:MakeButtonMenu(Button: Instance, Unpack: table, Options: MenuOptions)
	local Window = self.Window
	local Popup = Window:PopupCanvas({ RelativeTo = Button, MaxSizeX = 500 })
	for Name, Func in Options do
		 Popup:Selectable({
			Text = Name,
			Callback = function() Func(Process:Unpack(Unpack)) end,
		})
	end
end

function Ui:RemovePreviousTab(Title: string): boolean
	if not ActiveData then return false end
	local InfoSelector = self.InfoSelector
	local PreviousTab = ActiveData.Tab
	local PreviousSelectable = ActiveData.Selectable
	local TabFocused = self:ShouldFocus(PreviousTab)
	InfoSelector:RemoveTab(PreviousTab)
	PreviousSelectable:SetSelected(false)
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
	local Decompiled, IsError = Process:Decompile(Script)
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
	local Rows = Config.Rows
	local Flags = Config.Flags
	local DataTable = Config.Table
	local ToDisplay = Config.ToDisplay
	Flags.MaxColumns = #Rows
	local Table = Parent:Table(Flags)
	self:MakeTableHeaders(Table, Rows)
	for RowIndex, Name in ToDisplay do
		local Row = Table:Row()
		for Count, Catagory in Rows do
			local Column = Row:NextColumn()
			local Value = Catagory == "Name" and Name or DataTable[Name]
			if Value == nil then continue end
			local String = self:FilterName(`{Value}`, 150)
			Column:Label({Text=String})
		end
	end
	return Table
end

function Ui:SetFocusedRemote(Data)
	local Remote = Data.Remote
	local Method = Data.Method
	local IsReceive = Data.IsReceive
	local Script = Data.CallingScript
	local ClassData = Data.ClassData
	local HeaderData = Data.HeaderData
	local ValueSwaps = Data.ValueSwaps
	local Args = Data.Args
	local Id = Data.Id

	local TableArgs = Flags:GetFlagValue("TableArgs")
	local NoVariables = Flags:GetFlagValue("NoVariables")

	Data.IsActor = Data.IsActor == true

	local RemoteData = Process:GetRemoteData(Id)
	local IsRemoteFunction = ClassData.IsRemoteFunction
	local RemoteName = self:FilterName(`{Remote}`, 50)

	local CodeEditor = self.CodeEditor
	local ToDisplay = self.DisplayRemoteInfo
	local InfoSelector = self.InfoSelector

	local TabFocused = self:RemovePreviousTab()
	local Tab = InfoSelector:CreateTab({
		Name = self:FilterName(`Remote: {RemoteName}`, 50),
		Focused = TabFocused
	})

	local Module = Generation:NewParser({ NoVariables = NoVariables })
	local Parser = Module.Parser
	local Formatter = Module.Formatter
	Formatter:SetValueSwaps(ValueSwaps)

	ActiveData = Data
	Data.Tab = Tab
	Data.Selectable:SetSelected(true)

	local function SetIDEText(Content: string, Task: string?)
		Data.Task = Task or "Sigma Spy"
		CodeEditor:SetText(Content)
	end
	local function DataConnection(Name, ...)
		local Args = {...}
		return function() return Data[Name](Data, Process:Unpack(Args)) end
	end
	local function ScriptCheck(Script, NoMissingCheck: boolean): boolean?
		if IsReceive then 
			Ui:ShowModal({ "Recieves do not have a script because it's a Connection" })
			return 
		end
		if not Script and not NoMissingCheck then 
			Ui:ShowModal({"The Script has been destroyed by the game (-9999999 AURA)"})
			return
		end
		return true
	end

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
		if not ScriptCheck(Script, true) then return end
    	local Success, Bytecode = pcall(getscriptbytecode, Script)
		if not Success then
			Ui:ShowModal({"Failed to get Scripte bytecode (-9999999 AURA)"})
			return
		end
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
		if not IsRemoteFunction then
			Ui:ShowModal({"The Remote is not a Remote Function (-9999999 AURA)"})
			return
		end
		if not ReturnValues then
			Ui:ShowModal({"No return values (-9999999 AURA)"})
			return
		end
		local Script = Generation:TableScript(Module, ReturnValues)
		SetIDEText(Script, `Return Values for: {RemoteName}`)
	end
	function Data:GenerateInfo()
		if not ScriptCheck(nil, true) then return end
		local Script = Generation:AdvancedInfo(Module, self)
		SetIDEText(Script, `Advanced Info for: {RemoteName}`)
	end

	--// [FIX] Decompile: SourceScript (модуль/скрипт) с fallback на CallerScript;
	--// CallingScript-ветка = CallerScript (загрузчик), fallback на
	--// getcallingscript(). Блок IsScriptAvailable УБРАН: удалённый-но-
	--// загруженный скрипт getscriptbytecode может отдать, а если нет —
	--// Process:Decompile вернёт текст ошибки, а не упадёт.
	function Data:Decompile(WhichScript: string)
		if IsReceive then
			local RecvMethod = ClassData.Receive[1]
			local Signal
			if IsRemoteFunction then
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

		if WhichScript == "SourceScript" then
			ToDecompile = Data.SourceScript
			if typeof(ToDecompile) ~= "Instance" then
				ToDecompile = Data.CallerScript
				UsedFallback = true
			end
		else
			ToDecompile = Data.CallerScript
			if typeof(ToDecompile) ~= "Instance" then
				ToDecompile = Data.CallingScript
				UsedFallback = true
			end
		end

		if typeof(ToDecompile) ~= "Instance" then
			Ui:ShowModal({"Script not found: neither source nor caller could be resolved"})
			return
		end

		local Editor = CodeEditor

		if not ScriptCheck(ToDecompile, true) then return end
		local Task = Ui:FilterName(`Viewing: {ToDecompile}.lua`, 200)
		if WhichScript == "CallingScript" then
			Task = `{Task} (caller)`
		end
		if UsedFallback then
			Task = `{Task} (fallback)`
		end
		
		if DecompilePopout then
			Editor = Ui:MakeEditorPopoutWindow("", { Title = Task })
		end

		Ui:Decompile(Editor, ToDecompile)
	end
	
	xpcall(function()
		self:CreateOptionsForDict(Tab, RemoteData, function()
			Process:UpdateRemoteData(Id, RemoteData)
			pcall(function()
				Process:SetIncomingBlocked(Remote, RemoteData.Blocked == true)
			end)
		end)
	end, function(Err)
		warn("SigmaSpy RemoteOptions:", tostring(Err):sub(1, 200))
	end)

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
					local Target = Script
					if typeof(Target) ~= "Instance" then
						Target = Data.SourceScript
					end
					local Ok, Path = pcall(function()
						return Parser:MakePathString({ Object = Target, NoVariables = true })
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
					SetClipboard(Parser:MakePathString({ Object = Remote, NoVariables = true }))
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

	local HashSource = Data.SourceScript or Data.CallerScript
	Data.ScriptHash = HashSource and Process:GetScriptHash(HashSource) or nil

	self:DisplayTable(Tab, {
		Rows = {"Name", "Value"},
		Table = Data,
		ToDisplay = ToDisplay,
		Flags = { Border = true, RowBackground = true, MaxColumns = 2 }
	})
	
	if TableArgs then
		local Parsed = Generation:TableScript(Module, Args)
		SetIDEText(Parsed, `Arguments for {RemoteName}`)
		return
	end

	Data:MakeScript("Remote")
end

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
				local Editor = self:MakeEditorPopoutWindow(nil, { Title = Task })
				self:Decompile(Editor, Script)
			end
		})
	end
	Window:Center()
	return Window
end

function Ui:ViewConnections(RemoteName: string, Signal: RBXScriptConnection)
	if typeof(Signal) ~= "RBXScriptSignal" then
		return self:ViewCallback(RemoteName, Signal)
	end

	local Window = self:CreateWindow({
		Title = `Connections for: {RemoteName}`,
		Size = UDim2.fromOffset(450, 250)
	})
	local ToDisplay = { "Enabled", "LuaConnection", "Script" }
	local Connections = Process:FilterConnections(Signal, ToDisplay)
	local Table = Window:Table({ Border = true, RowBackground = true, MaxColumns = 3 })

	local ButtonsForValues = {
		["Script"] = function(Row, Value)
			Row:Button({
				Text = "Decompile",
				Callback = function()
					local Task = self:FilterName(`Viewing: {Value}.lua`, 200)
					local Editor = self:MakeEditorPopoutWindow(nil, { Title = Task })
					self:Decompile(Editor, Value)
				end
			})
		end,
		["Enabled"] = function(Row, Enabled, Connection)
			Row:Button({
				Text = Enabled and "Disable" or "Enable",
				Callback = function(self)
					Enabled = not Enabled
					self.Text = Enabled and "Disable" or "Enable"
					if Enabled then Connection:Enable() else Connection:Disable() end
				end
			})
		end
	}

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
		return Process:GetScriptFromFunc(Connection.Function)
	end

	self:MakeTableHeaders(Table, ToDisplay)

	for _, Connection in Connections do
		local Row = Table:Row()
		for _, Property in ToDisplay do
			local Column = Row:NextColumn()
			local ColumnRow = Column:Row()
			local Value = Property == "Script"
				and GetConnectionScript(Connection)
				or Connection[Property]
			local Callback = ButtonsForValues[Property]
			ColumnRow:Label({Text=`{Value}`})
			if Callback then
				Callback(ColumnRow, Value, Connection)
			end
		end
	end

	Window:Center()
end

function Ui:GetRemoteHeader(Data: Log)
	local LogLimit = self.LogLimit
	local Logs = self.Logs
	local RemotesList = self.RemotesList
	local Id = Data.Id
	local Remote = Data.Remote
	local RemoteName = self:FilterName(`{Remote}`, 30)
	local NoTreeNodes = Flags:GetFlagValue("NoTreeNodes")
	local Existing = Logs[Id]
	if Existing then return Existing end

	local HeaderData = { LogCount = 0, Data = Data, Entries = {} }
	RemotesCount += 1

	if not NoTreeNodes then
		HeaderData.TreeNode = RemotesList:TreeNode({
			LayoutOrder = -1 * RemotesCount,
			Title = RemoteName
		})
	end

	function HeaderData:CheckLimit()
		local Entries = self.Entries
		if #Entries < LogLimit then return end
		local Log = table.remove(Entries, 1)
		Log.Selectable:Remove()
	end

	function HeaderData:LogAdded(Data)
		self.LogCount += 1
		self:CheckLimit()
		local Entries = self.Entries
		table.insert(Entries, Data)
		return self
	end

	function HeaderData:Remove()
		local TreeNode = self.TreeNode
		if TreeNode then TreeNode:Remove() end
		Logs[Id] = nil
		table.clear(HeaderData)
	end

	Logs[Id] = HeaderData
	return HeaderData
end

function Ui:ClearLogs()
	local Logs = self.Logs
	local RemotesList = self.RemotesList
	RemotesCount = 0
	RemotesList:ClearChildElements()
	table.clear(Logs)
end

function Ui:QueueLog(Data)
	if typeof(Data.Remote) ~= "Instance" then
		return
	end
	local LogQueue = self.LogQueue
	Process:Merge(Data, { Args = Process:DeepCloneTable(Data.Args) })
	if Data.ReturnValues then
        Data.ReturnValues = Process:DeepCloneTable(Data.ReturnValues)
    end
    table.insert(LogQueue, Data)
end

function Ui:ProcessLogQueue()
	local Queue = self.LogQueue
    if #Queue <= 0 then return end
    for Index, Data in next, Queue do
        self:CreateLog(Data)
        table.remove(Queue, Index)
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
	local Filtred = Trimmed:gsub("[\n\r]", "")
	Filtred = Generation:MakePrintable(Filtred)
	return Filtred
end

function Ui:CreateLog(Data: Log)
	if typeof(Data.Remote) ~= "Instance" then
		return
	end

    local Remote = Data.Remote
	local Method = Data.Method
    local Args = Data.Args
    local IsReceive = Data.IsReceive
	local Id = Data.Id
	local Timestamp = Data.Timestamp
	local IsExploit = Data.IsExploit
	
	local IsNilParent = Hook:Index(Remote, "Parent") == nil
	local RemoteData = Process:GetRemoteData(Id)

	local Paused = Flags:GetFlagValue("Paused")
	if Paused then return end

	local LogExploit = Flags:GetFlagValue("LogExploit")
	if not LogExploit and IsExploit then return end

	local IgnoreNil = Flags:GetFlagValue("IgnoreNil")
	if IgnoreNil and IsNilParent then return end

	local LogRecives = Flags:GetFlagValue("LogRecives")
	if not LogRecives and IsReceive then return end

	local SelectNewest = Flags:GetFlagValue("SelectNewest")
	local NoTreeNodes = Flags:GetFlagValue("NoTreeNodes")

    if RemoteData.Excluded then return end

	Args = Communication:DeserializeTable(Args)

	local ClonedArgs = Process:DeepCloneTable(Args)
	Data.Args = ClonedArgs
	Data.ValueSwaps = Generation:MakeValueSwapsTable(Timestamp)

	local Color = Config.MethodColors[Method:lower()]
	local Text = NoTreeNodes and `{Remote} | {Method}` or Method

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

	local Header = self:GetRemoteHeader(Data)
	local RemotesList = self.RemotesList
	local LogCount = Header.LogCount
	local TreeNode = Header.TreeNode 
	local Parent = TreeNode or RemotesList

	if NoTreeNodes then
		RemotesCount += 1
		LogCount = RemotesCount
	end

	Data.HeaderData = Header
	Data.Selectable = Parent:Selectable({
		Text = Text,
        LayoutOrder = -1 * LogCount,
		TextColor3 = Color,
		TextXAlignment = Enum.TextXAlignment.Left,
		Callback = function() self:SetFocusedRemote(Data) end,
    })

	Header:LogAdded(Data)

	local GroupSelected = ActiveData and ActiveData.HeaderData == Header
	if SelectNewest and GroupSelected then
		self:SetFocusedRemote(Data)
	end
end

return Ui
