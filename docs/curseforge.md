<p style="text-align:center"><img src="https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/banner.png" alt="BudgetTools" width="400"></p>

BudgetTools adds small tools to WoW Forever that the default interface lacks. You switch each one on or off in a single window, so you run the ones you use and skip the rest.

BudgetTools keeps growing: the tools get better with each update, and new ones arrive regularly.

Type `/bgt` or click the minimap button to open it.

![The overview tab: every tool on one line](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/overview.png)

## Know who you group with

**Player notes and blacklist.** Right-click a player in chat, your friends list, the guild roster, a group frame or the target frame. Write a note, rate the player, or blacklist them. Your notes show up in tooltips and next to names in chat, and all your characters share them. For blacklisted players, you can get a warning when they join your group, decline their invites, or hide their messages.

![Note and blacklist in the right-click menu](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/notes-menu.png) ![Writing a note about a player](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/notes-editor.png)

![Note icon next to a name in chat](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/notes-whisper.png)

![Your note when the player joins your group](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/notes-join.png)

**Target from the player menu.** Right-click a name in chat, the friends list or the guild roster and pick Target. The player has to be nearby, and the game blocks this in combat.

**One-click LFG application.** Select a group in the Group Browser and click Apply. BudgetTools whispers your prepared message to the leader. The message can hold `{class}`, `{level}`, `{role}` and `{dungeon}`, and BudgetTools fills them in for each group. Groups you applied to get a mark.

![The application message editor](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/lfg-message.png)

## Find things on the map

**NPC and item finder.** Type a name in the search bar on the world map, or use `/npc Name` and `/item Name`. The map shows where the NPC stands, or where the item comes from: vendors, mobs, gathering nodes and quests. Alt+click an item to look it up. Hold Shift when you pick a result to get a TomTom arrow.

The finder reads its data from the **QuestieDB** addon, so install that too. QuestieDB knows quest items, vendors and gathering nodes. Its data has gaps for random drops, raid loot and crafted items.

![Search bar on the world map](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/finder-search.png)

![An NPC shown on the map](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/finder-map.jpg)

**Hunting list.** Build a list of the NPCs you are after. One key targets the most important one around you and casts your tag spell on it, so you can spam it while you ride. A sound and a taskbar flash tell you when a listed NPC shows up.

## Bags, bars and macros

**Room for loot when your bags are full.** Your bags are full and something good drops. BudgetTools offers to destroy a cheaper item so you can take the loot, grey junk first. You confirm with a click before anything goes. It leaves out blue and better items, quest items, keys, bags, lockboxes and profession tools. With Auctionator installed, it compares auction prices.

![Room for loot: a cheaper item proposed for destruction](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/loot-swap.png)

**Item type names in the combined bag.** A small name (Consumable, Weapon, Quest...) sits above the first item of each group in the combined backpack, so you see where "Clean up bags" put each kind of item. Grey items share one name, Junk. You choose the text size and how much room the rows leave for the names.

![Type names in the combined backpack](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/bag-types.png)

**Your own sort for "Clean up bags".** Right-click the clean-up button of your bags to choose how it sorts: the game's default, pickup order (the items you got first come first, the newest last) or most used items first. Pickups and uses are counted per character. Nothing is grouped by type, not even grey items, and the type names are hidden while these sorts are on. Bags set to "Ignore this bag" stay as they are. Tick "Keep equipment sets together" and every sort, the game's default included, puts the items of each equipment set side by side at the start of your bags.

![The sort choice and the option that keeps equipment sets together](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/set-colors-option.png)

**Equipment set colors.** Give an equipment set a color from its gear button in the Equipment Manager. Every item of that set gets a border of that color in your bags and bank, so you see at a glance what belongs to which set. An item in two colored sets shows both colors. Each character has its own colors.

