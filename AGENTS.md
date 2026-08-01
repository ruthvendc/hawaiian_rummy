# AGENTS.md

# Family Card Scorekeeper

## Project Overview

This repository contains a native iPhone application that keeps score for a
family card game.

The application should be simple, fast, and enjoyable to use while people are
actively playing.

Primary goals:

- Create a new game.
- Add, edit, and remove players.
- Record scores for each round.
- Display running totals.
- Review and edit previous rounds.
- Determine the winner.
- Start a rematch using the same players.

Favor simplicity, reliability, and ease of use over unnecessary features.

---

# Platform

- Native iPhone application
- Swift
- SwiftUI
- Xcode
- SwiftData for local persistence
- XCTest / Swift Testing

Unless explicitly requested:

- Do not introduce a backend.
- Do not introduce cloud synchronization.
- Do not introduce user accounts.
- Do not introduce analytics.
- Do not introduce advertising.

---

# Architecture

Use a lightweight MVVM architecture.

Responsibilities:

## Models

Represent the game state.

Examples:

- Game
- Player
- Round
- ScoreEntry

## Views

Responsible only for presentation and user interaction.

Views should remain small and easy to understand.

Extract reusable view components when appropriate.

## ViewModels

Contain presentation logic and coordinate user actions.

Business logic should not live directly inside SwiftUI views.

---

# Development Standards

## Swift

- Use SwiftUI unless UIKit is clearly required.
- Prefer Apple frameworks over third-party libraries.
- Use SwiftData for persistence.
- Use structured concurrency with async/await.
- Keep UI work on the Main Actor.
- Prefer value types.
- Prefer let over var whenever possible.
- Avoid force unwraps and force casts.
- Handle optionals safely.
- Use descriptive names.
- Keep functions focused and readable.
- Remove unused code.
- Do not leave commented-out code.
- Use `// MARK:` where appropriate.

## SwiftUI

- Keep Views small.
- Extract reusable components.
- Prefer composition over very large Views.
- Support Dynamic Type.
- Support Dark Mode.
- Add accessibility labels where appropriate.
- Use native Apple controls whenever possible.

---

# User Experience

The application should require as few taps as possible.

The active game screen should prominently display:

- Player names
- Running totals
- Current round
- Enter Scores button
- Edit Previous Round button

Destructive actions should require confirmation.

Examples:

- Delete Game
- Reset Scores
- Remove Player
- End Game

Never silently discard user data.

---

# Data Model

Suggested entities:

## Game

- id
- createdDate
- completedDate
- players
- rounds
- status

## Player

- id
- name
- runningTotal

## Round

- id
- roundNumber
- scoreEntries

## ScoreEntry

- playerID
- score

These are suggestions and may evolve as game rules become better defined.

---

# Persistence

Use SwiftData.

Requirements:

- Preserve games between launches.
- Preserve unfinished games.
- Store completed games.
- Avoid storing values that can be recalculated.
- Never lose user-entered scores.

---

# Accessibility

- Dynamic Type
- VoiceOver labels
- Adequate touch targets
- High contrast
- Never rely solely on color

---

# Testing

Add unit tests for business logic.

Important scenarios:

- Add players
- Remove players
- Record scores
- Edit scores
- Running totals
- Winner calculation
- Tie handling
- Save/restore games

UI tests are encouraged only for important user flows.

---

# Workflow

When beginning work:

1. Read AGENTS.md.
2. Inspect the existing project.
3. Explain the implementation approach.
4. Ask questions if requirements are ambiguous.

When implementing:

- Make focused changes.
- Preserve existing behavior.
- Modify existing files when appropriate.
- Create new files only when they represent a new responsibility.
- Do not reorganize the project without approval.

After implementation:

- Summarize what changed.
- List files modified.
- Explain architectural decisions.
- Report build or test results.
- Mention anything that remains unverified.

Build or test after editing whenever possible.

Never delete working functionality merely to resolve a build error.

---

# Project Rules

Unless explicitly requested:

Do NOT:

- Change bundle identifiers.
- Change signing settings.
- Change entitlements.
- Change deployment targets.
- Modify project capabilities.
- Add package dependencies.
- Add external services.

Explain why before performing any of the above.

---

# Git

- Keep commits focused.
- Never rewrite Git history.
- Do not create commits unless requested.
- Do not push unless requested.
- Never overwrite unrelated user changes.

---

# Security & Privacy

This application is local-first.

Do not:

- Upload user data.
- Add telemetry.
- Add analytics.
- Add tracking.
- Send game information over the network.

Player names and game history should remain local unless the user explicitly requests otherwise.

---

# Scope Control

Stay focused on the requested feature.

Do not introduce unrelated improvements while implementing a task.

Prefer a polished scorekeeper over an over-engineered application.

---

# Game Rules

Do not invent scoring rules.

Before implementing scoring logic, confirm:

- Number of players
- Number of rounds
- How points are scored
- Whether high or low score wins
- Whether negative scores are allowed
- Tie-breaking rules
- Whether players may join mid-game
- Whether games can be resumed later

Until these rules are defined, keep the scoring engine flexible.
