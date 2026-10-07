# HomeClerk's icon

A page dropping into a folder shaped like a house — household paperwork, filed away.

| File | What it is |
|---|---|
| `folder-back.svg` | The folder's back, with its tab |
| `document.svg` | The page, tilted as if just dropped in |
| `folder-front.svg` | The folder's front pocket, shaped like a house, with a chimney and door |
| `HomeClerk.icon` | The icon the app uses: the three layers as glass over a purple background (`#8E6BF5` → `#5634C8`; deep violet in dark mode) |
| `appearances.png` | `HomeClerk.icon` in each appearance macOS draws |
| `../docs/icon.png` | The icon at the top of the project README |

From `HomeClerk.icon`, macOS 26 and later draw the icon light, dark, clear (light and dark), and
tinted, and Xcode makes the flat icon for macOS 14 and 15.

After editing a layer, run `./update-icon.sh`: it copies the layers into `HomeClerk.icon` and renders
`appearances.png` with Icon Composer's own renderer. To adjust the glass, shadows, or the background
colors, open `HomeClerk.icon` in **Icon Composer** (Xcode ▸ Open Developer Tool ▸ Icon Composer).
