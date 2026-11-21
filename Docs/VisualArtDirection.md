# Miau Motel Visual Art Direction

Miau Motel uses an original isometric pixel-art style inspired by the general readability of classic social-island games. The goal is a cozy, compact, colorful motel world with crisp silhouettes and playful room dressing.

## Core Rules

- **Projection:** 2:1 isometric. Floor tiles are always `64 x 32` pixels.
- **Vertical unit:** one block height is `32` pixels.
- **Pixel size:** all gameplay sprites use the same screen pixel density. Do not mix 16 px, 32 px, and 64 px sprite grids in the same scene.
- **Edges:** hard pixel edges only. No anti-aliasing, no blurred textures, no smooth gradients.
- **Outlines:** use the dark warm outline color for important silhouettes. Interior details may omit outlines.
- **Lighting:** light comes from the upper-left. Top faces are lightest, left faces are mid-tone, right faces are darkest.
- **Anchors:** floor tiles are centered on their diamond. Block faces are unit-square textures mapped by `Block.gd`. Characters and furniture are bottom-center anchored so the logical origin stays at the floor contact point.
- **Collision:** logical footprints, elevations, and collision shapes stay independent from sprite art. Replacing a PNG must not require changing movement or collision code.

## Palette

| Role | Color | Hex |
| --- | --- | --- |
| Outline / ink | Dark cocoa | `#2B2320` |
| Warm cream | Soft wall cream | `#F6E7C8` |
| Paper highlight | Pale cream | `#FAF4E2` |
| Floor sand | Light wood sand | `#E8C98F` |
| Wood light | Honey wood | `#D9A066` |
| Wood mid | Warm wood | `#B97A4E` |
| Wood dark | Deep wood | `#7A4B32` |
| Coral accent | Motel coral | `#F08A7A` |
| Teal accent | Pool teal | `#4E9A94` |
| Mustard accent | Lamp mustard | `#F2C14E` |
| Sky accent | Window sky | `#8FC1D4` |
| Pink accent | Cat pink | `#F2A7C3` |
| Skin | Warm skin | `#F6D9B8` |
| Pants | Denim blue | `#3E5C76` |

Use the palette as a starting point. New assets should stay within these hues or add closely related shades.

## Required Placeholder Set

| Asset | Path | Size | Notes |
| --- | --- | --- | --- |
| Floor tile | `Assets/Sprites/Tiles/floor_iso.png` | `64 x 32` | Transparent corners, wood-plank diamond, dark outline. |
| Standard block top | `Assets/Sprites/Blocks/block_top.png` | `32 x 32` | Lightest face; maps to the top diamond. |
| Standard block left | `Assets/Sprites/Blocks/block_left.png` | `32 x 32` | Mid-tone face; maps to the left side. |
| Standard block right | `Assets/Sprites/Blocks/block_right.png` | `32 x 32` | Darkest face; maps to the right side. |
| Stacked block example | `Scenes/Test/VisualStyleTest.tscn` | n/a | Two standard blocks stacked by elevation, not a special sprite. |
| Player directional sprites | `Assets/Sprites/Player/player_iso_*.png` | `32 x 64` | Four isometric cat-guest directions: down_right, up_left, down_left, up_right. |
| Room background | `Assets/Backgrounds/room_background.png` | `640 x 360` | Simple motel wall/window backdrop behind the isometric floor. |

## Replacement Workflow

1. Keep the same file name and dimensions when replacing placeholder art.
2. Update resources or scenes only if a new asset needs a different path.
3. Do not change `IsometricGrid`, `BlockLayer`, `Player`, or collision scripts for visual-only updates.
4. Run `Tools/generate_placeholder_art.py` to regenerate the current placeholder set.
5. Open `Scenes/Test/VisualStyleTest.tscn` or run the project to inspect the set in context.
