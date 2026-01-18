(ns roughtime-server.sender
  (:require
   [clojure.core.async :as a]
   [roughtime-server.config :as config]
   [roughtime-server.stats :as stats])
  (:import
   (java.nio ByteBuffer)
   (java.net InetSocketAddress)
   (java.nio.channels DatagramChannel)))

(set! *warn-on-reflection* true)

(defn- send-one!
  [^DatagramChannel datagram-channel
   ^InetSocketAddress dest
   ^bytes request-bytes
   ^bytes response-bytes]
  (when (and
         (bytes? response-bytes)
         ;; RoughTime response MUST NOT exceed request length
         (<= (alength response-bytes)
             (alength request-bytes)))
    (.send datagram-channel
           (ByteBuffer/wrap response-bytes)
           dest)))

(defn- send-stats!
  [stats-ch request send-start-ns dt-send]
  (let [{:keys [received-ns queued-ns
                batched-ns batch-queued-ns
                worker-started-ns response-queued-ns
                batch-size]} request]
    (a/put!
     stats-ch
     { ;; throughput
      :receive-and-queue (- queued-ns received-ns)
      :batch             (quot (- batch-queued-ns batched-ns)           batch-size)
      :respond           (quot (- response-queued-ns worker-started-ns) batch-size)
      :send              dt-send
      ;; queueing: latency but not throughput
      :rcv-queue    (- batched-ns queued-ns)
      :worker-queue (- worker-started-ns batch-queued-ns)
      :snd-queue    (- send-start-ns response-queued-ns)})))

(defn- run-sender-loop!
  [{:keys [response-channel
           datagram-channel
           stats-channel]}]
  (loop []
    ;; nil value: response channel closed → done
    (when-let [v (a/<!! response-channel)]
      ;; got a response batch → loop over responses and send
      (let [send-start-ns (System/nanoTime)]
       (doseq [req v]
         (let [t0 (System/nanoTime)
               {:keys [src response-bytes request-bytes]} req]
           (send-one! datagram-channel src request-bytes response-bytes)
           (send-stats! stats-channel req send-start-ns (- (System/nanoTime) t0)))))

      (recur)))
  (a/close! stats-channel))

(defn run-sender!
  "start a background thread which reads responses from `response-channel`
  and sends them via `datagram-channel`"
  [{:keys [response-channel
           datagram-channel]}]
  (let [stats-ch (a/chan (config/stats-queue-depth))]
    ;; start the stats loop
    (stats/stats-loop stats-ch)
    (a/thread (run-sender-loop! {:response-channel response-channel
                                 :datagram-channel datagram-channel
                                 :stats-channel stats-ch}))))
