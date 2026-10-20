local DateTime = require("@lune/datetime")
local Fs = require("@lune/fs")
local Net = require("@lune/net")
local Process = require("@lune/process")
local Roblox = require("@lune/roblox")
local Serde = require("@lune/serde")
local Task = require("@lune/task")

type ScriptSources = { [string]: string }

type DiffStatistics = {
	LinesAdded: number,
	LinesRemoved: number,
	LargestAddedBlock: number,
}

type DiffRange = {
	Start: number,
	OldEnd: number,
	NewEnd: number,
}

type ChangeStatus = "Added" | "Modified" | "Removed"

type ScriptChange = {
	Path: string,
	Version: number,
	Status: ChangeStatus,
	SavedAt: string?,
	SavedBy: string?,
	MinutesSincePreviousSave: number?,
	LinesAddedPerMinute: number?,
	Statistics: DiffStatistics,
}

type DownloadOptions = {
	PlaceId: number,
	Version: number,
	ApiKey: string,
}

type HttpRequest = {
	url: string,
	method: string,
	headers: { [string]: string }?,
}

type PlaceVersion = {
	Contents: string,
	LastModified: string?,
}

type VersionMetadata = {
	SavedAt: string?,
	SavedBy: string?,
}

type VersionContext = {
	Version: number,
	SavedAt: string?,
	SavedBy: string?,
	MinutesSincePreviousSave: number?,
}

type Snapshot = {
	Version: number,
	Sources: ScriptSources,
	SavedAt: string?,
	SavedBy: string?,
	SavedTime: number?,
}

type PendingLoad = {
	Version: number,
	Done: boolean,
	Success: boolean,
	Result: Snapshot | string,
}

type RunArguments = {
	PlaceId: number,
	MaxSaves: number,
	OldestFirst: boolean,
	UseCache: boolean,
}

local ASSET_DELIVERY_URL = "https://apis.roblox.com/asset-delivery-api/v1/assetId/%d/version/%d"
local ASSET_VERSION_URL = "https://apis.roblox.com/assets/v1/assets/%d/versions/%d"
local LIST_VERSIONS_URL = "https://apis.roblox.com/assets/v1/assets/%d/versions?maxPageSize=1"
local REQUEST_DELAY_SECONDS = 0.7
local PREFETCH_COUNT = 2
local MAX_REQUEST_ATTEMPTS = 4
local RETRY_BASE_SECONDS = 2
local POLL_INTERVAL_SECONDS = 0.05
local CHECKPOINT_INTERVAL_SECONDS = 30
local MAX_CONSECUTIVE_FAILURES = 5
local MAX_DIFF_CELLS = 50_000_000
local KEEP_BUFFER_BYTES = 16_777_216
local OUTPUT_PATH = "ScriptChanges.json"
local CACHE_DIRECTORY = "VersionCache"
local SCRIPT_CLASS_NAMES = {
	Script = true,
	LocalScript = true,
	ModuleScript = true,
}

local SharedBuffer: buffer? = nil

local function RoundToTenth(Value: number): number
	return math.round(Value * 10) / 10
end

local function ParseTimestamp(Timestamp: string?): number?
	if not Timestamp then
		return nil
	end

	local Parsers = { DateTime.fromRfc3339, DateTime.fromIsoDate, DateTime.fromRfc2822 }
	for _, Parser in Parsers do
		local Success, Result = pcall(Parser, Timestamp)
		if Success then
			return Result.unixTimestampMillis / 1000
		end
	end

	return nil
end

local function RequestAsync(Request: HttpRequest)
	local Response = Net.request(Request)
	local Attempt = 1

	while (Response.statusCode == 429 or Response.statusCode >= 500) and Attempt < MAX_REQUEST_ATTEMPTS do
		local RetryAfter = tonumber(Response.headers["retry-after"])
		Task.wait(RetryAfter or RETRY_BASE_SECONDS * 2 ^ (Attempt - 1))
		Attempt += 1
		Response = Net.request(Request)
	end

	return Response
end

