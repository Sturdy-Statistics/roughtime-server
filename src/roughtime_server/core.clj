(ns roughtime-server.core
  (:require
   [clojure.stacktrace :refer [print-stack-trace]]
   [clojure.core.async :as a]
   ;;
   [roughtime-protocol.server :as s]
   ;;
   [roughtime-server.config :as config]
   [roughtime-server.keys :refer [mint-certificate
                                  check-cert-expiration
                                  read-longterm-public-key]]
   ;;
   [roughtime-server.server-udp :as server]
   [roughtime-server.batcher    :as batcher]
   [roughtime-server.worker     :as worker]
   [roughtime-server.sender     :as sender]
   ;;
   [chime.core :as chime]
   ;;
   [taoensso.telemere :as t])
  (:import
   (java.time LocalTime ZonedDateTime ZoneId Period))
  (:gen-class))

(set! *warn-on-reflection* true)

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Logging

(defn init-logging! [log-path]
  ;; remove default log handler
  (doseq [h (keys (t/get-handlers))] (t/remove-handler! h))

  ;; console as edn
  (t/add-handler! :my-console-handler
                  (t/handler:console {:output-fn (t/pr-signal-fn {:pr-fn :edn})}))

  ;; file as edn
  (t/add-handler! :my-file-handler
                  (t/handler:file {:output-fn (t/pr-signal-fn {:pr-fn :edn})
                                   :path log-path
                                   :interval :monthly
                                   :max-file-size (* 1024 1024 4)
                                   :max-num-parts 8
                                   :max-num-intervals 6
                                   :gzip-archives? false}))

  (t/set-min-level! :info)              ; global
  (t/set-min-level! :log "taoensso.*" :warn)
  (t/set-min-level! :log "org.eclipse.jetty.*" :warn)
  (t/set-min-level! :slf4j "org.eclipse.jetty.*" :warn))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; keys

(defonce cert (atom nil))

;; TTL of 48 hours, rotate every 24 hours
(def online-key-lifetime-secs (* 48 3600))

(defn install-new-cert! [secrets-dir]
  (when-let [old @cert]
    (t/log! {:level :info
             :id ::cert-exp
             :data (check-cert-expiration old)}))
  (let [new (mint-certificate
             secrets-dir online-key-lifetime-secs)]
    (swap! cert (constantly new))
    (t/log! {:level :info
             :id ::cert-install
             :msg "Installed new online certificate"})))

(defn log-public-key [secrets-dir]
  (let [data (read-longterm-public-key secrets-dir)]
    (t/log! {:level :info
             :id ::pub-key
             :data data})))


;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; key rotation

(def rotate-schedule
  (chime/periodic-seq (-> (LocalTime/of 1 0 0) ; 1AM Los Angeles time
                          (.adjustInto (ZonedDateTime/now (ZoneId/of "America/Los_Angeles")))
                          .toInstant)
                      (Period/ofDays 1)))

(defn start-key-rotator!
  [rotate-cert-fn]
  (chime/chime-at rotate-schedule rotate-cert-fn))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; server

(defn respond-single
  "make a closure around s/respond which is a single-arg function of the
  request-packet"
  ^bytes [^bytes request-packet]
  (try
    (s/respond {:request-bytes request-packet
                :cert-map @cert
                :min-size-bytes (config/min-msg-size)})
    (catch Exception ex
      (t/log! {:level :error
               :id ::respond
               :error ex}))))

(defn respond-batch
  "make a closure around s/batch-respond which is a single-arg function of the
  batch of request-packets"
  [request-batch]
  (try
    (s/batch-respond request-batch @cert
                     {:min-size-bytes (config/min-msg-size)})
    (catch Exception ex
      (t/log! {:level :error
               :id ::batch-respond
               :error ex}))))

(defn respond
  [request-batch]

  (if (= 1 (count request-batch))
    ;; for single responses, we support versions 1 & 2
    [(respond-single (first request-batch))]
    ;; batched responses are faster if we have more than 1 request
    (respond-batch request-batch)))

(defn launch
  []
  (let [server-map     (server/run-server! (config/host) (config/port))
        datagram-ch    (:channel server-map)
        request-ch     (:request-channel server-map)
        ;;
        batch-ch       (batcher/run-batcher! {:request-channel request-ch
                                              :max-batch (config/max-batch-size)
                                              :flush-ms (config/flush-ms)})
        ;;
        worker-map     (worker/launch-workers! {:batch-channel batch-ch
                                                :respond-fn respond
                                                :num-workers (config/num-workers)})
        response-ch    (:response-channel worker-map)

        ;;
        sender-done-ch (sender/run-sender! {:response-channel response-ch
                                            :datagram-channel datagram-ch})]
    (letfn [(stop! []

              ;; phase 1: graceful
              (t/log! {:level :info :id ::shutdown :msg "Stopping UDP server (graceful)..."} )
              (let [server-stop-fn (:stop server-map)]
                (try (server-stop-fn) (catch Throwable _)))

              ;; wait up to 200ms for queued requests to drain
              (let [timeout-ch     (a/timeout 200)
                    [_ ch]         (a/alts!! [sender-done-ch timeout-ch] :priority true)
                    worker-stop-fn (:stop worker-map)]

                ;; timed out → work still in the pipeline
                ;; phase 2: forceful
                (when (= ch timeout-ch)
                  (t/log! {:level :warn :id ::shutdown-escalate :msg "Force-stopping UDP server..."} )
                  (worker-stop-fn)
                  (.interrupt ^Thread (:th server-map))))

              ;; make sure we're closed
              (let [server-join   (:join server-map)]
                (try (server-join {:msec 200}) (catch Throwable _)))

              (let [timeout-ch (a/timeout 200)]
                (try (a/alts!! [sender-done-ch timeout-ch] :priority true) (catch Throwable _)))

              (t/log! {:level :info :id ::shutdown-done :msg "Shutdown complete."})
              (t/stop-handlers!))]
      stop!)))

(defn add-shutdown-hook! [stop-fn]
  (.addShutdownHook (Runtime/getRuntime)
                    (Thread.
                     #(do (t/log! {:level :info
                                   :id ::shutdown
                                   :msg "Caught SIGTERM. Shutting down..."})
                          (try (stop-fn)
                               (catch Throwable _))))))

(defn -main [& argv]
  (try
    (config/load! argv)

    (let [rotate-cert-fn (fn [_time] (install-new-cert! (config/secrets-dir)))]

      (init-logging! (config/log-path))
      (rotate-cert-fn 0)
      (log-public-key (config/secrets-dir))
      (start-key-rotator! rotate-cert-fn))

    (let [stop! (launch)]
      (add-shutdown-hook! stop!)
      @(promise))

    (catch Exception e
      (print-stack-trace e)
      (t/log! {:level :fatal
               :id ::fatal
               :error e
               :msg "Unhandled exception during startup"})
      (t/stop-handlers!)
      (flush)
      (Thread/sleep 10)
      (System/exit 1))))
