(ns roughtime-server.worker
  (:require
   [clojure.core.async :as a]
   [roughtime-server.config :as config]
   [taoensso.telemere :as t]))

(set! *warn-on-reflection* true)

(defn- process-batch
  "process a batch of requests.  returns a vector of maps
  {:src :response-bytes :received-ns :processed-ns}"
  [batch batch-respond]
  ;; batch is {:src :request-bytes :received-ns}
  (let [request-batch (mapv :request-bytes batch)
        responses     (batch-respond request-batch)
        ts            (System/nanoTime)]
    (assert (= (count batch) (count responses)))
    (letfn [(xf [req rsp]
              ;; skip items without a response
              (when rsp (assoc req
                               :response-bytes rsp
                               :processed-ns ts)))]
      ;; drop items without a response
      (remove nil?
              (mapv xf batch responses)))))

(defn- process-batch-safe
  [batch batch-respond]
  (try (or (process-batch batch batch-respond) [])
       (catch Throwable thr
         ;; log error
         (t/log! {:level :error
                  :id ::process-batch
                  :error thr})
         ;; return an empty batch
         [])))

(defn launch-workers!
  [{:keys [batch-channel
           respond-fn
           num-workers]}]

  (letfn [(proc [batch] (process-batch-safe batch respond-fn))]
    (let [response-channel (a/chan (config/response-queue-depth))
          ;; transducer expands each batch into 0..N response maps
          xf (mapcat proc)]

      ;; close? = true means: when batch-channel closes, response-channel closes too
      (a/pipeline-blocking num-workers response-channel xf batch-channel true)

      {:response-channel response-channel
       ;; graceful stop: close upstream (batch-channel) and let it drain.
       ;; this is a hard stop: drops in-flight responses
       :stop (fn [] (a/close! response-channel))})))