local function DownloadPlaceVersionAsync(Options: DownloadOptions): (boolean, PlaceVersion | string)
	local LocationResponse = RequestAsync({
		url = string.format(ASSET_DELIVERY_URL, Options.PlaceId, Options.Version),
		method = "GET",
		headers = { ["x-api-key"] = Options.ApiKey },
	})

	if LocationResponse.statusCode == 404 then
		return false, "NotFound"
	end

	if not LocationResponse.ok then
		return false, `Location request failed: {LocationResponse.statusCode} {LocationResponse.statusMessage}`
	end

	local LocationData = Serde.decode("json", LocationResponse.body)
	if not LocationData.location then
		return false, "NotFound"
	end

	local PlaceResponse = RequestAsync({
		url = LocationData.location,
		method = "GET",
	})

	if not PlaceResponse.ok then
		return false, `Place download failed: {PlaceResponse.statusCode} {PlaceResponse.statusMessage}`
	end

	return true, {
		Contents = PlaceResponse.body,
		LastModified = PlaceResponse.headers["last-modified"],
	}
end

local function FetchVersionMetadataAsync(Options: DownloadOptions): (boolean, VersionMetadata | string)
	local Response = RequestAsync({
		url = string.format(ASSET_VERSION_URL, Options.PlaceId, Options.Version),
		method = "GET",
		headers = { ["x-api-key"] = Options.ApiKey },
	})

	if not Response.ok then
		return false, `Metadata request failed: {Response.statusCode} {Response.statusMessage}`
	end

	local Data = Serde.decode("json", Response.body)
	local Creator = if Data.creationContext then Data.creationContext.creator else nil

	return true, {
		SavedAt = Data.createTime,
		SavedBy = if Creator then Creator.userId or Creator.groupId else nil,
	}
end

local function ExtractScriptSources(PlaceContents: string): (boolean, ScriptSources | string)
	local Success, Result = pcall(Roblox.deserializePlace, PlaceContents)
	if not Success then
		return false, tostring(Result)
	end

	local Sources: ScriptSources = {}
	for _, Descendant in Result:GetDescendants() do
		if SCRIPT_CLASS_NAMES[Descendant.ClassName] then
			Sources[`{Descendant:GetFullName()} [{Descendant.ClassName}]`] = Descendant.Source
		end
	end

	Result:Destroy()
	return true, Sources
end

local function CountLines(Source: string): number
	local Count = 1
	local Position = 1

	while true do
		local Found = string.find(Source, "\n", Position, true)
		if not Found then
			return Count
		end
		Count += 1
		Position = Found + 1
	end
end

local function AcquireBuffer(Size: number): buffer
	local Current = SharedBuffer
	if Current and buffer.len(Current) >= Size then
		return Current
	end

	local Created = buffer.create(Size)
	SharedBuffer = Created
	return Created
end

local function ReleaseBuffer()
	local Current = SharedBuffer
	if Current and buffer.len(Current) > KEEP_BUFFER_BYTES then
		SharedBuffer = nil
	end
end

local function EstimateDiffStatistics(OldLines: { string }, NewLines: { string }, Range: DiffRange): DiffStatistics
	local Remaining: { [string]: number } = {}
	for Index = Range.Start, Range.OldEnd do
		local Line = OldLines[Index]
		Remaining[Line] = (Remaining[Line] or 0) + 1
	end

	local LinesAdded = 0
	local LargestAddedBlock = 0
	local CurrentAddedBlock = 0

	for Index = Range.Start, Range.NewEnd do
		local Line = NewLines[Index]
		local Count = Remaining[Line]
		if Count and Count > 0 then
			Remaining[Line] = Count - 1
			CurrentAddedBlock = 0
		else
			LinesAdded += 1
			CurrentAddedBlock += 1
			LargestAddedBlock = math.max(LargestAddedBlock, CurrentAddedBlock)
		end
	end

	local Matched = (Range.NewEnd - Range.Start + 1) - LinesAdded

	return {
		LinesAdded = LinesAdded,
		LinesRemoved = (Range.OldEnd - Range.Start + 1) - Matched,
		LargestAddedBlock = LargestAddedBlock,
	}
end

