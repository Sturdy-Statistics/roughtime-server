(ns roughtime-server.sender
  (:require
   [clojure.pprint :refer [pprint]]
   [clojure.core.async :as a]
   [taoensso.truss :refer [have]])
  (:import
   (java.nio ByteBuffer)
   (java.net InetSocketAddress)
   (java.nio.channels DatagramChannel)))

(set! *warn-on-reflection* true)

(def stats-ch (a/chan 1024))

(defn stats-loop []
  (a/go-loop [n-sample       0
             sum-rcv-queue   0
             sum-batcher     0
             sum-batch-queue 0
             sum-worker      0
             sum-send-queue  0]
    (if-let [v (a/<! stats-ch)]
      (let [{:keys [rcv-queue batcher batch-queue worker send-queue]} v]
        (if (and (< 0 n-sample) (= 0 (mod n-sample 1000)))
          (do
            ;; TODO: replace with t/log!
            (pprint {:n-sample     n-sample
                     :rcv-queue   (quot sum-rcv-queue   n-sample)
                     :batcher     (quot sum-batcher     n-sample)
                     :batch-queue (quot sum-batch-queue n-sample)
                     :worker      (quot sum-worker      n-sample)
                     :send-queue  (quot sum-send-queue  n-sample)})
            (recur 0 0 0 0 0 0))
          (recur (inc n-sample)
                 (+ sum-rcv-queue   (have integer? rcv-queue))
                 (+ sum-batcher     (have integer? batcher))
                 (+ sum-batch-queue (have integer? batch-queue))
                 (+ sum-worker      (have integer? worker))
                 (+ sum-send-queue  (have integer? send-queue)))))
      (println "Stats channel closed."))))

(stats-loop)

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

(defn- run-sender-loop!
  [{:keys [response-channel
           datagram-channel]}]
  (loop []
    ;; nil value: response channel closed → done
    (when-let [v (a/<!! response-channel)]
      ;; got a response → send it
      (let [sent-ns (System/nanoTime)
            {:keys [src response-bytes request-bytes
                    received-ns batched-ns batch-sent-ns worker-ns processed-ns batch-size]} v]

        (send-one! datagram-channel src request-bytes response-bytes)

        ;; send stats
        (a/put!
         stats-ch
         {:rcv-queue   (- batched-ns received-ns)
          :batcher     (- batch-sent-ns batched-ns)
          :batch-queue (- worker-ns batch-sent-ns)
          :worker      (quot (- processed-ns worker-ns) batch-size)
          :send-queue  (- sent-ns processed-ns)})

        (recur))))
  (a/close! stats-ch))

(defn run-sender!
  "start a background thread which reads responses from `response-channel`
  and sends them via `datagram-channel`"
  [{:keys [response-channel
           datagram-channel]}]
  (a/thread (run-sender-loop! {:response-channel response-channel
                               :datagram-channel datagram-channel})))
