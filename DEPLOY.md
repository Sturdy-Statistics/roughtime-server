# Deploying the Sturdy Statistics Roughtime Server

This guide covers deploying the server to an Amazon Linux 2023 instance.
It *may* work on other RHEL-based instances, but this has not been tested.

## 🛡️ Security Architecture: Sturdy Statistics Roughtime Server

This deployment is engineered for both simplicity and security.
We use **TPM 2.0 Hardware Sealing** and **Systemd Sandboxing** to  minimize the "blast radius" of any potential vulnerability.

| Feature               | Protection  Mechanism                                                                                   |
|-----------------------|---------------------------------------------------------------------------------------------------------|
| **Hardware Sealing**  | Private keys are encrypted via **TPM 2.0** and only decrypt if the server's boot state is untampered.   |
| **Strict Sandboxing** | The entire filesystem is mounted **Read-Only** (`ProtectSystem=strict`), except for the logs directory. |
| **Kernel Hardening**  | System calls are restricted (`SystemCallFilter`), and kernel tunables are locked to prevent elevation.  |
| **Network Isolation** | The app is restricted to local loopback and only permitted to bind to **UDP port 2002**.                |
| **Zero-Privilege**    | Runs as a dedicated `roughtime` user with no ability to gain new privileges (`NoNewPrivileges`).        |
| **Invisible Process** | The server cannot see other system processes or user home directories.                                  |

Even if the application were compromised, it is physically prevented by the kernel from opening any network sockets except for UDP 2002. 
It cannot "call home" or act as a botnet node because of the `SocketBindDeny=any` and `IPAddressDeny=any` directives

## 1. Initial Server Setup

Log into your remote server and ensure make is installed.

```bash
sudo dnf install -y make
```

Download the bootstrap Makefile and run the setup.
This will install Java 17, the Clojure CLI, Nginx, and clone this repository into `~/roughtime-server`.

```bash
# Get the bootstrap file
curl -O https://raw.githubusercontent.com/Sturdy-Statistics/roughtime-server/main/bootstrap.mk

# Run the bootstrap
make -f bootstrap.mk bootstrap
```

## 2. Configure Nginx (UDP Proxy)

Roughtime operates over UDP.
Standard Nginx configurations are usually set up for HTTP (TCP).
We need to ensure a `stream` block exists.

### Step A: Run the Nginx Bootstrap

Try running the Nginx configuration script first:

```bash
cd ~/roughtime-server
sudo make -f nginx.mk nginx-bootstrap
```

### Step B: Manual Fix (If Required)

If the command above fails with an error about the `stream` context, you must manually edit `/etc/nginx/nginx.conf`.

Add this block at the **top level** of the file (outside the `http {}` block):

> ⚠️ NOTE: this requires manually editing the file!

`/etc/nginx/nginx.conf`
```conf
# At top level (outside http {})
stream {
    include /etc/nginx/stream.conf.d/*.conf;
}
```

After saving, re-run the bootstrap to finalize the setup.

```
sudo make -f nginx.mk nginx-bootstrap
```

This installs a UDP forwarding rule (`roughtime.conf`) into `/etc/nginx/stream.conf.d/` and reloads Nginx.

## 3. Firewall Configuration

Ensure your cloud provider's firewall (e.g., AWS Security Group) allows incoming traffic on:

* **Port 2002 (UDP)**: The Roughtime protocol port.

## 4. Secrets Management (TPM-Sealed)

The server requires a set of cryptographic keys to sign its certificates.
To protect these keys at rest, we use systemd-creds to seal them against the hardware's TPM 2.0.

### Step A: Provision Secrets

Run the provision target to generate the Clojure secrets, encrypt them, and install them into `/etc/roughtime/`.

```bash
make -f secrets.mk provision
```

What this does:

1. Generates `longterm.prv.b64` (private key), `longterm.pub` (public key), and other credentials.
2. Encrypts each file using your CPU's TPM chip.
3. Installs the encrypted `.cred` files to `/etc/roughtime/` with `0400` root-only permissions.

### Step B: Secure the Public Key

The command will print your **Longterm Public Key** to the console.

