# Arma 3 Egg — Age of Clones Edition

Fork of the [official Pterodactyl Arma 3 egg](https://github.com/pterodactyl/game-eggs/tree/main/arma/arma3)
and its [Docker image](https://github.com/Ptero-Eggs/yolks/tree/main/games/arma3) by David Wolfe (Red-Thirten).

**The one big change:** the Steam Workshop mod list is no longer read from an Arma 3 Launcher
`modlist.html` export, but downloaded from a **Strike Launcher `workshop.json` URL** — by default
<https://ageofclones.de/strikelauncher/workshop.json>. The URL is a startup variable, so it can be
changed per server.

Every time the server starts, the list is downloaded, all mods in it are downloaded/updated via
SteamCMD, and they are passed to the server as `-mod=...`. Updating the mod list on the website and
restarting the server is enough — nothing has to be uploaded to the server any more.

## Files

| File | Purpose |
| --- | --- |
| [egg-arma3-aoc.json](egg-arma3-aoc.json) | The egg — import it in the Pterodactyl/Pelican panel under *Nests → Import Egg* |
| [entrypoint.sh](entrypoint.sh) | Container start script (mod list download, mod updates, server start) |
| [Dockerfile](Dockerfile) | Docker image (Debian bookworm, upstream package set plus `jq`) |
| [passwd.template](passwd.template) | NSS wrapper template (unchanged, required by Arma) |

## Expected JSON format

```json
{
  "workshopAddons": [
    { "id": "463939057",  "name": "ace",           "iconUrl": "https://..." },
    { "id": "623475643",  "name": "3den Enhanced", "iconUrl": "https://..." }
  ]
}
```

Only `id` is required; `name` is used purely for nicer log output, and any other field
(such as `iconUrl`) is ignored. A top-level array (`["463939057", ...]`) as well as the keys
`addons`, `mods` and `items`, and the ID field names `publishedFileId` / `fileId`, are also accepted.

## New startup variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `MOD_JSON_URL` | `https://ageofclones.de/strikelauncher/workshop.json` | URL of the mod list. Empty = disabled |
| `MOD_JSON_FILE` | `workshop.json` | File name the list is saved to in the server root. Serves as a fallback if the URL is unreachable, and can be uploaded manually if no URL is set |
| `MOD_JSON_PRUNE` | `0` | `1` = delete downloaded Workshop mods (and their `.bikey` files) that are no longer in the list |

`MOD_FILE` (`modlist.html`) still exists and now defaults to empty. If it is set, its mods are added
on top of the ones from the JSON list, so both sources can be combined.

## Behaviour and safety nets

* **Website unreachable:** the last successfully downloaded `workshop.json` in the server root is
  used, so the server still starts with the correct mod list. If there is no cached copy either,
  only the manually configured mods (`MODIFICATIONS`, `SERVERMODS`, `OPTIONALMODS`) are loaded.
* **Invalid JSON** is rejected before it overwrites the cached copy.
* **`MOD_JSON_PRUNE=1`** only ever deletes directories named `@<numeric workshop id>`. Mods uploaded
  manually under a name (e.g. `@CBA_A3`) and mods from `MODIFICATIONS`/`SERVERMODS`/`OPTIONALMODS`
  are never touched. Cleanup is skipped entirely whenever no valid mod list could be loaded, so a
  failed download can never wipe the installed mods.
* **Mod names** come from the JSON, so the update log shows readable names without an extra request
  to the Steam Workshop page.

## Docker image

The image is the upstream one plus `jq`. Both variants are pre-configured in the egg:

* `ghcr.io/ltsammy/arma3-aoc:latest` — the image of this repository, public and the default in the
  egg. It is built and pushed automatically by
  [.github/workflows/build-image.yml](.github/workflows/build-image.yml) on every push to `main`
  that touches the `Dockerfile`, the `entrypoint.sh` or `passwd.template`.
* `ghcr.io/ptero-eggs/games:arma3` — upstream image as a fallback. Works too: without `jq` the
  entrypoint falls back to a built-in parser that reads the mod IDs (only the mod names are missing
  from the log).

The base is Debian **bookworm** with the package set of the maintained
[parkervcp/yolks](https://github.com/parkervcp/yolks/tree/master/games/arma3) image, because Debian
bullseye — which the older Ptero-Eggs image is based on — has reached end of life and its security
suite no longer serves packages.

Building locally:

```bash
docker build -t ghcr.io/ltsammy/arma3-aoc:latest .
```

## Installation

1. Import `egg-arma3-aoc.json` in the panel (*Nests → Import Egg*).
2. Enter Steam credentials in the egg (`STEAM_USER` / `STEAM_PASS`) — a real account without Steam
   Guard is required; ownership of Arma 3 is only needed for Workshop mods.
3. Create the server, set `MOD_JSON_URL` if needed, and start it.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