local function ComputeLcsStatistics(OldLines: { string }, NewLines: { string }, Range: DiffRange): DiffStatistics
	local Base = Range.Start - 1
	local OldCount = Range.OldEnd - Base
	local NewCount = Range.NewEnd - Base
	local IsWide = math.min(OldCount, NewCount) > 65535
	local CellSize = if IsWide then 4 else 2
	local Read = if IsWide then buffer.readu32 else buffer.readu16
	local Write = if IsWide then buffer.writeu32 else buffer.writeu16
	local RowBytes = (NewCount + 1) * CellSize
	local Lengths = AcquireBuffer((OldCount + 1) * RowBytes)

	buffer.fill(Lengths, OldCount * RowBytes, 0, RowBytes)

	for OldIndex = OldCount, 1, -1 do
		local OldLine = OldLines[Base + OldIndex]
		local Row = (OldIndex - 1) * RowBytes
		local NextRow = Row + RowBytes
		Write(Lengths, Row + NewCount * CellSize, 0)

		for NewIndex = NewCount, 1, -1 do
			local Cell = (NewIndex - 1) * CellSize
			if OldLine == NewLines[Base + NewIndex] then
				Write(Lengths, Row + Cell, Read(Lengths, NextRow + Cell + CellSize) + 1)
			else
				local Below = Read(Lengths, NextRow + Cell)
				local Beside = Read(Lengths, Row + Cell + CellSize)
				Write(Lengths, Row + Cell, if Below > Beside then Below else Beside)
			end
		end
	end

	local OldIndex = 1
	local NewIndex = 1
	local LinesAdded = 0
	local LinesRemoved = 0
	local LargestAddedBlock = 0
	local CurrentAddedBlock = 0

	while OldIndex <= OldCount and NewIndex <= NewCount do
		local Row = (OldIndex - 1) * RowBytes
		local Cell = (NewIndex - 1) * CellSize
		if OldLines[Base + OldIndex] == NewLines[Base + NewIndex] then
			CurrentAddedBlock = 0
			OldIndex += 1
			NewIndex += 1
		elseif Read(Lengths, Row + RowBytes + Cell) >= Read(Lengths, Row + Cell + CellSize) then
			LinesRemoved += 1
			OldIndex += 1
		else
			LinesAdded += 1
			CurrentAddedBlock += 1
			LargestAddedBlock = math.max(LargestAddedBlock, CurrentAddedBlock)
			NewIndex += 1
		end
	end

	ReleaseBuffer()

	local RemainingAdded = NewCount - NewIndex + 1
	LinesRemoved += OldCount - OldIndex + 1
	LinesAdded += RemainingAdded
	LargestAddedBlock = math.max(LargestAddedBlock, CurrentAddedBlock + RemainingAdded)

	return {
		LinesAdded = LinesAdded,
		LinesRemoved = LinesRemoved,
		LargestAddedBlock = LargestAddedBlock,
	}
end

local function ComputeDiffStatistics(OldLines: { string }, NewLines: { string }): DiffStatistics
	local Start = 1
	local OldEnd = #OldLines
	local NewEnd = #NewLines

	while Start <= OldEnd and Start <= NewEnd and OldLines[Start] == NewLines[Start] do
		Start += 1
	end

	while OldEnd >= Start and NewEnd >= Start and OldLines[OldEnd] == NewLines[NewEnd] do
		OldEnd -= 1
		NewEnd -= 1
	end

	local OldCount = OldEnd - Start + 1
	local NewCount = NewEnd - Start + 1

	if OldCount == 0 or NewCount == 0 then
		return {
			LinesAdded = NewCount,
			LinesRemoved = OldCount,
			LargestAddedBlock = NewCount,
		}
	end

	local Range: DiffRange = { Start = Start, OldEnd = OldEnd, NewEnd = NewEnd }

	if (OldCount + 1) * (NewCount + 1) > MAX_DIFF_CELLS then
		return EstimateDiffStatistics(OldLines, NewLines, Range)
	end

	return ComputeLcsStatistics(OldLines, NewLines, Range)
end

