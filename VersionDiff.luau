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

type RunArguments = {
	PlaceId: number,
	MaxSaves: number,
	OldestFirst: boolean,
}

local ASSET_DELIVERY_URL = "https://apis.roblox.com/asset-delivery-api/v1/assetId/%d/version/%d"
local ASSET_VERSION_URL = "https://apis.roblox.com/assets/v1/assets/%d/versions/%d"
local LIST_VERSIONS_URL = "https://apis.roblox.com/assets/v1/assets/%d/versions?maxPageSize=1"
local REQUEST_DELAY_SECONDS = 0.7
local MAX_CONSECUTIVE_FAILURES = 5
local OUTPUT_PATH = "ScriptChanges.json"
local SCRIPT_CLASS_NAMES = {
	Script = true,
	LocalScript = true,
	ModuleScript = true,
}

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

local function DownloadPlaceVersionAsync(Options: DownloadOptions): (boolean, PlaceVersion | string)
	local LocationResponse = Net.request({
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

	local PlaceResponse = Net.request({
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
	local Response = Net.request({
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

	return true, Sources
end

local function ComputeDiffStatistics(OldLines: { string }, NewLines: { string }): DiffStatistics
	local OldCount = #OldLines
	local NewCount = #NewLines

	local Lengths = table.create(OldCount + 1)
	for RowIndex = 1, OldCount + 1 do
		Lengths[RowIndex] = table.create(NewCount + 1, 0)
	end

	for OldIndex = OldCount, 1, -1 do
		local Row = Lengths[OldIndex]
		local NextRow = Lengths[OldIndex + 1]
		for NewIndex = NewCount, 1, -1 do
			if OldLines[OldIndex] == NewLines[NewIndex] then
				Row[NewIndex] = NextRow[NewIndex + 1] + 1
			else
				Row[NewIndex] = math.max(NextRow[NewIndex], Row[NewIndex + 1])
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
		if OldLines[OldIndex] == NewLines[NewIndex] then
			CurrentAddedBlock = 0
			OldIndex += 1
			NewIndex += 1
		elseif Lengths[OldIndex + 1][NewIndex] >= Lengths[OldIndex][NewIndex + 1] then
			LinesRemoved += 1
			OldIndex += 1
		else
			LinesAdded += 1
			CurrentAddedBlock += 1
			LargestAddedBlock = math.max(LargestAddedBlock, CurrentAddedBlock)
			NewIndex += 1
		end
	end

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
		if PreviousSource ~= CurrentSource then
			local PreviousLines = if PreviousSource then string.split(PreviousSource, "\n") else {}
			local Change = CreateChange(Path, ComputeDiffStatistics(PreviousLines, string.split(CurrentSource, "\n")), Context)
			Change.Status = if PreviousSource then "Modified" else "Added"
			table.insert(Changes, Change)
		end
	end

	for Path, PreviousSource in PreviousSources do
		if not CurrentSources[Path] then
			local Change = CreateChange(Path, ComputeDiffStatistics(string.split(PreviousSource, "\n"), {}), Context)
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
		else
			return nil
		end
	end

	return Parsed
end

local function LocationExistsAsync(PlaceId: number, Version: number, ApiKey: string): boolean
	local Response = Net.request({
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
	local Response = Net.request({
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

local function LoadSnapshotAsync(Options: DownloadOptions): (boolean, Snapshot | string)
	local DownloadSuccess, DownloadResult = DownloadPlaceVersionAsync(Options)
	if not DownloadSuccess then
		return false, DownloadResult :: string
	end

	local Place = DownloadResult :: PlaceVersion

	local MetadataSuccess, MetadataResult = FetchVersionMetadataAsync(Options)
	local Metadata: VersionMetadata = {}
	if MetadataSuccess then
		Metadata = MetadataResult :: VersionMetadata
	else
		warn(`Version {Options.Version}: {MetadataResult}`)
	end

	local ExtractSuccess, ExtractResult = ExtractScriptSources(Place.Contents)
	if not ExtractSuccess then
		return false, ExtractResult :: string
	end

	local SavedAt = Metadata.SavedAt or Place.LastModified
	return true, {
		Version = Options.Version,
		Sources = ExtractResult :: ScriptSources,
		SavedAt = SavedAt,
		SavedBy = Metadata.SavedBy,
		SavedTime = ParseTimestamp(SavedAt),
	}
end

local function RunAsync()
	local Arguments = ParseArguments(Process.args)
	local ApiKey = Process.env.ROBLOX_API_KEY

	if not Arguments or not ApiKey then
		print("Usage: ROBLOX_API_KEY=<key> lune run VersionDiff <PlaceId> [max=<Saves>] [oldest]")
		Process.exit(1)
		return
	end

	local Version = 1
	local Direction = 1
	if not Arguments.OldestFirst then
		local Success, Result = FindLatestVersionAsync(Arguments.PlaceId, ApiKey)
		if not Success then
			warn(Result)
			Process.exit(1)
			return
		end
		Version = Result :: number
		Direction = -1
		print(`Latest version is {Version}, working backwards`)
	end

	local Changes: { ScriptChange } = {}
	local Anchor: Snapshot? = nil
	local SavesCompared = 0
	local ConsecutiveFailures = 0

	while Version >= 1 and SavesCompared < Arguments.MaxSaves and ConsecutiveFailures < MAX_CONSECUTIVE_FAILURES do
		local Success, Result = LoadSnapshotAsync({
			PlaceId = Arguments.PlaceId,
			Version = Version,
			ApiKey = ApiKey,
		})

		if Success then
			ConsecutiveFailures = 0
			local Current = Result :: Snapshot
			if Anchor then
				local Older = if Arguments.OldestFirst then Anchor else Current
				local Newer = if Arguments.OldestFirst then Current else Anchor
				for _, Change in CompareSnapshots(Older, Newer) do
					table.insert(Changes, Change)
				end
				SavesCompared += 1
				Fs.writeFile(OUTPUT_PATH, Serde.encode("json", Changes, true))
			end
			Anchor = Current
			print(`Processed version {Version}`)
		else
			if Result ~= "NotFound" then
				warn(`Version {Version}: {Result}`)
			end
			ConsecutiveFailures += 1
		end

		Version += Direction
		Task.wait(REQUEST_DELAY_SECONDS)
	end

	Fs.writeFile(OUTPUT_PATH, Serde.encode("json", Changes, true))
	print(`Compared {SavesCompared} saves and wrote {#Changes} script changes to {OUTPUT_PATH}`)
end

RunAsync()
