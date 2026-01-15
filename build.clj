(ns build
  (:require
   [clojure.string :as string]
   [clojure.tools.build.api :as b]))

;;; Project coordinates and paths
(def lib       'com.sturdystats/roughtime-server)
(def main-ns   'roughtime-server.core)

(def basis     (b/create-basis {:project "deps.edn"}))
(def class-dir "target/classes")
(def target    "target")

;;; Git helpers
(defn git-describe-last-tag
  "Returns the last tag (string) or nil if none."
  []
  (try
    (let [out (b/git-process {:git-args ["describe" "--tags" "--abbrev=0"]})
          tag (some-> out string/trim)]
      (when (seq tag) tag))
    (catch Throwable _ nil)))

(defn git-short-sha []
  (-> (b/git-process {:git-args ["rev-parse" "--short" "HEAD"]})
      str
      string/trim))

(def commit-count (b/git-count-revs {}))

(defn normalize-tag->version [tag]
  ;; Strip common leading "v"
  (if (and tag (string/starts-with? tag "v"))
    (subs tag 1)
    tag))

(defn git-exact-tag []
  (try
    (let [out (b/git-process {:git-args ["describe" "--tags" "--exact-match"]})
          tag (some-> out string/trim)]
      (when (seq tag) tag))
    (catch Throwable _ nil)))

(def version
  (let [sha   (git-short-sha)
        exact (some-> (git-exact-tag) normalize-tag->version)
        last  (some-> (git-describe-last-tag) normalize-tag->version)]
    (cond
      exact exact
      last  (format "%s-g%s" last sha)
      :else (format "0.1.%s-g%s" commit-count sha))))

(def jar-file  (format "%s/%s-%s.jar" target (name lib) version))
(def uber-file (format "%s/%s-%s-standalone.jar" target (name lib) version))

;;; Tasks

(defn clean
  "Delete the target/ directory."
  [_]
  (b/delete {:path target})
  (println "Cleaned" target))

(defn prepare
  [_]
  (b/copy-dir {:src-dirs   ["resources"]
               :target-dir class-dir})
  (b/compile-clj {:basis basis
                  :src-dirs ["src"]
                  :class-dir class-dir
                  :ns-compile [main-ns]})
  (println "Prepared class-dir with resources."))

(defn jar
  "Create a thin JAR (not standalone) with a POM."
  [_]
  (clean nil)
  (prepare nil)
  (b/write-pom {:class-dir class-dir
                :lib       lib
                :version   version
                :basis     basis
                :src-dirs  ["src"]
                :scm       {:tag  (git-describe-last-tag)
                            :url  "https://github.com/Sturdy-Statistics/roughtime-server"}
                :pom-data
                [[:description "Clojure implementation of a simple RoughTime server."]
                 [:url "https://github.com/Sturdy-Statistics/roughtime-server"]
                 [:licenses
                  [:license
                   [:name "Apache License 2.0"]
                   [:url "https://www.apache.org/licenses/LICENSE-2.0"]]]
                 [:scm
                  [:tag (git-describe-last-tag)]
                  [:url "https://github.com/Sturdy-Statistics/roughtime-server"]
                  [:connection "scm:git:https://github.com/Sturdy-Statistics/roughtime-server.git"]]]})

  (b/jar {:class-dir class-dir
          :jar-file  jar-file})

  (println "Wrote jar:" jar-file)
  {:jar-file jar-file})

(defn uber
  "Create an executable uberjar with Main-Class manifest, ready for `java -jar`."
  [_]
  (clean nil)
  (prepare nil)
  ;; tools.build will include all deps (incl. git deps) into the uberjar.
  ;; :main sets the manifest Main-Class.
  (b/uber {:class-dir class-dir
           :uber-file uber-file
           :basis     basis
           :main      main-ns})
  (println "Wrote uberjar:" uber-file))
