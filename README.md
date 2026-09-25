# Godot 3D Multiplayer Template

Godot 4.7 starter project for building a 3D multiplayer game with player movement, sessions, inventory, equipment, chat, and dedicated-server support.

> This template is also available on the [Godot Asset Library](https://godotengine.org/asset-library/asset/3377) and [Godot Asset Store](https://store.godotengine.org/asset/devmoreir4/godot-3d-multiplayer-template/).

## Key Features

- **Multiplayer Sessions:** Host, join, test multiple local instances, or run a headless dedicated server with support for up to 10 players.
- **Character Controller:** Camera-relative movement, sprinting, double jumping, synchronized animations, and switchable first- and third-person views.
- **Player Profiles:** Four selectable character skins and in-world name tags for every player.
- **Chat and Player List:** Communicate with connected players and view the current session members.
- **Server-Authoritative Inventory:** 16 base slots, 4 backpack slots, stacking, drag and drop, context actions, and server-validated changes.
- **Synchronized Equipment:** Hats, weapons, and backpacks are visible on every player's character.
- **World Items:** Drop, push, and collect physics-based items.
- **Integrated Interfaces:** Inventory, chat, player list, and pause menu coordinate gameplay input and mouse capture.

## Project Structure

- `assets/`: Imported models, textures, icons, fonts, and third-party asset attribution files.
- `scenes/items/`: World-drop scenes organized into backpacks, hats, miscellaneous items, and weapons.
- `scenes/level/`: Main level, arena, and multiplayer player scenes.
- `scenes/ui/`: Inventory, menus, chat, and online-player-list scenes.
- `scripts/autoload/`: Global `Network` and `ItemDatabase` singletons.
- `scripts/inventory/`: Item data, inventory slots, and player inventory state.
- `scripts/items/`: World-item behavior.
- `scripts/level/`: Level and multiplayer session coordination.
- `scripts/player/`: Player controller, character model, and camera support.
- `scripts/ui/`: User-interface behavior.

## How to Run the Project

Follow these simple steps to get the template up and running:

1. **Clone or Download:** Obtain the repository by cloning it via Git or downloading the ZIP file.
2. **Open in Godot Engine:** Load the project in [Godot Engine 4.7](https://godotengine.org).
3. **Execute:** Press <kbd>F5</kbd> or click `Run Project` in the Godot editor.

For local multiplayer testing, open `Debug > Customize Run Instances`, enable `Enable Multiple Instances`, choose the desired number of instances, and run the project.

## Dedicated Server

From the project directory, start a headless server with:

```bash
godot --headless --path .
```

## Deploying to Render.com

This project supports running as a dedicated cloud server on [Render.com](https://render.com) using WebSockets (`WebSocketMultiplayerPeer`), overcoming Render's lack of raw UDP routing.

### 1. Deploy the Server on Render
1. Push this repository to GitHub.
2. Log into [Render.com](https://render.com) and click **New + > Web Service**.
3. Select your repository.
4. Render will automatically detect the `Dockerfile` (or use Blueprint with `render.yaml`).
5. Choose the **Free** instance type and click **Create Web Service**.
6. Once deployed, Render will provide a public URL: `https://your-service-name.onrender.com`.

### 2. Connect Players (Join Option)
In the game client's Main Menu:
- In the **Server Address** field, enter your Render secure WebSocket URL:
  ```text
  wss://your-service-name.onrender.com
  ```
  *(You can also omit `wss://` and enter `your-service-name.onrender.com` directly; the client will auto-detect it).*
- Click **JOIN** to connect to the cloud server!

### 3. Local Hosting (Host Option)
- Click **HOST** in the client to run a local server instance.
- Other local clients can join by entering `127.0.0.1` or the host's LAN IP address.

## Controls

- <kbd>W</kbd> <kbd>A</kbd> <kbd>S</kbd> <kbd>D</kbd> to move.
- <kbd>Shift</kbd> to run.
- <kbd>Space</kbd> to jump or double jump.
- Left mouse button to play the attack animation (visual only, without damage).
- <kbd>E</kbd> to collect a nearby item.
- <kbd>Esc</kbd> to open or close the pause menu.
- <kbd>T</kbd> to hide/show chat.
- <kbd>I</kbd> to toggle inventory.
- Hold <kbd>Tab</kbd> to show the online player list.
- <kbd>V</kbd> to switch between first-person and third-person views.
- <kbd>F1</kbd> to add a random test item (debug builds, host only).
- <kbd>F2</kbd> to print the local inventory (debug).

## Contributing

If you want to contribute to this project, please refer to our [Contributing Guidelines](CONTRIBUTING.md).

## Credits

- 3D Godot Robot Platformer Character, by AGChow, licensed under CC0. See [`assets/characters/player/ATTRIBUTIONS.md`](assets/characters/player/ATTRIBUTIONS.md).
- Item models and icons by Poly by Google and Quaternius. See [`assets/items/ATTRIBUTIONS.md`](assets/items/ATTRIBUTIONS.md).
- Prototype environment textures by Kenney, licensed under CC0. See [`assets/environment/ATTRIBUTIONS.md`](assets/environment/ATTRIBUTIONS.md).

## License

The project source code is available under the [MIT License](LICENSE). Third-party assets are excluded from that license and remain available under the terms documented in their respective attribution files.
