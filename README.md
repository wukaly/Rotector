# ⚠️ THIS IS AI SLOP ⚠️

This repo was made to detect when AI is being used in Roblox Studio projects. All text below this section was AI generated.

# Rotector

Flags Roblox scripts that appeared unusually fast in a place's version history, so reviewers know which saves to look at. It can't prove code was AI-generated. It points to saves worth opening.

Two parts:

- **VersionDiff.luau** downloads a place's saved versions, diffs every script between saves, and writes `ScriptChanges.json`.
- **The website** reads `ScriptChanges.json` in your browser and shows a timeline and a ranked list of flagged changes. Nothing is uploaded.

## 1. Install Lune

With [Rokit](https://github.com/rojo-rbx/rokit), run this in the repo folder:

```
rokit install
```

Or download Lune 0.8.9 from [its releases page](https://github.com/lune-org/lune/releases) and put `lune` (or `lune.exe`) in this folder.

## 2. Make an API key

In the Creator Dashboard, go to Open Cloud → API Keys and create a key. Create it under the group if the game is group-owned.

- Permissions: **Assets** (Read) and **Legacy Asset** (`legacy-asset:manage`).
- Accepted IP addresses: your IP followed by `/32`, for example `73.45.122.18/32`.

Never commit the key or paste it anywhere public.

## 3. Run it

The place ID is the number in the game's URL.

Windows (PowerShell):

```
$env:ROBLOX_API_KEY="your-key-here"
lune run VersionDiff 1234567890 max=50
```

Mac or Linux:

```
ROBLOX_API_KEY=your-key-here lune run VersionDiff 1234567890 max=50
```

If Lune is in this folder rather than installed, use `.\lune` on Windows or `./lune` on Mac and Linux.

| Option | What it does |
| --- | --- |
| `max=50` | Compare only the 50 most recent saves. Leave it out to go through the whole history. |
| `oldest` | Start at version 1 and work forward instead of starting at the newest. |

The JSON is saved after every save it compares, so you can stop with Ctrl+C and keep what it has done so far.

## 4. Review

Open the website and drop in `ScriptChanges.json`.

- **Fast and large**: a big block of new lines that also arrived quickly.
- **Worth a look**: one of those signals, or a line-by-line rewrite.

Common false flags are pasted open-source modules, scripts moved between folders, and code written in an external editor. With Collaborative Editing, drafts can sit for hours before being committed. Talk to the developer before drawing a conclusion.
