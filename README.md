# Core stack

The base layer for a home server: DNS with ad blocking, remote access and a
start page for the whole household. Configured from a single `.env` file.

| Service           | Role                                                      | Default address                |
|-------------------|-----------------------------------------------------------|--------------------------------|
| AdGuard Home      | DNS server with ad and tracker blocking for every device  | `http://<server>:8053`, DNS on port 53 |
| Homepage          | Start page with a tile for every app, plus status         | `http://<server>` (port 80)    |
| Cloudflare Tunnel | Exposes selected apps to the internet, no open ports      | managed in Cloudflare          |
| Tailscale         | Private access to the server and home network from anywhere | managed in Tailscale         |
| socket-proxy      | Read-only Docker access for Homepage's status dots        | internal only                  |

This stack is independent of your other stacks. It doesn't change them and
doesn't share a Docker network with them.

## How access works

```
                     Internet
                        │
        ┌───────────────┴────────────────┐
        │                                │
 Cloudflare Tunnel                   Tailscale
 (selected apps, browser,            (family devices,
  behind Cloudflare Access)           everything else)
        │                                │
        └──────────────┬─────────────────┘
                       │
                  Home server ── AdGuard Home = DNS for the whole house
                       │
        other stacks: media, photos, ... (their own repos)
```

- **At home:** open apps on the server's IP or `server.home`. Nothing needs a
  proxy.
- **Cloudflare Tunnel:** only for apps you choose, such as Seerr or Mealie.
  Family members log in through Cloudflare Access first.
- **Tailscale:** for everything that shouldn't or can't go through Cloudflare,
  such as Jellyfin (video streaming isn't allowed on Cloudflare's free plan),
  Immich (uploads over 100 MB fail through the tunnel) and admin pages.

## Files

```
.
├── .env.example        # template with all settings, committed to git
├── .env                # your settings and secrets (created by setup.sh, not committed)
├── docker-compose.yml  # service definitions, reads everything from .env
├── setup.sh            # install, start and update the stack
├── backup.sh           # back up and restore config/
├── homepage/           # Homepage templates, copied to config/homepage/
├── config/             # app settings and state (not committed)
└── backups/            # output of backup.sh (not committed)
```

## Requirements

- **A Linux server** (Debian or Ubuntu recommended) with a fixed LAN IP. Give
  it a DHCP reservation in your router.
- **Docker Engine with the Compose plugin.** On Debian/Ubuntu:

  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER   # log out and back in afterwards
  ```

- **For Cloudflare Tunnel:** a free Cloudflare account, with a domain whose DNS
  is managed by Cloudflare.
- **For Tailscale:** a Tailscale account.

Don't have the Cloudflare or Tailscale parts ready yet? Remove them from
`COMPOSE_PROFILES` in `.env` and start with just AdGuard Home and Homepage.

## Installation

1. **Clone the repository** on the server:

   ```bash
   git clone https://github.com/rnvegter/core-stack.git
   cd core-stack
   ```

2. **Prepare the secrets** (or skip these services for now, see step 3):
   - **Cloudflare tunnel token:** in the [Zero Trust dashboard](https://one.dash.cloudflare.com/)
     go to **Networks → Tunnels → Create a tunnel**, choose **Cloudflared**,
     name it (for example `home`), and copy the token from the install
     command shown (the long string after `--token`).
   - **Tailscale auth key:** in the [admin console](https://login.tailscale.com/admin/settings/keys)
     go to **Settings → Keys → Generate auth key**. New to Tailscale? Follow
     the step-by-step guide in [4. Tailscale](#4-tailscale).

3. **Run the setup script:**

   ```bash
   ./setup.sh --no-start
   ```

   This creates `.env` (readable only by you). Paste the token and key into
   `CLOUDFLARE_TUNNEL_TOKEN` and `TS_AUTHKEY`, or remove `tunnel` and/or
   `tailscale` from `COMPOSE_PROFILES`. Then run:

   ```bash
   ./setup.sh
   ```

   The script:
   - checks Docker and Compose
   - suggests `PUID`/`PGID`, `SERVER_IP` and `LAN_SUBNET` from your system
     and asks before changing them
   - checks that the enabled services have their token/key
   - **frees port 53** if Ubuntu's `systemd-resolved` holds it (asks first,
     uses sudo). The server itself keeps using your router's DNS.
   - **enables IP forwarding** for Tailscale subnet routing (asks first, uses
     sudo)
   - creates the folders and the Homepage config, pulls the images and starts
     the stack

   Every question has a safe default when no terminal is attached: nothing is
   changed without your answer.

4. **Store `.env` in your password manager** (for example as a secure note in
   Proton Pass). It holds the tunnel token, and backups don't include it.

## First-time configuration

### 1. AdGuard Home

1. Open `http://<server-ip>:3000` for the first-run wizard.
2. **Admin web interface:** listen on **All interfaces**, keep the default
   port **80**. That's the port *inside* the container; the stack publishes
   it on the server as `ADGUARD_WEB_PORT` (8053).
