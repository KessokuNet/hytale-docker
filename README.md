# Hytale Dedicated Server - OCI Image

This repository contains a Containerfile and scripts to run a dedicated Hytale server
using Docker or any OCI-compatible container runtime.

## Usage

To run the Hytale server, use the following command:

```bash
docker run -itd \
  --name hytale-server \
  -e HYTALE_PATCHLINE=release \ # or specify a version number
  -e EXTRA_JVM_ARGS="-Xmx4G -Xms4G" \
  -p 5520:5520/udp \
  -v /path/to/data:/data \
  ghcr.io/kessokunet/hytale-docker:latest
```

... Or refer to the provided `docker-compose.yml` for an example using Docker Compose.

Make sure to replace `/path/to/data` with the actual path on your host where you want to store
stateful data. Without this volume mount, all server data will be lost when the container is removed.

## First Run Authentication

On the first run, the container will prompt you to authenticate with your Hytale account.
The server will output a device code and URL. Visit the URL on another machine and enter the code.
The container will poll until authentication completes, then download the game binaries.

Credentials are stored in `/data/credentials.json` and persisted across container restarts.

This is required for downloading the game binaries, but once downloaded, the server can run
without authentication.

To set up authentication on the actual server itself, Start authentication inside the server console itself using:

```
auth login device
```

Then follow the same process as above.

## Server Console Access

You can access the server console in two ways:

### 1. Docker Attach (Local Access)

```bash
# Attach to the running container (Ctrl+P, Ctrl+Q to detach without stopping)
docker attach hytale-server

# Or if using docker-compose
docker-compose attach hytale
```

### 2. Netcat (Remote Access)

The server console is also exposed via raw TCP on port 5521 (configurable via `CONSOLE_PORT`):

```bash
nc <server-ip> 5521
```

**Note:** Use `nc` (netcat) instead of `telnet`. Telnet sends protocol negotiation commands that interfere with the console. Netcat provides a clean, raw TCP connection.

Multiple clients can connect simultaneously to the console.

## Ports

- `5520/udp` - Game server (configurable via `HYTALE_BIND`)
  - This is the main game port where players connect
- `5521/tcp` - Console TCP port (configurable via `CONSOLE_PORT`)
  - Remote console access for server administration (use `nc`, not `telnet`)

> [!NOTE]
> The console port has no authentication or encryption whatsoever, and is exposed in plaintext TCP. Use caution when exposing this port to untrusted networks. Consider exposing it only on a private network or via a VPN.
>
> The console is provided for convenience and should not be considered secure, for production use, consider not exposing this port after initial setup after you give yourself operator access via the console.

## Environment Variables

The following environment variables can be used to configure the server:

### Server Configuration

- `HYTALE_PATCHLINE` - Server patchline to use (default: `release`)
- `HYTALE_DATA_DIR` - Directory for server state and save data (default: `/data/state`)
- `HYTALE_BIND` - Server bind address and port (default: `0.0.0.0:5520`)
- `HYTALE_UNIVERSE` - Path to universe/world data (default: `${HYTALE_DATA_DIR}/universe`)
- `HYTALE_AUTH_MODE` - Authentication mode (default: `authenticated`)
- `HYTALE_TRANSPORT` - Network transport protocol (default: `QUIC`)

### Backup Configuration

- `HYTALE_BACKUP_FREQUENCY` - Backup frequency in minutes (default: `30`)
- `HYTALE_BACKUP_MAX_COUNT` - Maximum number of backups to keep (default: unset)

### Boot Commands

- `HYTALE_PERSIST_AUTH` - Enable persistent authentication (default: `true`)
- `HYTALE_BOOT_CMDS` - Semicolon-delimited list of additional boot commands (default: empty)
  - Example: `HYTALE_BOOT_CMDS="command1;command2;another command"`

### JVM Configuration

- `EXTRA_JVM_ARGS` - Additional JVM arguments (default: empty)
  - Example: `EXTRA_JVM_ARGS="-Xmx4G -Xms4G"`
- `HYTALE_EXTRA_ARGS` - Additional arguments passed to the Hytale server (default: empty)

### Console Access

- `CONSOLE_PORT` - Port for the console TCP server (default: `5521`)
  - Use with `nc` (netcat), not telnet

## License

This software is under the Unlicense. See the [LICENSE](LICENSE) file for details.
This is free and unencumbered software released into the public domain.
Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.