> 🗝️ **Note:** You must save this key.
> Your Roughtime clients will need it to verify the signatures provided by your server.

### Step C: Backup and Cleanup

The plaintext secrets are temporarily stored in `roughtime-secrets/`.
1. **Backup:** Copy this directory to a secure, offline location (e.g., an encrypted vault). If the EC2 instance is terminated, you will need these to recreate the sealed credentials on a new instance.
2. **Shred:** Once backed up, securely delete the local plaintext copies:

```bash
make -f secrets.mk clean
```

> **Note:** The server uses `LoadCredentialEncrypted`.
> Systemd handles the decryption at startup and places the plaintext keys in a secure, temporary RAM-disk specified by `${CREDENTIALS_DIRECTORY}`.
> This ensures private keys never touch the physical disk in plaintext.

### Troubleshooting: "Verification Failed"

If you update your system kernel or bootloader, the PCR (Platform Configuration Register) values may change, causing the TPM to refuse to release the secrets.

To check if your secrets are still accessible, run:

```bash
make -f secrets.mk verify
```

If verification fails, you will need to restore your plaintext backups to the `roughtime-secrets` directory and run `make -f secrets.mk encrypt` again to re-seal them against the new system state.

## 5. Deply and Manage the Service

The deployment process uses a dedicated system user (`roughtime`) and a release-management directory structure to keep your production environment clean.

### Initial Deploy

To set up the service user, create the directory structure, and perform the first build and start:

```bash
make -f server.mk server
```

This performs:
1. Repository update (`git pull`)
2. Uberjar build (`clojure -T:build uber`)
3. Artifact staging to `/opt/roughtime/roughtime-server/releases/`
4. Systemd unit installation and enablemeant
5. Service start (`systemctl start roughtime`)

### Subsequent Updates

When you have pushed new code to your repository, use the `deploy` target to perform an update:

```bash
make -f server.mk deploy
```

This command will:
1. Pull the latest code.
2. Build a new Clojure Uberjar.
3. Promote the new jar to the `current-standalone.jar` symlink.
4. Conditionally restart the `systemd` service and tail the logs.

> **Note:** these commands tail the server logs.
> You can exit out with `^C`; this simply exits `journalctl` and does not stop the server.
> (You can stop the server using the `server-stop` target.)

## 6. Test the Server

Once the server is running, you can test it on a different machine using a RoughTime client.
If you use [ours](https://github.com/Sturdy-Statistics/roughtime-client), you can run:

```
clj -M:run :address "<YOUR-IP>:2002" :protocol "udp" :public-key "<YOUR-KEY-B64>" :version-no "0x8000000c"
```

Your server should support earlier versions as well, such as:

```
clj -M:run :address "<YOUR-IP>:2002" :protocol "udp" :public-key "<YOUR-KEY-B64>" :version-no "0x00"
```

## 7. Rollbacks

If a deployment introduces a bug, you can revert to the previous stable version in seconds.
Sturdy Statistics keeps the last 5 releases by default.

### List Available Releases

See what versions are currently archived on the server:

```bash
make -f server.mk releases
```

### Quick Rollback

To immediately revert to the version used *just before* the current one:

```
make -f server.mk rollback
```

*Note: Running this again will effectively "roll forward" back to the newer version.*

### Rollback to a Specific Version

If you need to go further back (e.g., the 3rd newest version):

```
make -f server.mk rollback-n N=3
```

alternatively, you can go to a specific release:

```
make rollback-to NAME=roughtime-server-v0.1.0-standalone.jar
```

## 8. Maintenance & Logs

Standard `systemd` commands are wrapped for convenience:

* View Status: `make -f server.mk server-status`

* Tail Logs: `make -f server.mk server-logs`

* Verify UDP Listener: `make -f server.mk server-verify` (Checks if port 2002 is active)


## 9. after changing the unit definition `roughtime.service`

If you choose to modify the service definition file, you must re-install it and restart the service as follows:

```
make -f server-install
make -f server-restart
```

<!-- Local Variables: -->
<!-- fill-column: 100000 -->
<!-- End: -->
