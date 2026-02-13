# Deploying the Sturdy Statistics Roughtime Server

This guide covers deploying the server to an Amazon Linux 2023 instance.
It *may* work on other RHEL-based instances, but this has not been tested.

## 🛡️ Security Architecture: Sturdy Statistics Roughtime Server

This deployment is engineered for both simplicity and security.
We use **TPM 2.0 Hardware Sealing** and **Systemd Sandboxing** to  minimize the "blast radius" of any potential vulnerability.

| Feature               | Protection  Mechanism                                                                                   |
|-----------------------|---------------------------------------------------------------------------------------------------------|
| **Hardware Sealing**  | Private keys are encrypted via **TPM 2.0** and only decrypt if the server's boot state is untampered.   |
|                       | (a backup "break-glass" key is also generated for data recovery in the event of hardware failure.)      |
| **Strict Sandboxing** | The entire filesystem is mounted **Read-Only** (`ProtectSystem=strict`), except for the logs directory. |
| **Kernel Hardening**  | System calls are restricted (`SystemCallFilter`), and kernel tunables are locked to prevent elevation.  |
| **Network Isolation** | The app is restricted to local loopback and only permitted to bind to **UDP port 12002**.               |
| **Zero-Privilege**    | Runs as a dedicated `roughtime` user with no ability to gain new privileges (`NoNewPrivileges`).        |
| **Invisible Process** | The server cannot see other system processes or user home directories.                                  |

Even if the application were compromised, it is physically prevented by the kernel from opening any network sockets except for UDP 12002.
It cannot "call home" or act as a botnet node because of the `SocketBindDeny=any` and `IPAddressDeny=any` directives

## ❗ Security Trade-offs

While this system offers a robust security posture, we have simplified our standard internal deployment process in two ways to make this server easier to run.
You should be aware of these trade-offs.

### 1. Supply Chain Integrity (On-Host Builds)

This guide uses an **on-host build process**: the server pulls code via `git` and builds the artifact locally using Clojure.

* **Our Internal Standard:** We build artifacts offline in a secure environment, sign the Uberjar with a GPG key, and deploy to a private S3 bucket.
The host verifies the signature before starting the application, guaranteeing strict supply chain integrity.
* **The Trade-off:** We chose the `git` method for this public release to simplify the setup for new users.
This means you rely on the security of your GitHub connection and the integrity of the checkout rather than a cryptographic signature on the artifact itself.
It also means the host server is capable of modifying the application.

### 2. Key Isolation (Memory Hygiene)

The RoughTime protocol relies on a **long-term private key** to mint weekly delegation certificates.
Ideally, this key should never be loaded into the memory of a network-facing process.

* **The Risk:** This implementation decrypts and loads private key into the main server process.
  Because `java.security.PrivateKey` objects are immutable, they cannot be explicitly zeroed out in memory.
  They remain on the heap until garbage collected, theoretically exposing them to a memory-dump attack if the process were compromised.
* **The Ideal Design:** A more secure design would run rotations in a separate, one-shot `systemd` unit isolated from the network.
  The main server would never touch the long-term key, only receiving the short-term delegation certificates.
* **The Trade-off:** We combined these functions into a single service to avoid the complexity of maintaining multiple codebases and coordinated service units.

**Why this is reasonable:**
We believe this trade-off is acceptable for a public node because:

1. **Hardening:** The strict `systemd` sandbox and `NoNewPrivileges` flag make a memory-dump attack unlikely.
2. **Network Isolation:** Even if a key were accessed, the `IPAddressDeny=any` directive makes exfiltration difficult.
3. **Ecosystem Health:** The best protection against a leaked key is **server diversity**.
By simplifying the deployment, we encourage more independent nodes to join the network, which improves the security of the RoughTime ecosystem as a whole.

## 1. Initial Server Setup

Log into your remote server and ensure make is installed.

```bash
sudo dnf install -y make git
```

```bash
git clone https://github.com/Sturdy-Statistics/roughtime-server.git
```

> ⚠️ NOTE: All of the following commands run from inside `~/roughtime-server`

This will install Java, the Clojure CLI, and Nginx.
It will also create an unprivileged user to run the server and create some necessary directories.

