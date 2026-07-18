// Entry point: open (and seed) the database, then serve the users page over
// HTTP/1.1.
//
// Usage: zigvibe-go [listen-address] [database-path]
//
//	listen-address  default 127.0.0.1:8080
//	database-path   default users.db (created and seeded on first run)
package main

import (
	"log"
	"net/http"
	"os"
)

const (
	defaultAddress = "127.0.0.1:8080"
	defaultDBPath  = "users.db"
)

func main() {
	address := defaultAddress
	if len(os.Args) > 1 {
		address = os.Args[1]
	}
	dbPath := defaultDBPath
	if len(os.Args) > 2 {
		dbPath = os.Args[2]
	}

	// One sqinn child process (one SQLite connection) is shared by every request
	// goroutine; sqinn serializes calls internally.
	db, err := openDB(dbPath)
	if err != nil {
		log.Fatalf("open database %q: %v", dbPath, err)
	}
	defer func() {
		if err := db.Close(); err != nil {
			log.Printf("close database: %v", err)
		}
	}()

	if err := initDB(db); err != nil {
		log.Fatalf("initialize database: %v", err)
	}
	log.Printf("database ready at %s", dbPath)

	srv := &server{db: db, hub: newHub()}

	log.Printf("listening on http://%s/", address)
	httpServer := &http.Server{Addr: address, Handler: srv.routes()}
	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatalf("server: %v", err)
	}
}
