# Changelog

## 1.1.0

### New tools
- CraftScout, a new optional module in the same download: the margin and profit of each recipe you can craft, from your Auction House scans. Compare prices from the last scan or a 72-hour average, see what to make with the reagents in your bags, and add a minimap button if you want one. It is off by default and not even loaded until you tick it in `/bgt`, Professions; then type `/csc`. Data from ForeverDB.net (https://foreverdb.net).
- Equipment set colors: give a set a color from its gear button in the Equipment Manager, and all its items get a border of that color in your bags and bank. An item in two colored sets shows both colors.
- Buff sequences (priest for now): create up to 8 sequences, each with its buffs, their order and rank, and its own key; press it again and again to cast each missing buff on you, your group and pets. Drag a sequence onto an action bar to get a button for it, and pick its icon from the game's icon list (right-click the icon). A buff already there is never cast again, whatever its rank; spells you haven't learned are skipped. Out of combat only. `/bgt buffs`.
- Choose how "Clean up bags" sorts: right-click the button to pick the game's default, pickup order (oldest items first) or most used items first. A "Keep equipment sets together" option puts the items of each set side by side at the start of your bags, with any of these sorts.
- Trinket bar: your two equipped trinkets on screen with their cooldowns, and the trinkets of your bags one hover away. Left-click equips in the top slot, right-click in the bottom slot; a swap asked in combat waits for the end of the fight. A key can be bound to each trinket.
- Target in unit tooltips: a "Target:" line shows what a mob, player or NPC is targeting, and "Target: Me" (in red for a hostile mob or a player of the other faction) when it is you. It follows target changes while the tooltip stays open.

### Improvements
- Search box in the options window: type a few letters to find a tool by its name, its description or one of its settings.
- Room for loot: when nothing in your bags can make room, the window can open anyway and say why. Turn this off to get a single chat line instead.

### Fixes
- Action bar backup: after putting actions back on your bars, BudgetTools offers to reload the interface, so the game doesn't block those buttons in combat.

## 1.0.0

First release. Type `/bgt` or click the minimap button to open the options. Each tool can be turned on or off on its own.

### Options window
- Overview tab: every tool on one line, with a checkbox to turn it on or off.
- English and French, following your game language or picked in the settings.
- Minimap button, and an entry in the game's AddOns options.

### Social
- Player notes and blacklist: rate players, write notes, see them in tooltips and in chat, get warned when a blacklisted player joins, decline their invites or hide their messages.
- Target from the player menu: a Target button when you right-click a name in chat, the friends list or the guild roster.
- One-click LFG application: an Apply button in the Group Browser that whispers your prepared message to the leader, with `{class}`, `{level}`, `{role}` and `{dungeon}` filled in.

### Map
- NPC and item finder: search from the world map, `/npc Name` or `/item Name`, or Alt+click an item. Shows where an NPC stands or where an item comes from. Needs QuestieDB.
- Hunting list: one key targets the most important listed NPC around you and casts your tag spell on it, with a sound and a taskbar flash when one shows up.

### Bags, bars and macros
- Room for loot when your bags are full: offers to destroy a cheaper item, grey junk first, after you confirm.
- Item type names above each group of items in the combined backpack, with adjustable text size and row spacing.
- Macro and emote wheel: hold a key to open up to 8 macros and emotes around the cursor. Works in combat.
- Action bar backup: keeps a copy of your bars for each spec and restores what the dual spec bug removes.

### Professions and leveling
- Pinned recipes: drag a recipe out of the professions window to keep its reagents and bag counts on screen.
- Experience per hour: a small box with XP per hour and the time to your next level.
- Quest chains in the quest log: the step of each quest, and a window with the whole chain and where to start and turn in each quest. Needs QuestieDB.

### Frames and auras
- "Cast by" line in buff and debuff tooltips.
- Hides Boosted Rest on party and raid frames.
- Talents tab in the inspect window, opening the game's talent window on the inspected player.

### Requirements
- QuestieDB for the NPC and item finder and for quest chains.
- Markers on the map need HereBeDragons, which comes with TomTom or Questie.
- TomTom (arrow) and Auctionator (auction prices) are optional.