```bash
make -f bootstrap.mk setup
```

## 2. Configure Nginx (UDP Proxy)

Roughtime operates over UDP.
Standard Nginx configurations are usually set up for HTTP (TCP).
We need to ensure a `stream` block exists.

### Step A: Run the Nginx Bootstrap

Try running the Nginx configuration script first:

```bash
make -f bootstrap.mk nginx
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
sudo make -f bootstrap.mk nginx
```

This installs a UDP forwarding rule (`conf/nginx-roughtime.conf`) into `/etc/nginx/stream.conf.d/` and reloads Nginx.

## 3. Firewall Configuration

Ensure your cloud provider's firewall (e.g., AWS Security Group) allows incoming traffic on:

* **Port 2002 (UDP)**: The Roughtime protocol port.

## 4. Secrets Management (TPM-Sealed)

The server requires a set of cryptographic keys to sign its certificates.
To protect these keys at rest, we use systemd-creds to seal them against the hardware's TPM 2.0.

### Step A: Provision Secrets

Run the provision target to generate the secrets, encrypt them, and install them into `/etc/roughtime/`.

```bash
make -f bootstrap.mk secrets
```

When the following prompt appears
```
⚠️ Please enter the Admin Backup Password:
```
enter a password at the prompt.
This password is used to encrypt a backup key; you will need this in the event of a hardware failure which prevents the TPM secret from decrypting.

What this does:

1. Generates `password.bytes` (private key) which acts as a server password.
2. Encrypts `password.bytes` using your CPU's TPM chip and installs the encrypted `.cred` file to `/etc/roughtime/` with `0400` root-only permissions.
3. Generates an asymmetric “backup keypair” for data recovery.  The server will encrypt data using both its TPM-sealed password and using the backup public key.

### Step B: Backup and Cleanup

The plaintext secrets are temporarily stored in `/dev/shm/roughtime-secrets`.
1. **Backup:** Copy this directory to a secure, offline location (e.g., an encrypted vault). If the EC2 instance is terminated, you will need these to recreate the sealed credentials on a new instance.
2. **Shred:** Once backed up, securely delete the local plaintext copies:

```bash
make -f secrets.mk clean-secrets
```

> **Note:** The server uses `LoadCredentialEncrypted`.
> Systemd handles the decryption at startup and places the plaintext keys in a secure, temporary RAM-disk specified by `${CREDENTIALS_DIRECTORY}`.
> This ensures private keys never touch the physical disk in plaintext.

### Troubleshooting: "Verification Failed"

If you update your system kernel or bootloader, the PCR (Platform Configuration Register) values may change, causing the TPM to refuse to release the secrets.

To check if your secrets are still accessible, run:

```bash
make -f bootstrap.mk verify-secrets
```

If verification fails, you will need to restore your plaintext backups to `/dev/shm/roughtime-secrets` and run `make FORCE=1 overwrite-secrets` again to re-seal them against the new system state.

## 5. Deploy and Manage the Service

The deployment process uses a dedicated system user (`roughtime`) and a release-management directory structure to keep your production environment clean.

### Initial Deploy

To perform the first build and start:

```bash
make -f server.mk server
```

This performs:
1. Repository update (`git pull`)
2. Uberjar build (`clojure -T:build uber`)
3. Artifact staging to `/opt/roughtime/roughtime-server/releases/`
4. Systemd unit installation and enablement
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

### Rollback to a Specific Version

If you need to go further back (e.g., the 3rd newest version):

```
make -f server.mk rollback-n N=3
```

To "undo" a rollback, reset to the newest:

```
make -f server.mk rollback-n N=1
```

## 8. Maintenance & Logs

Standard `systemd` commands are wrapped for convenience:

* View Status: `make -f server.mk server-status`

* Tail Logs: `make -f server.mk server-logs`

## 9. after changing the unit definition `roughtime.service`

If you choose to modify the service definition file, you must re-install it and restart the service as follows:

```
make -f server.mk server-install
make -f server.mk server-restart
```

<!-- Local Variables: -->
<!-- fill-column: 100000 -->
<!-- End: -->
