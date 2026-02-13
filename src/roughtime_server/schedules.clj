(ns roughtime-server.schedules
  (:require
   [chime.core :as chime]
   [taoensso.telemere :as t])
  (:import
   (java.time.temporal TemporalAdjusters)
   (java.time ZonedDateTime ZoneId Period DayOfWeek)))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; rotation schedules

(def ^:private pacific-tz (ZoneId/of "America/Los_Angeles"))

(def ^:private cert-rotate-schedule
  (->> (chime/periodic-seq
        (-> (ZonedDateTime/now pacific-tz)
            (.with (TemporalAdjusters/nextOrSame DayOfWeek/WEDNESDAY))
            (.withHour 1)
            (.withMinute 0) ;; 1:00 AM
            (.withSecond 0)
            (.withNano 0))

        (Period/ofWeeks 1))

       (chime/without-past-times)))

(def ^:private server-key-rotate-schedule
  (->> (chime/periodic-seq
        ;; ANCHOR: January 1st of the CURRENT year at Midnight
        ;; We anchor here so the intervals are always aligned to Jan/July
        (-> (ZonedDateTime/now pacific-tz)
            (.withMonth 1)
            (.withDayOfMonth 1)
            (.withHour 0)
            (.withMinute 0) ;; 12:00 AM
            (.withSecond 0)
            (.withNano 0))

        ;; STEP: 6 Months
        (Period/ofMonths 6))

       (chime/without-past-times)))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; key rotation

(defn- start-cert-rotator!
  [install-new-cert!]
  (chime/chime-at
   cert-rotate-schedule
   install-new-cert!))

(defn- start-server-key-rotator!
  [rotate-bailey!]
  (chime/chime-at
   server-key-rotate-schedule
   rotate-bailey!))

(defn start-key-rotators!
  [{:keys [rotate-bailey! install-new-cert!]}]
  (start-cert-rotator! install-new-cert!)
  (start-server-key-rotator! rotate-bailey!)
  (t/log! {:level :info
           :id ::started-rotators
           :msg "started key rotators"}))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (import '[java.time.format DateTimeFormatter])

;; (def readable-fmt
;;   (DateTimeFormatter/ofPattern "MMMM dd, yyyy 'at' h:mm a z"))

;; (->> (take 5 cert-rotate-schedule)
;;      (map #(.format readable-fmt %)))
;; ;; => ("February 18, 2026 at 1:00 AM PST"
;; ;;     "February 25, 2026 at 1:00 AM PST"
;; ;;     "March 04, 2026 at 1:00 AM PST"
;; ;;     "March 11, 2026 at 1:00 AM PDT"
;; ;;     "March 18, 2026 at 1:00 AM PDT")

;; (->> (take 5 server-key-rotate-schedule)
;;      (map #(.format readable-fmt %)))
;; ;; => ("July 01, 2026 at 12:00 AM PDT"
;; ;;     "January 01, 2027 at 12:00 AM PST"
;; ;;     "July 01, 2027 at 12:00 AM PDT"
;; ;;     "January 01, 2028 at 12:00 AM PST"
;; ;;     "July 01, 2028 at 12:00 AM PDT")