3. **DNS server:** **All interfaces**, port **53**.
4. Create the admin account and finish. The wizard then sends your browser
   to port 80 on the server, which is **Homepage**, not AdGuard. That's
   expected: open `http://<server-ip>:8053` instead. That's where the admin
   page lives from now on.
5. **Settings → DNS settings → Upstream DNS servers:** pick encrypted
   upstreams, for example:

   ```
   https://dns.quad9.net/dns-query
   https://cloudflare-dns.com/dns-query
   ```

   Select **Parallel requests** for speed.
6. **Filters → DNS blocklists:** the default AdGuard list is a good start. Add
   more from **Add blocklist → Choose from the list** if you want stricter
   blocking.
7. **Filters → DNS rewrites → Add:** `server.home` → your `SERVER_IP`. Every
   device can then open `http://server.home`.
8. **Make it the DNS for the house:** in your router's DHCP settings, set the
   DNS server to `SERVER_IP`. Devices pick it up when they renew their lease
   (or reconnect to Wi-Fi).

> **If the server is down, the house has no DNS.** Many routers let you set a
> second DNS server. If you set a public one there, the internet keeps working
> when the server is down, but some devices will use it now and then and skip
> ad blocking. Choose what matters more to your household.

Optional: **Settings → Client settings** lets you give devices their own rules,
for example stricter filtering or safe search on the kids' devices.

### 2. Homepage

Open `http://server.home` (or `http://<server-ip>`). The tiles come from
`config/homepage/services.yaml`. It's pre-filled with the apps from the media
stack. Edit the file to add or remove apps; Homepage picks up changes
automatically, just reload the page.

- A tile shows a **status dot** when it has `server: docker` and the right
  `container:` name. This works for containers of all stacks on this server.