![Choosing a set's color in the Equipment Manager](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/set-colors-menu.png) ![Set items with their colored border, kept together in the bags](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/set-colors-bags.png)

**Macro and emote wheel.** Hold a key and a wheel of up to 8 macros and emotes opens around your cursor. Move toward one and release. It works in combat.

![The wheel open around the cursor](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/wheel.png) ![Setting up the wheel](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/wheel-editor.png)

**Action bar backup.** Dual spec on WoW Forever can empty your action bars. BudgetTools keeps a copy of your bars for each spec and puts back the actions the game loses after a logout, a reload or a spec swap. It saves spells with their exact rank and waits for the end of a fight before it restores anything.

**Trinket bar.** A small bar shows your two equipped trinkets and their cooldowns. Click one to use it, or give each a key. Hover the bar to see the trinkets in your bags: left-click equips one in the top slot, right-click in the bottom slot. The game blocks trinket swaps in combat, so the one you pick waits and goes on when the fight ends.

**Buff sequences (priest for now).** Create up to 8 sequences, each with its buffs, their order and rank, and its own key. Press the key again and again to cast each missing buff on you, your group and pets. Drag a sequence onto an action bar to get a button for it. A buff already there is never cast again, whatever its rank, and spells you haven't learned are skipped. Out of combat only. Set them up with `/bgt buffs`.

## Professions and leveling

**CraftScout: margin and profit per craft.** An optional module, in the same download. Scan the Auction House and CraftScout shows what each recipe you can craft earns: its sale price after the auction cut, minus the cost of its reagents. Compare prices from the last scan or a 72-hour average, and see what to make with the reagents in your bags. It stays off and is not even loaded until you tick it in `/bgt`, Professions. Then type `/csc`, or tick its minimap button on the same card.

![CraftScout: the recipes you can craft, ranked by margin, with the detail of the selected one](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/craftscout-best-crafts.png)

![Use my reagents: what to craft with the reagents you own](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/craftscout-reagents.png) ![Picking reagents from your bags and bank](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/craftscout-my-bags.png)

**Pinned recipes.** Drag a recipe name out of the professions window. Its reagents stay on screen in a small note that counts them in your bags: green when you have enough, gold when your bank covers the rest, red when some are missing. Set how many crafts you want and the counts follow.

![Dragging a recipe out of the professions window](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/recipe-drag.png)

![Recipe notes with their reagent counts](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/recipe-notes.png)

**Experience per hour.** A small box shows the XP you earn per hour this session and the time left until your next level. Right-click it to pick its lines, its size and its background.

**Quest chains in the quest log.** A quest that belongs to a chain shows its step (2/5) in the quest log. One click opens the whole chain in its own window: the quests you have done, the ones in your log and what comes next. Select a quest to see its objective, rewards and XP, and show its giver and turn-in on the map. Needs QuestieDB.

![The quest chain window showing XP, money and two reward choices](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/quest-chain-rewards.png)

## Frames and auras

**Who cast that buff.** Buff and debuff tooltips gain a "Cast by" line with the caster's name in class color. It works on your buff bar and the party frames. Forever locks the tooltips of the target frame and the raid-style frames, so those stay as they are.

![Cast by line in a buff tooltip](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/aura-caster.png)

**Who is it targeting.** Unit tooltips gain a "Target:" line with the name of what the unit is targeting, in class color, or "Target: Me" (red for a hostile mob or a player of the other faction) when it is you. The line follows target changes while the tooltip stays open.

**Hide Boosted Rest on raid frames.** BudgetTools removes the Boosted Rest icon from party and raid frames, so the debuffs you need to see keep their place. The bonus itself stays on.

**Talents tab in the inspect window.** The inspect window gains a Talents tab under Character, PvP and Guild. One click opens the game's talent window on the player you are inspecting, without going back to their right-click menu. A button on the talent window brings you back to the inspect window.

![The Talents tab in the inspect window](https://raw.githubusercontent.com/jBeyondstars/BudgetTools/main/docs/screenshots/inspect-talents.png)

## Commands

| Command                    | What it does                                             |
| -------------------------- | -------------------------------------------------------- |
| <code>/bgt</code>           | Open or close the options                                |
| <code>/bgt note Name</code> | Write a note about a player                              |
| <code>/bgt lfg</code>       | Edit your LFG application message                        |
| <code>/bgt wheel</code>     | Set up the macro and emote wheel                         |
| <code>/npc Name</code>     | Find an NPC on the world map                             |
| <code>/item Name</code>    | Show where an item comes from                            |
| <code>/hunt Name</code>    | Add an NPC to your hunting list                          |
| <code>/bgt bars</code>      | Check, save or restore your action bar copy              |
| <code>/bgt xp</code>        | Print your XP per hour in chat                           |
| <code>/bgt trinket</code>   | List your equipped trinkets (<code>reset</code> puts the bar back in place) |
| <code>/bgt buffs</code>   | Set up your buff sequences                               |
| <code>/csc</code>         | Open CraftScout, once its module is on                   |
| <code>/bgt auras</code>     | List the auras hidden on raid frames                     |
| <code>/bgt reset</code>     | Restore the default settings (your notes and lists stay) |

## Works with

*   **QuestieDB**: required for the NPC and item finder and for quest chains.
*   **TomTom**: optional, for the arrow toward an NPC.
*   **Auctionator**: optional, for auction prices when your bags are full.

## Languages

English and French. BudgetTools follows your game language, and you can change it in its settings.

## Credits

CraftScout: Data from ForeverDB.net (https://foreverdb.net). Recipe details also come from WhatsTraining (MIT License). CraftScout is licensed under GPL-3.0.

## Feedback

Found a bug, or want a tool added? Leave a comment below.
