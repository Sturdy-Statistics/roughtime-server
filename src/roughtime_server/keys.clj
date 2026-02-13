(ns roughtime-server.keys
  (:require
   [clojure.pprint :refer [pprint]]
   ;;
   [babashka.fs :as fs]
   [sturdy.fs :as sfs]
   ;;
   [roughtime-protocol.sign :as ed]
   [roughtime-protocol.cert :as cert]
   [roughtime-protocol.server :as server]
   ;;
   [roughtime-server.config :as config]
   ;;
   [bailey.core :as bailey]
   [bailey.util :refer [zero-byte-array]]
   [taoensso.telemere :as t])
  (:import
   (java.security KeyPair PrivateKey PublicKey)))

(set! *warn-on-reflection* true)

(defn- longterm-path []
  (-> (config/artifacts-dir)
      (fs/path "longterm.prv.bytes")
      fs/absolutize))

(defn- public-lt-path []
  (-> (config/artifacts-dir)
      (fs/path "longterm.pub")
      fs/absolutize))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; longterm ed25519 keypair file

(defn- write-longterm!
  [path ^KeyPair lt!!]
  (let [^PrivateKey lt-prv!! (.getPrivate lt!!)
        ^bytes      pkcs8!!  (ed/private-key->pkcs8 lt-prv!!)]
   (try
     (let [^bytes lt-e (bailey/encrypt pkcs8!!)]
       (sfs/spit-bytes! path lt-e {:atomic? true})
       (sfs/chmod-600! path))
     (finally
       (zero-byte-array pkcs8!!)))))

(defn- ensure-longterm!
  []
  (let [p (longterm-path)]
    (if (fs/exists? p)
      ;; already have a key; return :existing
      :existing

      ;; no key present; generate one and return :new
      (let [^KeyPair   lt!!     (ed/gen-ed25519-kp)
            ^PublicKey lt-pub   (.getPublic lt!!)

            pub-data (with-out-str
                       (-> lt-pub ed/format-public-key pprint))]

        ;; write encrypted private key
        (write-longterm! p lt!!)

        ;; write public key
        (sfs/spit-string! (public-lt-path)
                          pub-data
                          {:atomic? true})
        (t/log! {:level :info
                 :id ::new-lt-key
                 :msg "created new longterm key"})
        :new))))

(defn- read-longterm!!
  []
  (ensure-longterm!)
  (let [lt-e     (sfs/slurp-bytes (longterm-path))
        lt-prv!! (bailey/decrypt lt-e)]
    (try
      (ed/pkcs8->private-key lt-prv!!)
      (finally
        (zero-byte-array lt-prv!!)))))

(defn read-longterm-public-key
  []
  (-> (public-lt-path)
      sfs/slurp-edn))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; new certificate

(defn mint-certificate
  [expires-in-seconds]
  (let [lt!! (read-longterm!!)
        cert-map (server/mint-new-certificate-map
                  lt!!
                  {:expires-in-seconds expires-in-seconds})]
    (t/log! {:level :info
             :id ::new-certificate
             :msg "minted new certificate"})
    cert-map))

(defn check-cert-expiration
  [cert]
  (cert/check-cert-expiration (:cert-bytes cert)))

(defn make-secrets []
  (let [_    (ensure-longterm!)
        pubk (read-longterm-public-key)]
    (println (format "secrets saved to `%s`" (-> (config/artifacts-dir)
                                                 fs/absolutize
                                                 str)))
    (println "public key =")
    (pprint pubk)))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; new certificate

(defn make-backup-key
  [opts]
  (bailey/generate-backup-keys! opts))
