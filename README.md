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

## Quick Start

1. **Run the server**

This uses ad hoc keys and is NOT secure for production use.
```bash
clj -M:run
```

When the server starts up, watch the log.
It will print the base64 public key, which you need to make requests.

2. **Query it** (in a separate terminal):

Once the server is running, you can test it on a different machine using a RoughTime client.
If you use [ours](https://github.com/Sturdy-Statistics/roughtime-client), you can run:

```
clj -M:run :address "127.0.0.1:2002" :protocol "udp" :public-key "<YOUR-KEY-B64>" :version-no "0x8000000c"
```

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

## Performance Notes

Above about 20,000 requests/sec the server will begin load shedding.
Below are average times in microseconds per response spent in each phase of the pipeline (sampled at 25,000 requests/sec on an M2 MacBook Air):

```clj
;; 2 workers; batch of 512 → communication bound, snd-queue backs up
{;; compute time in μs, per request
 :receive-and-queue    0.5
 :batch               12.5
 :respond             11.8
 :send                 5.3

 ;; queue wait time in μs
 :rcv-queue           27.9 ;; single req
 :worker-queue        54.3 ;; batch of 512
 :snd-queue          370.0 ;; batch of 512
 }
```


```clj
;; 1 worker; batch of 64 → CPU-bound
{ ;; compute time in μs, per request
 :receive-and-queue  0.5
 :batch             11.9
 :respond           10.6
 :send               4.4

 ;; queue wait time in μs
 :rcv-queue         20.8 ;; single req
 :worker-queue      54.0 ;; batch of 64
 :snd-queue         64.2 ;; batch of 64
 }
```

### Analysis

In both cases, the total compute time of ~30 μs per response implies a max throughput of ~30k req/sec.

The `:respond` phase involves parsing requests and assembling responses which include Ed25519 signatures.
This is by far the most CPU-intensive step; however, at ~12 μs, it is not the primary bottleneck.
In theory, with 4 cores the workers could respond to >300k req/sec; however, the batcher and sender would become bottlenecks.
A high performance server would need to speed up these steps.

### Load Shedding & Back-pressure

The server manages over-capacity through a combination of blocking and load-shedding:
1. **Back-pressure:** When the sender cannot keep up, the `response-channel` fills, blocking the Workers.  This propagates back to the Batcher.
2. **Load Shedding:** The `request-channel` uses a **sliding buffer**.  Once the downstream stages are blocked and the buffer is full, the server shed loads by dropping the oldest uncalculated requests, ensuring the server remains responsive and processes the most recent traffic possible.

---

## Running the Server

### Running the server directly

To run the server from source:

```bash
clj -M:run
```

This will generate ad-hoc cryptographic secrets and run, but it is NOT secure.
To deploy the server, use the makefile described in DEPLOY.md.

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
