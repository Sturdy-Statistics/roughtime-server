(ns roughtime-server.server-udp
  (:require
   [clojure.core.async :as a]
   [roughtime-server.config :as config]
   [taoensso.telemere :as t])
  (:import
   (java.net InetSocketAddress)
   (java.nio ByteBuffer)
   (java.nio.channels DatagramChannel AsynchronousCloseException)
   (java.net StandardSocketOptions)))

(set! *warn-on-reflection* true)

(defn- read-request-packet
  "Read a UDP request and return as a byte[].  Drop requests larger than 2048 bytes."
  ^bytes [^ByteBuffer buf {:keys [min-size max-size]}]
  (.flip buf) ;; switch buf from write to read mode
  (let [n (.remaining buf)]
    ;; don't bother processing small or large requests
    (when (<= min-size n max-size)
      (let [ba (byte-array n)]
        (.get buf ba 0 n)
        ba))))

(defn- queue-next-request
  "Read next request.  If successful, put on the `request-channel`.  Puts a map with keys
     `:src` - InetSocketAddress
     `:request-bytes` - bytes
     `:received-ns` - long"
  [^DatagramChannel ch ^ByteBuffer buf request-channel opts]
  ;; prepare buf for writing
  (.clear buf)

  ;; blocking receive; returns the sender address
  (when-let [^InetSocketAddress src (.receive ch buf)] ; fill buffer
    (let [received-ns (System/nanoTime)]
     (when-let [request-packet (read-request-packet buf opts)]
       (let [msg {:src src
                  :request-bytes request-packet
                  :received-ns received-ns
                  :queued-ns (System/nanoTime)}]
         ;; place request on the queue
         (a/>!! request-channel msg))))))

(defn- run-server-loop!
  "Run a blocking UDP server loop on the given channel+buffer until the
  channel is closed."
  [^DatagramChannel ch ^ByteBuffer buf async-req-channel]
  (loop []
    (try
      ;; this runs a blocking receive; execution waits until a
      ;; packet arrives
      (queue-next-request ch buf async-req-channel {:min-size (config/min-msg-size)
                                                    :max-size (config/max-msg-size)})

      ;; channel was closed from another thread → exit loop
      (catch AsynchronousCloseException ex
        (throw ex))

      (catch Exception ex
        (t/log! {:level :error
                 :id ::respond
                 :error ex})))
    (when (.isOpen ch) (recur))))

(defn run-server!
  "Start a UDP RoughTime server on a background thread.
   Returns {:channel ch :thread th :stop (fn []) :request-channel}.
   Options:
     bind-addr (default \"127.0.0.1\"), port (required)."
  ([port] (run-server! "127.0.0.1" port))
  ([bind-addr port]
   (let [;; when the channel is full, drop *oldest* items
         request-channel     (a/chan (a/sliding-buffer (config/request-queue-depth)))
         ^DatagramChannel ch (DatagramChannel/open)
         buf-size-mb         (config/udp-buffer-size-mb)]

     ;; allow quick restarts
     (.setOption ch StandardSocketOptions/SO_REUSEADDR Boolean/TRUE)
     ;; buffer up to 1Mb of incoming requests
     (.setOption ch StandardSocketOptions/SO_RCVBUF ^Integer (int (* buf-size-mb 1024 1024)))
     (.setOption ch StandardSocketOptions/SO_SNDBUF ^Integer (int (* buf-size-mb 1024 1024)))

     (.bind ch (InetSocketAddress. bind-addr (int port)))
     (.configureBlocking ch true)

     (let [rcv-buf (ByteBuffer/allocateDirect 4096)
           srv-loop
           (fn []
             (try
               (run-server-loop! ch rcv-buf request-channel)
               (catch AsynchronousCloseException _
                 ;; expected on shutdown
                 nil)
               (catch Exception ex
                 (t/log! {:level :fatal
                          :id ::fatal
                          :error ex}))
               (finally
                 (try (.close ch) (catch Exception _))
                 (a/close! request-channel))))

           th (doto (Thread. ^Runnable srv-loop)
                (.setName (format "roughtime-udp-%s:%d" bind-addr (int port))))

           stop-fn (fn [] (try (.close ch) (catch Exception _)))]
       (.start th)
       {:channel ch
        :request-channel request-channel
        :thread th
        :stop stop-fn
        :join (fn [& {:keys [msec]}] (.join th msec))
        :alive? (fn [] (.isAlive th))}))))
