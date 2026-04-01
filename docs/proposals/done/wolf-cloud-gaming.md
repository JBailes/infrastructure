# Wolf Cloud Gaming Bootstrap Script

## Problem

There is no homelab bootstrap script for cloud gaming. Wolf (Games on Whales)
enables Moonlight-compatible game streaming from a shared server, but setting it
up requires: creating a Docker-capable LXC container, passing through GPU
devices, configuring the correct docker-compose.yml for the GPU vendor, and
setting up virtual input devices. This is error-prone to do manually.

## Approach

Create `homelab/bootstrap/10-setup-wolf.sh` that:

1. Creates a privileged Debian LXC via `lib/common.sh` (`create_lxc`), then
   installs Docker Engine and Docker Compose inside the container from Docker's
   official apt repository.

2. Detects the GPU vendor on the Proxmox host by inspecting
   `/sys/class/drm/renderD*/device/driver` and prompts the user to select which
   render device to use if multiple GPUs are present.

3. Configures GPU passthrough in the LXC container config based on the detected
   vendor:
   - **Intel/AMD**: Pass `/dev/dri` with cgroup rules for `226:*`
   - **NVIDIA**: Pass `/dev/nvidia*`, `/dev/dri` with cgroup rules for `195:*`
     and `226:*`; install NVIDIA Container Toolkit inside the container

4. Writes the appropriate `docker-compose.yml` for Wolf and Wolf Den based on
   the GPU vendor:
   - **Intel/AMD**: Standard compose with `/dev/dri`, `/dev/uinput`, `/dev/uhid`
   - **NVIDIA (manual driver volume)**: Compose with all nvidia device nodes,
     `NVIDIA_DRIVER_VOLUME_NAME`, and external driver volume; builds and creates
     the driver volume automatically

5. Deploys Wolf Den (`ghcr.io/games-on-whales/wolf-den:stable`) alongside Wolf
   in the same docker-compose.yml. Wolf Den is a web management UI on port 8080
   that connects to Wolf via its Unix socket (`/var/run/wolf/wolf.sock`).

6. Sets up virtual input udev rules for gamepad support.

7. Starts Wolf and Wolf Den via `docker compose up -d`.

### Script usage

```
10-setup-wolf.sh [OPTIONS]
  --ctid <id>        Container ID (default: 120)
  --cpu <cores>      CPU cores (default: 4)
  --ram <mb>         RAM in MB (default: 4096)
  --disk <gb>        Disk in GB (default: 16)
  --storage <name>   Proxmox storage name (default: local-lvm)
  --configure        (internal) Run inside the container
```

### Script structure

Follows the existing homelab bootstrap pattern:
- Without `--configure`: runs on the Proxmox host, creates the LXC container
  via the community script, detects GPU, configures GPU passthrough in the LXC
  config, then pushes and executes itself inside with `--configure`
- With `--configure`: runs inside the container, writes docker-compose.yml
  (Wolf + Wolf Den), sets up udev rules, pulls and starts services

### Container defaults

- **CTID**: 120 (overridable via `--ctid`)
- **Hostname**: wolf
- **IP**: DHCP (community script default)
- **Privileged**: Yes (required for GPU device passthrough)
- **Resources**: 4 CPU, 4096 MB RAM, 16 GB disk (all overridable)
- **Storage**: local-lvm (overridable via `--storage`)

### GPU detection and prompting

The script detects available render devices on the host:

```bash
for dev in /sys/class/drm/renderD*/device/driver; do
    driver=$(basename "$(readlink "$dev")")
    # driver will be: i915, amdgpu, or nvidia
done
```

If multiple render devices exist, the script lists them and prompts:

```
Available GPUs:
  1) /dev/dri/renderD128 (i915 - Intel)
  2) /dev/dri/renderD129 (amdgpu - AMD)

Select GPU for Wolf [1]:
```

The selected render device is passed to Wolf via `WOLF_RENDER_NODE`.

### Docker Compose layout

Wolf and Wolf Den run as two services in a single docker-compose.yml:

```yaml
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    # ... GPU-specific config ...
    volumes:
      - /etc/wolf:/etc/wolf
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - wolf-socket:/var/run/wolf
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    volumes:
      - wolf-socket:/var/run/wolf
      - /etc/wolf/wolf-den:/app/wolf-den
      - /etc/wolf/covers:/etc/wolf/covers
    ports:
      - "8080:8080"
    restart: unless-stopped

volumes:
  wolf-socket:
```

### Post-setup output

After deployment, the script prints:

```
Wolf:     streaming on ports 47984-48200
Wolf Den: http://<IP>:8080 (web management)
Moonlight pairing: check Wolf logs for PIN URL
```

## Affected files

- `homelab/bootstrap/10-setup-wolf.sh` (new)
- `homelab/bootstrap/README.md` (add section for Wolf)

## Trade-offs

- Privileged containers are less secure than unprivileged, but GPU passthrough
  in LXC reliably requires it.
- NVIDIA manual driver volume setup is used over the Container Toolkit approach
  because Wolf's documentation recommends it for stability. The driver volume
  must be recreated after host driver updates.
- The script does not install GPU drivers on the host. The host must already
  have working GPU drivers before running this script.
- Wolf Den runs on port 8080 which is accessible from the LAN. It shares a
  Docker named volume (`wolf-socket`) with Wolf for Unix socket communication.