- Icons come from [dashboard-icons](https://github.com/homarr-labs/dashboard-icons):
  use the app name, for example `immich.png`.
- Other files in `config/homepage/`: `settings.yaml` (title, theme, layout),
  `widgets.yaml` (CPU, memory, disk, clock, search), `bookmarks.yaml`.

Did you set up `server.home` in AdGuard Home or change the IP? Homepage only
answers on the names in `HOMEPAGE_ALLOWED_HOSTS` (built from `SERVER_NAME` and
`SERVER_IP` in `.env`). Run `docker compose up -d` after changing them.

### 3. Cloudflare Tunnel

The tunnel runs as soon as the token is in `.env`. You manage which apps are
reachable in the Cloudflare dashboard, not in this repo.

**Expose an app:**

1. Zero Trust dashboard → **Networks → Tunnels → your tunnel → Public
   hostname → Add a public hostname**.
2. Subdomain and domain, for example `requests` + `yourdomain.nl`.
3. Service: type **HTTP**, URL `host.docker.internal:<port>`, for example
   `host.docker.internal:5055` for Seerr.

`host.docker.internal` is this server, so any app on it is reachable
through its published port, whichever stack it's in.

**Protect it with Cloudflare Access** (free for up to 50 users):

1. Zero Trust → **Access → Applications → Add an application →
   Self-hosted**.
2. Application domain: the hostname from above.
3. Policy: **Allow**, include **Emails** with the family's email addresses.
4. Login method: **One-time PIN** (a code by email) works for everyone
   without extra accounts. You can add Google login under **Settings →
   Authentication**.

Family members now log in with a code from their mailbox before they see the
app.

**Which apps to expose:**

| Route | Apps |
|---|---|
| Tunnel + Access (browser apps) | Seerr, Mealie, Grocy, Paperless-ngx, Actual Budget, Homepage |
| Tunnel, app's own login + 2FA (mobile apps can't pass the Access login) | Home Assistant |
| **Tailscale only** | Jellyfin (video isn't allowed through Cloudflare), Immich and Nextcloud (100 MB upload limit), Audiobookshelf |
| **Never exposed** | Download apps, AdGuard Home, Dozzle, Uptime Kuma, Docker admin tools |

### 4. Tailscale

#### What Tailscale does

Tailscale builds a **private network** (a "tailnet") between your own devices:
the server, your phone, your laptop. Each device gets an extra IP address
(`100.x.y.z`) that works from anywhere, at home or away, without opening ports
on your router.

You manage that network on Tailscale's website, the **admin console** at
https://login.tailscale.com/admin. **There is no admin page on the server
itself**: the Tailscale container is simply one of the devices in your
network, which is why the stack publishes no port for it.

```
Your phone (Tailscale app) ──┐
Your laptop (Tailscale app) ─┼── your private Tailscale network ── server (container)
Family phones ───────────────┘
```

#### Step 1: Create an account

1. Go to https://login.tailscale.com and sign in with Google, Microsoft, Apple
   or GitHub. This account becomes the owner of your network.
2. Tailscale asks you to add a first device. You can skip that for now.

#### Step 2: Create a key for the server

The server has no screen to log in with, so you give it a key once.

1. In the admin console: **Settings → Keys → Generate auth key**.
2. Leave the defaults and click **Generate key**.
3. Copy the key (starts with `tskey-auth-`). It's shown only once.

#### Step 3: Give the key to the server

On the server, in the `core-stack` folder:

```bash
nano .env
```

Find these lines and fill them in:

```
COMPOSE_PROFILES=tunnel,tailscale
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxx
```

- `COMPOSE_PROFILES` must contain `tailscale`. If you don't use Cloudflare yet,
  write `COMPOSE_PROFILES=tailscale`.
- Save with **Ctrl+O**, **Enter**, then close with **Ctrl+X**.

Then start it:

```bash
docker compose up -d
```

#### Step 4: Check that the server is connected

```bash
docker exec tailscale tailscale status
```

The first line should show `home-server` (the value of `TS_HOSTNAME`) with a
`100.x.y.z` address. The server also appears in the admin console under
**Machines**.

Doesn't work? Check the logs:

```bash
docker compose logs --tail 30 tailscale
```

#### Step 5: Two settings in the admin console

Under **Machines**, click the **⋯** next to `home-server`:

1. **Disable key expiry.** Otherwise the server gets logged out after 180
   days.
2. **Edit route settings** → tick the subnet route (your `LAN_SUBNET`, for
   example `192.168.2.0/24`) → **Save**. Your phone can then reach
   *everything* at home through Tailscale, not just the server.

After this, you can empty `TS_AUTHKEY=` in `.env`. The server remembers its
login in `config/tailscale/`.

#### Step 6: Install the app on your phone

1. Install **Tailscale** from the App Store or Play Store.
2. Sign in with **the same account** as in step 1.
3. Switch the connection on.

#### Step 7: Test it

Turn off Wi-Fi on your phone so you're on mobile data. Open in the browser:

- `http://<server-lan-ip>:8053`: the AdGuard admin page (works thanks to the
  subnet route from step 5)
- or `http://100.x.y.z:8053`: the same page via the server's Tailscale
  address

If AdGuard loads over mobile data, Tailscale works.

#### Later (optional)

- **Ad blocking on your phone while away:** admin console → **DNS → Add
  nameserver → Custom** → the server's `100.x.y.z` address → turn on
  **Override local DNS**. Every device on Tailscale then uses AdGuard Home,
  also away from home.
- **Family members:** install the app, then invite them via **Users → Invite
  users**, or share only the server with their own free Tailscale accounts
  (**Machines → ⋯ → Share**). Check the current plan limits: the free Personal
  plan covers a limited number of users.
- **Exit node:** set `TS_EXTRA_ARGS=--advertise-exit-node` in `.env`, run
  `docker compose up -d`, and approve it in the admin console. Devices can
  then send all their traffic through home, for example on public Wi-Fi.
- **Web interface for the server:** Tailscale has an optional page to view
  and change the server's Tailscale settings. Enable it once (it survives
  restarts):

  ```bash
  docker exec tailscale tailscale set --webclient
  ```

  Then open `http://100.x.y.z:5252` from a device on your tailnet. It's only
  reachable through Tailscale, not from the home network, and it's read-only
  until you sign in with your Tailscale account.

## Backups

`backup.sh` saves the `config/` folder (AdGuard Home settings and filters,
Homepage config, Tailscale login) to a dated archive in `backups/`. On Linux
it needs **sudo**, because AdGuard Home and Tailscale store their files as root.

```bash
sudo ./backup.sh                  # make a backup (stops the stack for a few seconds)
sudo ./backup.sh --list           # list backups
sudo ./backup.sh --restore FILE   # restore one
```