local function CreateChange(Path: string, Statistics: DiffStatistics, Context: VersionContext): ScriptChange
	local Minutes = Context.MinutesSincePreviousSave

	return {
		Path = Path,
		Version = Context.Version,
		Status = "Modified",
		SavedAt = Context.SavedAt,
		SavedBy = Context.SavedBy,
		MinutesSincePreviousSave = if Minutes then RoundToTenth(Minutes) else nil,
		LinesAddedPerMinute = if Minutes and Minutes > 0 then RoundToTenth(Statistics.LinesAdded / Minutes) else nil,
		Statistics = Statistics,
	}
end

local function CompareVersions(PreviousSources: ScriptSources, CurrentSources: ScriptSources, Context: VersionContext): { ScriptChange }
	local Changes: { ScriptChange } = {}

	for Path, CurrentSource in CurrentSources do
		local PreviousSource = PreviousSources[Path]
		if PreviousSource == CurrentSource then
			continue
		end

		if PreviousSource then
			local Statistics = ComputeDiffStatistics(string.split(PreviousSource, "\n"), string.split(CurrentSource, "\n"))
			table.insert(Changes, CreateChange(Path, Statistics, Context))
		else
			local LineCount = CountLines(CurrentSource)
			local Change = CreateChange(Path, {
				LinesAdded = LineCount,
				LinesRemoved = 0,
				LargestAddedBlock = LineCount,
			}, Context)
			Change.Status = "Added"
			table.insert(Changes, Change)
		end
	end

	for Path, PreviousSource in PreviousSources do
		if not CurrentSources[Path] then
			local Change = CreateChange(Path, {
				LinesAdded = 0,
				LinesRemoved = CountLines(PreviousSource),
				LargestAddedBlock = 0,
			}, Context)
			Change.Status = "Removed"
			table.insert(Changes, Change)
		end
	end

	return Changes
end

local function CompareSnapshots(Older: Snapshot, Newer: Snapshot): { ScriptChange }
	return CompareVersions(Older.Sources, Newer.Sources, {
		Version = Newer.Version,
		SavedAt = Newer.SavedAt,
		SavedBy = Newer.SavedBy,
		MinutesSincePreviousSave = if Newer.SavedTime and Older.SavedTime
			then (Newer.SavedTime - Older.SavedTime) / 60
			else nil,
	})
end

local function ParseArguments(Arguments: { string }): RunArguments?
	local PlaceId = tonumber(Arguments[1])
	if not PlaceId then
		return nil
	end

	local Parsed: RunArguments = {
		PlaceId = PlaceId,
		MaxSaves = math.huge,
		OldestFirst = false,
		UseCache = false,
	}

	for Index = 2, #Arguments do
		local Argument = string.lower(Arguments[Index])
		local MaxValue = string.match(Argument, "^max=(%d+)$")
		if MaxValue then
			local MaxSaves = tonumber(MaxValue) :: number
			if MaxSaves < 1 then
				return nil
			end
			Parsed.MaxSaves = MaxSaves
		elseif Argument == "oldest" then
			Parsed.OldestFirst = true
		elseif Argument == "cache" then
			Parsed.UseCache = true
		else
			return nil
		end
	end

	return Parsed
end

local function LocationExistsAsync(PlaceId: number, Version: number, ApiKey: string): boolean
	local Response = RequestAsync({
		url = string.format(ASSET_DELIVERY_URL, PlaceId, Version),
		method = "GET",
		headers = { ["x-api-key"] = ApiKey },
	})

	if not Response.ok then
		return false
	end

	local Success, Data = pcall(Serde.decode, "json", Response.body)
	return Success and Data.location ~= nil
end

local function ProbeLatestVersionAsync(PlaceId: number, ApiKey: string): number?
	if not LocationExistsAsync(PlaceId, 1, ApiKey) then
		return nil
	end

	local Low = 1
	local High = 2
	while LocationExistsAsync(PlaceId, High, ApiKey) do
		Low = High
		High *= 2
		Task.wait(REQUEST_DELAY_SECONDS)
	end

	while High - Low > 1 do
		local Middle = (Low + High) // 2
		if LocationExistsAsync(PlaceId, Middle, ApiKey) then
			Low = Middle
		else
			High = Middle
		end
		Task.wait(REQUEST_DELAY_SECONDS)
	end

	return Low
end

