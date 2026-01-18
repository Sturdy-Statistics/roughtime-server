(ns roughtime-server.stats
  (:require
   [clojure.core.async :as a]
   [taoensso.truss :refer [have]]
   [taoensso.telemere :as t]))

(set! *warn-on-reflection* true)

(defn stats-loop [stats-ch]
  (a/go-loop [t-start  (System/currentTimeMillis)
              n-sample 0
              sums     {:receive-and-queue 0
                        :batch 0
                        :respond 0
                        :send 0
                        ;;
                        :rcv-queue 0
                        :worker-queue 0
                        :snd-queue 0}]
    (if-let [v (a/<! stats-ch)]
      (let [dt-ms (- (System/currentTimeMillis) t-start)]
        (if (or (>= n-sample 100000)
                (and (>= n-sample 1000) (>= dt-ms 3600000)))
          ;; flush stats
          (do
            (t/log!
             {:level :info
              :id :roughtime-server/stats
              :msg "performance stats"
              :data (update-vals sums #(quot % n-sample))})
            (recur (System/currentTimeMillis) 0 (update-vals sums (constantly 0))))

          ;; accumulate
          (recur t-start
                 (inc n-sample)
                 (merge-with + sums (update-vals v #(have integer? %))))))
      (t/log! {:level :info :id ::stats-closed :msg "Stats channel closed."}))))