- **Stopping briefly** makes sure nothing is half-written. It also means DNS
  is gone for those seconds, so schedule it at night. Use `--no-stop` to skip
  stopping.
- **Retention:** only the newest `BACKUP_KEEP` backups (default 7) are kept.
- **Private:** backups contain the Tailscale identity of the server. They're
  created readable by root only.
- **`.env` isn't included.** Keep it in your password manager.
- **Restore** asks for confirmation, moves your current `config/` aside to
  `config.before-restore-<date>`, unpacks the backup and starts the stack.

**Nightly backups:** add to root's crontab with `sudo crontab -e`:

```
30 3 * * * cd /path/to/core-stack && ./backup.sh >> backups/backup.log 2>&1
```

Copy `backups/` to another machine or offsite storage now and then, so a disk
failure doesn't take your backups with it.

## Updating the stack

Make a backup first:

```bash
sudo ./backup.sh
```

**Update the containers (new image versions):**

```bash
./setup.sh --update
```

This pulls the latest images, recreates only the changed containers and
removes old images. By hand:

```bash
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
```

**Update this repository:**

```bash
git pull
./setup.sh --update
```

New settings from `.env.example` are added to your `.env` automatically;
existing values stay. Your Homepage config in `config/homepage/` is never
overwritten. Compare it with the templates in `homepage/` if you want new
defaults.

**Pin or roll back a version:** every image has a tag in `.env`
(`ADGUARD_TAG`, `HOMEPAGE_TAG`, `CLOUDFLARED_TAG`, `TAILSCALE_TAG`,
`SOCKET_PROXY_TAG`). Set it to a specific version instead of `latest`, run
`docker compose up -d`, and restore your pre-update backup if needed.

## Everyday commands

```bash
docker compose ps                  # status
docker compose logs -f cloudflared # follow logs of one service
docker compose restart homepage    # restart one service
docker compose down                # stop everything (config is kept)
```

## Security notes

- **Never expose** AdGuard Home's admin page, the socket proxy or Docker admin
  tools through the tunnel.
- `.env` is created with permissions `600`. Keep it that way: the tunnel token
  lets anyone run your tunnel.
- The socket proxy only allows **reading** container information. Homepage
  can't start, stop or change containers.
- Anyone on your home network can open Homepage and see which apps exist. The
  apps themselves still need their own login.

## Troubleshooting

- **AdGuard's admin page gives "unable to connect" on port 8053:** AdGuard
  must listen on port 80 inside the container. Check with
  `docker compose logs adguardhome | grep "plain server"`: it should say
  `addr=0.0.0.0:80`. If it shows another port (because a different port was
  chosen in the wizard), set it back to 80 in AdGuard's config file (as root,
  because AdGuard owns it):

  ```bash
  docker compose stop adguardhome
  sudo sed -i 's/^\([[:space:]]*address: 0\.0\.0\.0:\)[0-9]*$/\180/' config/adguardhome/conf/AdGuardHome.yaml
  docker compose up -d adguardhome
  ```
- **`setup.sh` says port 53 is in use:** another DNS server runs on the
  host. For Ubuntu's `systemd-resolved` the script offers the fix. For
  others (for example `dnsmasq`), stop that service, or set `DNS_BIND_IP` to
  the server's LAN IP in `.env`.
- **Homepage shows "Host validation failed":** you opened it on a name or IP
  that isn't in `SERVER_NAME`/`SERVER_IP`. Fix `.env`, then run
  `docker compose up -d homepage`.
- **Homepage has no status dots:** the container name in `services.yaml`
  doesn't match `docker ps`, or the socket proxy isn't running
  (`docker compose ps socket-proxy`).
- **Cloudflare shows error 502 or 1033:** the tunnel runs but can't reach the
  app. Check the port, and that the app is running. If `host.docker.internal`
  doesn't work on your system, use the server's LAN IP instead.
- **Tailscale devices reach the server but not other devices at home:**
  approve the subnet route in the admin console, and check that IP forwarding
  is on: `sysctl net.ipv4.ip_forward` should say `1`.
- **Devices don't use AdGuard Home:** check the DNS server your router hands
  out, and reconnect the device. Some devices and browsers use their own DNS
  (for example "Secure DNS" in Chrome, or Private Relay on Apple devices), which
  bypasses AdGuard Home.
- **Permission denied from Docker:** your user isn't in the `docker` group.
  Run `sudo usermod -aG docker $USER` and log in again.
