# Changelog

## 1.4
- Added support for the WoW Forever client (Interface 16001); still loads on 3.3.5a.
- Dropdown uses `BackdropTemplate` where the client requires it (fixes `SetBackdrop`
  errors on newer clients).
- `math.atan2` fallback for dragging the launcher on newer Lua builds.
- Icon scan also handles texture file IDs (numbers) on newer clients.

## 1.3
- Ctrl + Alt + mouse wheel over the launcher changes its opacity; hovering restores full
  opacity unless Ctrl + Alt is held. Opacity is saved.
- Tooltip explains the opacity controls and shows the current value.
- `/mbs reset` also resets opacity.

## 1.2
- Fixed stretched / "dripping" icons in the list (icon texture coordinates were not
  copied correctly).

## 1.1
- Custom round launcher icon.
- Finds buttons nested one level deep (for example Atlas) and checks minimap
  replacement frames such as DragonUI.
- Launcher is placed on the minimap edge based on the minimap's actual size.
- Added `/mbs list`.

## 1.0
- Initial release: collects minimap buttons into a single dropdown.
