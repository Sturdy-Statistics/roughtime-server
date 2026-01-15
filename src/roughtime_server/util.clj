(ns roughtime-server.util
  (:import
   (java.security SecureRandom)))

(set! *warn-on-reflection* true)

;; (-> (fs/path "secrets/password.edn")
;;     fs/parent
;;     fs/absolutize
;;     str)

(def ^:private ^SecureRandom secure-random (SecureRandom.))

(defn nonce [size]
  (let [^bytes bytes (byte-array size)]
    (.nextBytes secure-random bytes)
    bytes))
