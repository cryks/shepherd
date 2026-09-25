# Changelog

## Unreleased

### Fixed

- The menu panel hotkey works on macOS 27.

## v0.17.0 - 2026-09-08

### Changed

- Supports herdr 0.9.0 (protocol 22).

## v0.16.0 - 2026-08-20

### Added

- Notifications can play a sound, chosen separately for blocked and done
  agents.
- Agent icons include Grok.

### Changed

- Supports herdr protocol 20.

### Fixed

- Status labels sit centered beside the heading instead of above it.

## v0.15.0 - 2026-08-04

### Added

- Display lines take a line count, so a long excerpt can wrap instead of
  truncating.

### Changed

- Shepherd tracks herdr protocol 19; a server on another protocol is
  monitored with a warning, and "not supported" appears only when reading
  it fails.
- The monospace row style matches the body text size.

### Fixed

- Codex rows no longer mistake unrecognized history cells for the reply.
- Claude and Codex rows keep the latest excerpt while the pane is scrolled
  back, instead of picking up history or the scrollback indicator text.
- Menu excerpts show every configured line instead of sometimes truncating
  one line early.

## v0.14.0 - 2026-07-30

### Added

- The update dialog shows release notes.

### Changed

- The notification body takes any number of lines, and a line that renders
  empty is left out.
- `{excerpt}` works in notification templates, so a body line decides where the
  excerpt goes. Saved templates gain that line where the excerpt used to be
  added.

### Fixed

- Agent rows no longer change order between refreshes when pane IDs contain letters.
- The working status no longer washes out in light mode.

## v0.13.0 - 2026-07-25

### Added

- A Display settings tab with editable templates for agent rows and notifications.
- Global hotkeys for the menu bar panel and the pop-out window.

### Changed

- Drag to reorder display lines and remote hosts.

### Fixed

- The settings window no longer flashes wider on first open.
