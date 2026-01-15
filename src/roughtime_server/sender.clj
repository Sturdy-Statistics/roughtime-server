(ns roughtime-server.sender
  (:require
   [clojure.core.async :as a])
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

(defn- run-sender-loop!
  [{:keys [response-channel
           datagram-channel]}]
  (loop []
    ;; nil value: response channel closed → done
    (when-let [v (a/<!! response-channel)]
      ;; got a response → send it
      (let [{:keys [src response-bytes request-bytes]} v]
        (send-one! datagram-channel src request-bytes response-bytes)
        (recur)))))

(defn run-sender!
  "start a background thread which reads responses from `response-channel`
  and sends them via `datagram-channel`"
  [{:keys [response-channel
           datagram-channel]}]
  (a/thread (run-sender-loop! {:response-channel response-channel
                               :datagram-channel datagram-channel})))
