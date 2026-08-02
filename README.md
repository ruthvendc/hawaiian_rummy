# Hawaiian Rummy Scorekeeper

Hawaiian Rummy Scorekeeper is a native iPhone app for keeping a family Hawaiian Rummy game moving. It was created as a tribute to “Purple Grammy” and the family tradition she inspired.

The app keeps score across the game’s seven hands, makes the current objective easy to see, and remembers game history locally on the device.

## Features

- Create a game with two or more saved players.
- Choose players in the same order you want to enter their scores.
- Keep score through all seven hands of Hawaiian Rummy.
- See each hand’s objective and number of cards at a glance.
- Enter and correct scores for previous hands.
- Track round standings and overall game standings; the lowest score always wins.
- Play multiple rounds in a game, then end the game when the table decides.
- Review round-by-round score matrices and final standings.
- Keep reusable player profiles for future games.
- View family records, including game wins, round wins, best rounds, streaks, and the Level 7 record.
- Keep Screen On prevents Auto-Lock while actively scorekeeping.
- Supports Light Mode, Dark Mode, Dynamic Type, and VoiceOver-friendly labels.

## Game Rules Included

The scorekeeper includes these seven hands:

| Hand | Cards | Objective |
| --- | ---: | --- |
| 1 | 7 | 2 Sets |
| 2 | 8 | 1 Run · 1 Set |
| 3 | 9 | 2 Runs |
| 4 | 10 | 3 Sets |
| 5 | 11 | Run of 7 · 1 Set |
| 6 | 12 | 2 Runs · 1 Set |
| 7 | 12 | 2 Sets · 1 Run · No Discards |

All scores are non-negative whole numbers. Lower cumulative scores are better. Ties are shared.

## Privacy

Hawaiian Rummy Scorekeeper is local-first.

- Game, score, and player data stay on the device using SwiftData.
- The app has no account system, backend, analytics, ads, or cloud synchronization.
- Deleting a game removes its associated rounds and scores from the local records.

## Requirements

- macOS with Xcode 26.5 or later
- iOS 26.5 or later

## Run the App

1. Clone this repository.
2. Open `hawiian_rummy_scorekeeper/hawiian_rummy_scorekeeper.xcodeproj` in Xcode.
3. Select an iPhone simulator or connected iPhone.
4. Press **Run** (`⌘R`).

## Project Structure

```text
hawiian_rummy_scorekeeper/
├── DesignSystem/    Theme colors and reusable UI components
├── Models/          SwiftData game, round, player, and score models
├── Services/        Game rules and screen-awake coordination
└── Views/           SwiftUI screens and reusable scorecard views
```

## Family Legacy

The app is intentionally focused on one thing: making it easy for family and friends to spend less time managing scores and more time playing together.
