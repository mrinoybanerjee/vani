# Vani visual system

A quiet native writing tool. Warm paper, forest green, comfortable reading, immediate actions.

- Light: paper #FAF9F6, sidebar #F0F0EA, accent #315E48.
- Dark: paper #202321, sidebar #191C1A, accent #A4C9AD.
- Text: native primary and secondary labels. Never encode state only in color.
- Mark: five rounded bars sharing a top line, lengths 150 · 270 · 400 · 270 · 150 (width 56, gap 36), so the waveform forms a V. Paper bars on a forest tile for the app icon; accent bars beside the rounded `vani` wordmark; a monochrome template in the menu bar. Never redraw it by hand: `VaniMark` in code, and `swift scripts/make-app-icon.swift` regenerates the icon.
- Recording motion: the listening icon's bars follow the real microphone level and rest in silence.
- Typography: system sans for controls (12–14 pt) and editor body (15 pt, 6 pt extra line spacing); system serif for workspace headings (28–34 pt). Rounded system wordmark.
- Spacing: 4, 8, 12, 16, 20, 24, 32. Notebook content measure bounded at 780 pt including padding.
- Shape: 6 pt keycaps, 8 pt fields, 10 pt selected note; capsule for ambient status.
- Native controls retain keyboard navigation, focus indicators, selection, context menus and accessibility labels.
- Motion conveys recording only; respect Reduce Motion. Status remains understandable with animation disabled.
- Show saved, unsaved and failed states truthfully. Preserve text before navigating away. Never imply that plaintext local notes are encrypted.
- No decorative card grids, gradients, scoreboards, promotional UI or fake features.

See [redesign rationale](docs/REDESIGN_2026-09-12.md) and [product behavior](docs/PRODUCT_DESIGN.md).

Meetings, Notes and Settings share one native workspace and one navigation sidebar.
The selected library lives below navigation; Settings uses a native section picker.
See [workspace layout and lifecycle](docs/WORKSPACE_DESIGN.md).
