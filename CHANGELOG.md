# Changelog

## Unreleased

### Added

- Display lines take a line count, so a long excerpt can wrap instead of
  truncating.

### Changed

- The monospace row style matches the body text size.

### Fixed

- Codex rows no longer mistake unrecognized history cells for the reply.

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
