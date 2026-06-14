# torrent-nas

Automatically transfers completed torrents from a qBittorrent Docker container to a NAS, creating a clean `Movie Name (Year)` folder structure using TMDB metadata.

## Why

Downloading directly to a NAS over SMB is often bottlenecked by the network protocol overhead — the NAS can't saturate a fast internet connection. The solution is to download to a local fast disk first, then rsync to the NAS after the torrent completes. This repo contains the script that does that handoff, plus the Docker Compose setup to wire it in.

## How it works

qBittorrent has a built-in "Run program after torrent finishes" option. It calls `torrent-done.sh` with the torrent name as an argument. The script:

1. Parses the raw release filename (e.g. `Some.Great.Film.2024.1080p.WEB-DL.H264.mkv`) to extract a rough title and year
2. Queries the [TMDB API](https://www.themoviedb.org/) to get the canonical movie title
3. For non-English films, uses the `original_title` field so the folder name is in the film's original language
4. Creates `/mnt/nas/torrents/{Title} ({Year})/` and rsyncs the file there
5. Single-file torrents are renamed to match the folder: `Some Great Film (2024).mkv`
6. Falls back to a regex-cleaned version of the filename if TMDB returns no match
7. Removes the source file/folder after a successful transfer

## Project structure

```
.
├── compose.yaml                  # qBittorrent Docker Compose stack
├── .env.example                  # environment variable template
└── scripts/
    ├── torrent-done.sh           # runs on download completion
    └── torrent-name-preview.sh   # dry-run: shows what folder/file would be created
```

## Setup

### 1. Mount your NAS

The script transfers files to `/mnt/nas` on the host. This must be a real filesystem mount — Docker bind-mounts the host path into the container, so the NAS needs to be mounted on the host before the container starts.

**SMB / CIFS (most home NAS devices — Synology, QNAP, TrueNAS, etc.)**

Install the client and create the mount point:

```bash
sudo apt install cifs-utils
sudo mkdir -p /mnt/nas
```

Mount it manually to test:

```bash
sudo mount -t cifs //192.168.1.x/share /mnt/nas -o username=youruser,password=yourpass,uid=1000,gid=1000,vers=3.0
```

To make it survive reboots, add it to `/etc/fstab`:

```
//192.168.1.x/share  /mnt/nas  cifs  username=youruser,password=yourpass,uid=1000,gid=1000,vers=3.0,_netdev  0  0
```

The `_netdev` flag tells the system to wait for the network before mounting, which is important on boot.

**NFS (alternative)**

```bash
sudo apt install nfs-common
sudo mkdir -p /mnt/nas
sudo mount -t nfs 192.168.1.x:/path/to/share /mnt/nas
```

`/etc/fstab` entry:

```
192.168.1.x:/path/to/share  /mnt/nas  nfs  defaults,_netdev  0  0
```

**Verify the mount is working:**

```bash
mountpoint -q /mnt/nas && echo "mounted" || echo "not mounted"
```

The `torrent-done.sh` script checks this at runtime and aborts if the NAS is not mounted, so nothing is lost if the NAS goes offline.

---

### 3. TMDB API key

Create a free account at [themoviedb.org](https://www.themoviedb.org/) and generate an API key under **Settings → API → API Key (v3 auth)**.

> **Attribution:** This project uses the TMDB API. Per their terms, you must display the TMDB logo in any UI that shows results. This script runs headlessly and stores files — no UI is shown — but be aware of [TMDB's terms of use](https://www.themoviedb.org/api-terms-of-use) if you extend it.
>
> This product uses the TMDB API but is not endorsed or certified by TMDB.

### 4. Environment file

On the server, create `.env` next to your `compose.yaml`:

```bash
TMDB_API_KEY=your_api_key_here
```

`compose.yaml` reads `${TMDB_API_KEY}` from this file automatically when you run `docker compose up`.

### 5. Deploy the stack with Dockge

`compose.yaml`:

```yaml
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/London
      - WEBUI_PORT=8080
      - TORRENTING_PORT=6881
      - DOCKER_MODS=linuxserver/mods:universal-package-install
      - INSTALL_PACKAGES=rsync
      - TMDB_API_KEY=${TMDB_API_KEY}
    volumes:
      - /opt/stacks/qbittorrent/config:/config
      - /home/user/downloads:/downloads
      - /opt/scripts:/opt/scripts
      - /mnt/nas:/mnt/nas
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    stop_grace_period: 10s
    restart: unless-stopped
networks:
  default:
    driver: bridge
    driver_opts:
      com.docker.network.driver.mtu: "1450"
```

1. In Dockge, create a new stack (e.g. `main`)
2. Paste the contents of `compose.yaml` into the compose editor
3. Make sure the `.env` file is in the same directory as `compose.yaml` on the server
4. Click **Deploy**

The stack expects these paths to exist on the host — adjust them in `compose.yaml` to match your setup:

| Host path | Purpose |
|-----------|---------|
| `/opt/stacks/qbittorrent/config` | qBittorrent config and logs |
| `/home/user/downloads` | Active download directory |
| `/opt/scripts` | Location of the scripts in this repo |
| `/mnt/nas` | NAS mount point (SMB/NFS) |

**PUID / PGID:** The `PUID` and `PGID` values in `compose.yaml` control which user the container runs as. Set these to the UID/GID of your server user so that created files have the right ownership. Find yours with:

```bash
id
```

### 6. Copy scripts to the server

```bash
scp scripts/torrent-done.sh scripts/torrent-name-preview.sh user@server:/opt/scripts/
ssh user@server 'chmod +x /opt/scripts/torrent-done.sh /opt/scripts/torrent-name-preview.sh'
```

### 7. Configure qBittorrent to run the script

1. Open the qBittorrent web UI (default: `http://server-ip:8080`)
2. Go to **Tools → Options → Downloads**
3. Scroll to **Run program on torrent completion**
4. Check the box and enter:
   ```
   /opt/scripts/torrent-done.sh "%N"
   ```
   `%N` is the torrent name as qBittorrent passes it — the full raw release name.
5. Click **Save**

> **Note:** The script path `/opt/scripts` is mounted into the container via the `volumes` section in `compose.yaml`, so the container can find and execute it.

### 8. Test before using

Use the preview script to verify the output for any filename without touching real files:

```bash
# Without TMDB (shows fallback parsing only):
bash /opt/scripts/torrent-name-preview.sh "Some.Great.Film.2024.1080p.BluRay.x264.mkv"

# With TMDB lookup:
TMDB_API_KEY=your_key bash /opt/scripts/torrent-name-preview.sh "Some.Great.Film.2024.1080p.BluRay.x264.mkv"
```

Example output:
```
[parse] title='some great film' year='2024'
[tmdb] querying 'some great film' (2024)
[tmdb] matched: 'Some Great Film'
Folder : Some Great Film (2024)
File   : Some Great Film (2024).mkv
```

## Logs

Transfer logs are written to `/config/torrent-transfer.log` inside the container, which maps to `/opt/stacks/qbittorrent/config/torrent-transfer.log` on the host.

```bash
tail -f /opt/stacks/qbittorrent/config/torrent-transfer.log
```

## License

Scripts in this repository are released under the [MIT License](LICENSE).