local function FindLatestVersionAsync(PlaceId: number, ApiKey: string): (boolean, number | string)
	local Response = RequestAsync({
		url = string.format(LIST_VERSIONS_URL, PlaceId),
		method = "GET",
		headers = { ["x-api-key"] = ApiKey },
	})

	if Response.ok then
		local Success, Data = pcall(Serde.decode, "json", Response.body)
		if Success then
			local Versions = if Data.assetVersions then Data.assetVersions else Data
			local Latest = if type(Versions) == "table" then Versions[1] else nil
			local Number = if Latest and Latest.path then tonumber(string.match(Latest.path, "versions/(%d+)$")) else nil
			if Number then
				return true, Number
			end
		end
	end

	print("Couldn't read the version list, searching for the latest version instead")
	local Probed = ProbeLatestVersionAsync(PlaceId, ApiKey)
	if Probed then
		return true, Probed
	end

	return false, "No versions of this place could be downloaded. Check the place ID and the API key's permissions."
end

local function GetCachePath(PlaceId: number, Version: number): string
	return `{CACHE_DIRECTORY}/{PlaceId}/{Version}.json`
end

local function ReadCachedSnapshot(PlaceId: number, Version: number): Snapshot?
	local Path = GetCachePath(PlaceId, Version)
	if not Fs.isFile(Path) then
		return nil
	end

	local Success, Result = pcall(function()
		return Serde.decode("json", Fs.readFile(Path))
	end)

	if not Success or type(Result) ~= "table" or type(Result.Sources) ~= "table" then
		return nil
	end

	return {
		Version = Version,
		Sources = Result.Sources,
		SavedAt = Result.SavedAt,
		SavedBy = Result.SavedBy,
		SavedTime = ParseTimestamp(Result.SavedAt),
	}
end

local function WriteCachedSnapshot(PlaceId: number, Current: Snapshot)
	local Success, Result = pcall(function()
		Fs.writeDir(`{CACHE_DIRECTORY}/{PlaceId}`)
		Fs.writeFile(GetCachePath(PlaceId, Current.Version), Serde.encode("json", {
			Sources = Current.Sources,
			SavedAt = Current.SavedAt,
			SavedBy = Current.SavedBy,
		}))
	end)

	if not Success then
		warn(`Version {Current.Version}: couldn't write cache: {Result}`)
	end
end

local function LoadSnapshotAsync(Options: DownloadOptions, UseCache: boolean): (boolean, Snapshot | string)
	if UseCache then
		local Cached = ReadCachedSnapshot(Options.PlaceId, Options.Version)
		if Cached then
			return true, Cached
		end
	end

	local Metadata: VersionMetadata = {}
	local MetadataError: string? = nil
	local MetadataDone = false

	Task.spawn(function()
		local Success, MetadataSuccess, MetadataResult = pcall(FetchVersionMetadataAsync, Options)
		if not Success then
			MetadataError = tostring(MetadataSuccess)
		elseif MetadataSuccess then
			Metadata = MetadataResult :: VersionMetadata
		else
			MetadataError = MetadataResult :: string
		end
		MetadataDone = true
	end)

	local DownloadSuccess, DownloadResult = DownloadPlaceVersionAsync(Options)
	if not DownloadSuccess then
		return false, DownloadResult :: string
	end

	local Place = DownloadResult :: PlaceVersion
	local ExtractSuccess, ExtractResult = ExtractScriptSources(Place.Contents)
	if not ExtractSuccess then
		return false, ExtractResult :: string
	end

	while not MetadataDone do
		Task.wait(POLL_INTERVAL_SECONDS)
	end

	if MetadataError then
		warn(`Version {Options.Version}: {MetadataError}`)
	end

	local SavedAt = Metadata.SavedAt or Place.LastModified
	local Current: Snapshot = {
		Version = Options.Version,
		Sources = ExtractResult :: ScriptSources,
		SavedAt = SavedAt,
		SavedBy = Metadata.SavedBy,
		SavedTime = ParseTimestamp(SavedAt),
	}

	if UseCache then
		WriteCachedSnapshot(Options.PlaceId, Current)
	end

	return true, Current
end

