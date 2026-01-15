(ns roughtime-server.keys
  (:require
   [clojure.pprint :refer [pprint]]
   ;;
   [babashka.fs :as fs]
   [sturdy.fs :as sfs]
   ;;
   [roughtime-protocol.util :refer [bytes->b64 b64->bytes]]
   [roughtime-protocol.sign :as ed]
   [roughtime-protocol.cert :as cert]
   [roughtime-protocol.server :as server]
   ;;
   [roughtime-server.util :as util]
   ;;
   [taoensso.tempel :as tempel]
   [taoensso.truss :refer [have]]
   [taoensso.telemere :as t]))

(set! *warn-on-reflection* true)

(defn- random-token []
  (bytes->b64 (util/nonce 64)))

(defn- password-path [secrets-dir]
  (-> secrets-dir
      (fs/path "password.edn")
      fs/absolutize))

(defn- keychain-path [secrets-dir]
  (-> secrets-dir
      (fs/path "keychain.b64")
      fs/absolutize))

(defn- longterm-path [secrets-dir]
  (-> secrets-dir
      (fs/path "longterm.prv.b64")
      fs/absolutize))

(defn- public-lt-path [secrets-dir]
  (-> secrets-dir
      (fs/path "longterm.pub")
      fs/absolutize))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; password file

;;; password to encrypt/decrypt the keychain
(defn- ensure-password-file! [secrets-dir]
  (let [p (password-path secrets-dir)]
    (if-not (fs/exists? p)
      (do (sfs/spit-string! p
                            (prn-str {:password (random-token)})
                            {:atomic? true})
          (sfs/chmod-600! p)
          (t/log! {:level :info
                   :id ::new-password
                   :msg "created new password file"})
          :new)
      :existing)))

(defn- read-password!! [secrets-dir]
  (ensure-password-file! secrets-dir)
  (-> (password-path secrets-dir)
      sfs/slurp-edn
      :password))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; keychain file

(defn- ensure-keychain!
  [secrets-dir]
  (let [p (keychain-path secrets-dir)]
   (if-not (fs/exists? p)
    (let [pw   (have string? (read-password!! secrets-dir))
          kc!  (tempel/keychain {})
          kc-e (tempel/encrypt-keychain kc! {:password pw})
          b64  (bytes->b64 kc-e)]
      (sfs/spit-string! p b64 {:atomic? true})
      (sfs/chmod-600! p)
      (t/log! {:level :info
               :id ::new-keychain
               :msg "created new keychain file"})
      :new)
    :existing)))

(defn- read-keychain!! [secrets-dir]
  (ensure-keychain! secrets-dir)
  (let [pw (have string? (read-password!! secrets-dir))
        b64 (-> (keychain-path secrets-dir) str slurp)
        kc-e (b64->bytes b64)
        kc!  (tempel/decrypt-keychain kc-e {:password pw})]
    kc!))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; longterm ed25519 keypair file

(defn- ensure-longterm!
  [secrets-dir]
  (let [p (longterm-path secrets-dir)]
    (if-not (fs/exists? p)
      (let [lt!      (ed/gen-ed25519-kp)
            lt-pub   (.getPublic lt!)
            pub-data (with-out-str
                       (-> lt-pub ed/format-public-key pprint))
            lt-prv!  (.getPrivate lt!)
            lt-e     (tempel/encrypt-with-symmetric-key
                      (ed/private-key->pkcs8 lt-prv!)
                      (read-keychain!! secrets-dir))
            b64      (bytes->b64 lt-e)]
        ;; write encrypted private key
        (sfs/spit-string! p b64 {:atomic? true})
        (sfs/chmod-600! p)
        ;; write public key
        (sfs/spit-string! (public-lt-path secrets-dir)
                          pub-data
                          {:atomic? true})
        (t/log! {:level :info
                 :id ::new-lt-key
                 :msg "created new longterm key"})
        :new)
      :existing)))

(defn- read-longterm!!
  [secrets-dir]
  (ensure-longterm! secrets-dir)
  (let [b64 (-> (longterm-path secrets-dir) str slurp)
        lt-e (b64->bytes b64)
        lt-prv! (tempel/decrypt-with-symmetric-key
                 lt-e
                 (read-keychain!! secrets-dir))]
    (ed/pkcs8->private-key lt-prv!)))

(defn read-longterm-public-key
  [secrets-dir]
  (-> (public-lt-path secrets-dir)
      sfs/slurp-edn))

;;; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; new certificate

(defn mint-certificate
  [secrets-dir expires-in-seconds]
  (let [cert-map (server/mint-new-certificate-map
                  (read-longterm!! secrets-dir)
                  {:expires-in-seconds expires-in-seconds})]
    (t/log! {:level :info
             :id ::new-certificate
             :msg "minted new certificate"})
    cert-map))

(defn check-cert-expiration
  [cert]
  (cert/check-cert-expiration (:cert-bytes cert)))

(defn make-secrets [{:keys [secrets-dir] :as _args}]
  (let [_    (ensure-longterm! (have string? secrets-dir))
        pubk (read-longterm-public-key secrets-dir)]
    (println (format "secrets saved to `%s`" secrets-dir))
    (println "public key =")
    (pprint pubk)))
