(ns roughtime-server.batcher
  (:require
   [clojure.core.async :as a]
   [roughtime-server.config :as config]))

(set! *warn-on-reflection* true)

(defn- run-batcher-loop!
  [{:keys [request-channel
           batch-channel
           max-batch
           flush-ms]}]
  (loop [batch []]
    (let [[v ch] (if (>= (count batch) max-batch)
                   [::flush ::flush]
                   (let [t (a/timeout flush-ms)]
                     (a/alts!! [request-channel t] :priority true)))]
      (cond
        (= ch request-channel)
        (if (nil? v)
          ;; input closed → flush and close
          (do
            (when (seq batch) (a/>!! batch-channel {:batch batch :batch-sent-ns (System/nanoTime)}))
            (a/close! batch-channel))
          ;; received a request → append to batch
          (recur (conj batch (assoc v :batched-ns (System/nanoTime)))))

        ;; timeout or ::flush → flush and recur
        :else
        (do
          (when (seq batch) (a/>!! batch-channel {:batch batch :batch-sent-ns (System/nanoTime)}))
          (recur []))))))

(defn run-batcher!
  [{:keys [request-channel max-batch flush-ms]}]
  (let [batch-channel (a/chan (config/batch-queue-depth))]
    (a/thread
      (run-batcher-loop! {:request-channel request-channel
                          :batch-channel batch-channel
                          :max-batch max-batch
                          :flush-ms flush-ms}))
    batch-channel))