local function StartLoad(Options: DownloadOptions, UseCache: boolean): PendingLoad
	local Pending: PendingLoad = {
		Version = Options.Version,
		Done = false,
		Success = false,
		Result = "Pending",
	}

	Task.spawn(function()
		local CallSuccess, LoadSuccess, LoadResult = pcall(LoadSnapshotAsync, Options, UseCache)
		Pending.Success = if CallSuccess then LoadSuccess else false
		Pending.Result = if CallSuccess then LoadResult else tostring(LoadSuccess)
		Pending.Done = true
	end)

	return Pending
end

local function AwaitLoadAsync(Pending: PendingLoad): (boolean, Snapshot | string)
	while not Pending.Done do
		Task.wait(POLL_INTERVAL_SECONDS)
	end

	return Pending.Success, Pending.Result
end

local function WriteReport(Changes: { ScriptChange }, Pretty: boolean)
	Fs.writeFile(OUTPUT_PATH, Serde.encode("json", Changes, Pretty))
end

local function RunAsync()
	local ParsedArguments = ParseArguments(Process.args)
	local EnvironmentKey = Process.env.ROBLOX_API_KEY

	if not ParsedArguments or not EnvironmentKey then
		print("Usage: ROBLOX_API_KEY=<key> lune run VersionDiff <PlaceId> [max=<Saves>] [oldest] [cache]")
		Process.exit(1)
		return
	end

	local Arguments = ParsedArguments :: RunArguments
	local ApiKey = EnvironmentKey :: string

	local NextVersion = 1
	local Direction = 1
	if not Arguments.OldestFirst then
		local Success, Result = FindLatestVersionAsync(Arguments.PlaceId, ApiKey)
		if not Success then
			warn(Result)
			Process.exit(1)
			return
		end
		NextVersion = Result :: number
		Direction = -1
		print(`Latest version is {NextVersion}, working backwards`)
	end

	local Changes: { ScriptChange } = {}
	local Queue: { PendingLoad } = {}
	local Anchor: Snapshot? = nil
	local SavesCompared = 0
	local SnapshotsLoaded = 0
	local ConsecutiveFailures = 0
	local LastRequestTime = -math.huge
	local LastCheckpointTime = os.clock()

	local function FillQueueAsync()
		while #Queue < PREFETCH_COUNT and NextVersion >= 1 and SnapshotsLoaded + #Queue <= Arguments.MaxSaves do
			local IsCached = Arguments.UseCache and Fs.isFile(GetCachePath(Arguments.PlaceId, NextVersion))
			if not IsCached then
				local Remaining = REQUEST_DELAY_SECONDS - (os.clock() - LastRequestTime)
				if Remaining > 0 then
					Task.wait(Remaining)
				end
				LastRequestTime = os.clock()
			end

			table.insert(Queue, StartLoad({
				PlaceId = Arguments.PlaceId,
				Version = NextVersion,
				ApiKey = ApiKey,
			}, Arguments.UseCache))
			NextVersion += Direction
		end
	end

	FillQueueAsync()

	while #Queue > 0 and SavesCompared < Arguments.MaxSaves and ConsecutiveFailures < MAX_CONSECUTIVE_FAILURES do
		local Pending = table.remove(Queue, 1) :: PendingLoad
		local Success, Result = AwaitLoadAsync(Pending)

		if Success then
			ConsecutiveFailures = 0
			SnapshotsLoaded += 1
			local Current = Result :: Snapshot
			if Anchor then
				local Older = if Arguments.OldestFirst then Anchor else Current
				local Newer = if Arguments.OldestFirst then Current else Anchor
				for _, Change in CompareSnapshots(Older, Newer) do
					table.insert(Changes, Change)
				end
				SavesCompared += 1
			end
			Anchor = Current
			print(`Processed version {Pending.Version}`)

			if os.clock() - LastCheckpointTime >= CHECKPOINT_INTERVAL_SECONDS then
				WriteReport(Changes, false)
				LastCheckpointTime = os.clock()
			end
		else
			if Result ~= "NotFound" then
				warn(`Version {Pending.Version}: {Result}`)
			end
			ConsecutiveFailures += 1
		end

		FillQueueAsync()
	end

	WriteReport(Changes, true)
	print(`Compared {SavesCompared} saves and wrote {#Changes} script changes to {OUTPUT_PATH}`)
end

RunAsync()
