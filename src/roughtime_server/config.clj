(ns roughtime-server.config
  (:require
   [babashka.cli :as cli]
   [taoensso.telemere :as t]))

(def ^:private defaults
  { ;; server
   :port           2002
   :host           "127.0.0.1"
   ;; workers
   :num-workers 2
   :max-batch-size 256
   :flush-ms 100
   ;; size policy
   :min-msg-size 1012
   :max-msg-size 2048
   ;; queues
   :request-queue-depth 16384
   :batch-queue-depth 128  ;; 128 batches * 128 req/batch = 16384 req
   :response-queue-depth 16384
   :stats-queue-depth 1024
   :udp-buffer-size-mb 20
   ;; paths
   :log-path       "logs/flashpaper-server.log"
   :secrets-dir    "secrets"})

(defn usage
  [spec]
  (cli/format-opts (merge spec {:order (vec (keys (:spec spec)))})))

(defn- pos-long? [x] (and (integer? x) (pos? x)))

(def ^:private spec
  {:spec
   {;; server
    :port            {:coerce :long   :desc "UDP port" :alias :p :validate pos-long?}
    :host            {:coerce :string :desc "HTTP hostname"}
    ;; workers
    :num-workers     {:coerce :long   :desc "Number of Worker Threads"     :validate pos-long?}
    :max-batch-size  {:coerce :long   :desc "Max Batch Size for Responses" :validate pos-long?}
    :flush-ms        {:coerce :long   :desc "Flush Request Queue"          :validate pos-long?}
    ;; size policy
    :min-msg-size    {:coerce :long   :desc "Minimum size for RT *Message*" :validate pos-long?}
    :max-msg-size    {:coerce :long   :desc "Maximum size for RT *Message*" :validate pos-long?}
    ;; queues
    :request-queue-depth  {:coerce :long :desc "Queue depth for requests"  :validate pos-long?}
    :batch-queue-depth    {:coerce :long :desc "Queue depth for batches"   :validate pos-long?}
    :response-queue-depth {:coerce :long :desc "Queue depth for responses" :validate pos-long?}
    :stats-queue-depth    {:coerce :long :desc "Queue depth for stats"     :validate pos-long?}
    ;;
    :udp-buffer-size-mb   {:coerce :long :desc "UDP socket buffer size"    :validate pos-long?}
    ;; paths
    :log-path        {:coerce :string :desc "Server log path"}
    :secrets-dir     {:coerce :string :desc "Path to dir for server secrets"}}})

(defn- print-errors! [errors]
  (binding [*out* *err*]
    (doseq [e errors] (println e)))
  (println (usage spec))
  (t/stop-handlers!)
  (flush)
  (Thread/sleep 10)
  (System/exit 1))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; State and public API

(defonce ^:private config* (atom nil))

(defn config
  "Return the full, merged config map."
  []
  @config*)

(defn require-config
  []
  (or (config)
      (throw (ex-info "config not initialized"
                      {:hint "Call (config/load! args)"}))))

(defn parse!
  "Parse argv with babashka.cli, apply defaults & validation, and return
  the final opts map."
  [argv]
  (let [{:keys [opts errors]} (cli/parse-args argv
                                              {:spec (:spec spec)
                                               :exec-args defaults})]
    (when (seq errors)
      (print-errors! errors))

    (when (or (:help opts) (:h opts))
      (println (usage spec))
      (t/stop-handlers!)
      (System/exit 0))

    opts))

(defn load!
  "Merge defaults and set the live config.
   Call this once from -main: (config/load! *command-line-args*)."
  ([]
   (load! nil))
  ([argv]
   (let [merged (parse! argv)]
     (reset! config* merged)
     merged)))

;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; accessors

(defn port []           (:port @config*))
(defn host []           (:host @config*))

(defn num-workers []    (:num-workers @config*))
(defn max-batch-size [] (:max-batch-size @config*))
(defn flush-ms []       (:flush-ms @config*))

(defn min-msg-size []   (:min-msg-size @config*))
(defn max-msg-size []   (:max-msg-size @config*))

(defn request-queue-depth []  (:request-queue-depth @config*))
(defn batch-queue-depth []    (:batch-queue-depth @config*))
(defn response-queue-depth [] (:response-queue-depth @config*))
(defn stats-queue-depth []    (:stats-queue-depth @config*))
(defn udp-buffer-size-mb []   (:udp-buffer-size-mb @config*))

(defn log-path []       (:log-path @config*))
(defn secrets-dir []    (:secrets-dir @config*))
