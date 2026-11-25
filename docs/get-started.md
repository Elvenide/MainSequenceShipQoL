# Getting Started with Elvenide's Ship QoL

> [!NOTE]
> **Main Sequence vs. Demo**: **Elvenide's Ship QoL** is tested and working in the full version of **Main Sequence**. While it may work in the **Main Sequence Demo**, it is developed exclusively for the full game and using it in the demo is not recommended.

**Elvenide's Ship QoL** is a standalone, client-side UE4SS Lua mod for **Main Sequence**. It is designed to be 100% save-safe and cleanly removable at any time without affecting your save files.

## Prerequisites

- **Main Sequence** installed via Steam (default: `C:\Program Files (x86)\Steam\steamapps\common\Main Sequence`)
- **UE4SS v4.0.0+** (Unreal Engine 5.7 compatible)

## Installation

Choose either **MSCoreManager** (recommended) or **Manual UE4SS Installation** below.

### Option 1: Install with MSCoreManager (Recommended)

1. **Install MSCoreManager & UE4SS** (if you haven't already):
   - Download the latest **MSCoreManager** executable by **xxalex3xx97** from [github.com/xxalex3xx97/MSCore/releases/latest](https://github.com/xxalex3xx97/MSCore/releases/latest).
   - Run `MSCoreManager` and follow its prompts to automatically install and configure UE4SS for *Main Sequence*.
2. **Install Elvenide's Ship QoL**:
   - Open **MSCoreManager** and click **Add mod...**.
   - Paste in `https://github.com/Elvenide/MainSequenceShipQoL` to install automatically from GitHub Releases (MSCoreManager uses `manifest.txt` and **$(System.Collections.Hashtable.ZipBase)-v<version>.zip**).
   - *(Alternatively, if installing from a local archive in MSCoreManager, download **$(System.Collections.Hashtable.ZipBase)-v<version>.zip** from [github.com/Elvenide/MainSequenceShipQoL/releases](https://github.com/Elvenide/MainSequenceShipQoL/releases).)*
3. **Launch Main Sequence**:
   - **Elvenide's Ship QoL** will automatically create/update `ElvenidesShipQoL\config.json` with default keybinds on first launch.
   - Open **Settings → Controls** at any time to rebind hotkeys.

### Option 2: Manual UE4SS Installation

1. **Install UE4SS** (if you haven't already):
   - Download the latest UE4SS release (`UE4SS_v4.0.0.zip` or newer) from the [RE-UE4SS Releases page](https://github.com/UE4SS-RE/RE-UE4SS/releases).
   - Extract the contents into your game's `Win64` folder:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\
     ```
     (You should see `dwmapi.dll` and the `ue4ss\` folder inside `Binaries\Win64\`.)
   - Open `ue4ss\UE4SS-settings.ini` and set the engine version override for Main Sequence:
     ```ini
     [EngineVersionOverride]
     MajorVersion = 5
     MinorVersion = 7
     ```
2. **Install Elvenide's Ship QoL**:
   - Download **$(System.Collections.Hashtable.ZipBase)-v<version>.zip** from [github.com/Elvenide/MainSequenceShipQoL/releases](https://github.com/Elvenide/MainSequenceShipQoL/releases).
   - Open the zip, navigate into its `Mods\` folder, and copy the `ElvenidesShipQoL` folder into:
     ```
     Main Sequence\Windows\MainSequence\Binaries\Win64\ue4ss\Mods\ElvenidesShipQoL\
     ```
     *(You can safely leave `mscore.mod` inside `ElvenidesShipQoL\`—UE4SS ignores it.)*
   - Ensure `ElvenidesShipQoL\enabled.txt` exists (an empty file is fine).
   - Open `ue4ss\Mods\mods.txt` and add `ElvenidesShipQoL : 1` **above** `Keybinds : 1`:
     ```ini
     ElvenidesShipQoL : 1

     ; Built-in keybinds, do not move up!
     Keybinds : 1
     ```
3. **Launch Main Sequence**:
   - **Elvenide's Ship QoL** will automatically create/update `ElvenidesShipQoL\config.json` with default keybinds on first launch.
   - Open **Settings → Controls** at any time to rebind hotkeys.

## Uninstalling

- Remove or rename `ElvenidesShipQoL\enabled.txt` (or delete the `ElvenidesShipQoL` folder and remove `ElvenidesShipQoL : 1` from `mods.txt`).
- Your saves remain completely intact with no missing-mod dependencies.