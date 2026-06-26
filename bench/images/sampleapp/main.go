// Minimal HTTP server used by the build scenario. Returns 200 "ok" on /,
// and reports readiness — small but real (imports net/http, exercises the
// Go toolchain in a multi-stage build).
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}
	_ = http.ListenAndServe(addr, nil)
}
