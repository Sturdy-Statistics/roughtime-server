# RoughTime UDP Server (Clojure)

This repository implements a RoughTime server in Clojure.

The server uses the [Sturdy Statistics](https://github.com/Sturdy-Statistics/roughtime-protocol) implementation of the [roughtime protocol](https://datatracker.ietf.org/doc/html/draft-ietf-ntp-roughtime-15).
The server itself is built using `core.async` to batch responses.

## Architecture Overview

The server is structured as a linear pipeline:

```
UDP socket
   ↓
request-channel (sliding-buffer)
   ↓
batcher
   ↓
batch-channel
   ↓
workers (pipeline-blocking)
   ↓
response-channel
   ↓
sender
   ↓
UDP socket
```

Each stage has a single responsibility:

| Stage      | Responsibility                               |
|------------|----------------------------------------------|
| UDP server | Read incoming datagrams and enqueue requests |
| Batcher    | Form batches to amortize crypto cost         |
| Workers    | Generate RoughTime responses (CPU-bound)     |
| Sender     | Send responses back via UDP                  |

The server manages thread lifecycle passively via channel closure, rather than needing explicit stop signals.

## Design Principles

### 1. Bounded Everywhere

All queues are bounded:

- Kernel socket receive buffer (`SO_RCVBUF`)
- `request-channel`
- `batch-channel`
- `response-channel`

This should ensure that the server drops requests under load rather than crashing.

### 2. Drop at the Edge

When overloaded:

- The request channel may drop requests (using `sliding-buffer`), and
- The kernel socket buffer may drop packets

### 3. Batching

RoughTime responses have a large fixed cost (~30 μs) and a small per-request cost (~4 μs).

The batcher groups requests until either:

- `max-batch` is reached, or
- `flush-ms` elapses

This improves throughput while bounding latency.
The commandline args `max-batch-size` and `flush-ms` allow you to customize these values.

### 4. CPU Isolation

CPU-intensive work runs in a dedicated worker pool using:

```clj
core.async/pipeline-blocking
```

The commandline arg `num-workers` allows you to customize the number of workers in the pool.

### 5. Graceful Shutdown via Channel Closure

Shutdown flows naturally downstream:

1. UDP socket is closed
2. `request-channel` closes
3. Batcher flushes and closes `batch-channel`
4. Workers drain and close `response-channel`
5. Sender drains and exits


---

## Running the Server

The RoughTime server requires cryptographic secrets to run.
These include the server’s long-term key material used to sign certificates.

### Generating secrets

Generate the required secrets with:

```bash
clojure -X:local-deps:make-secrets
```

This command will print a **public key** to stdout.
Save this value — clients need it to validate server responses.

By default, `make-secrets` writes secrets to a local directory named `secrets/`.

> ⚠️ This default is convenient for development, but not compatible with running the server from an uberjar.

To write secrets to a different location, run:

```bash
clojure -X:local-deps:make-secrets :secrets-dir '"path/to/secrets"'
```

Note the double quoting: this is required so the shell passes a string that Clojure can read as EDN.

### Running the server directly

To run the server from source:

```bash
clj -M:run \
  :secrets-dir path/to/secrets \
  :log-path path/to/logs/roughtime.log
```

### Building and running an uberjar

To build a self-contained uberjar:

```bash
clj -T:build uber
```

Then launch the server with:

```bash
java -jar target/roughtime-server-v0.1.1-standalone.jar \
  :secrets-dir /path/to/secrets \
  :log-path /path/to/logs/roughtime.log
```

### Verifying operation

By default, the server listens on:

```
127.0.0.1:2002
```

Once running, it should respond to valid RoughTime requests sent to that address.

### Deployment notes

For deployment on EC2, see **`DEPLOY.md`**, which documents a mostly automated setup that:

- Seals secrets using **TPM-backed encryption**
- Runs the server bound to **loopback only**
- Uses a **strict systemd sandbox**
- Proxies network traffic via **nginx**

This setup is designed to minimize attack surface while keeping the RoughTime service externally accessible.

## License

Apache License 2.0

Copyright © Sturdy Statistics


<!-- Local Variables: -->
<!-- fill-column: 1000000 -->
<!-- End: -->
