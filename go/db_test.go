package main

import (
	"errors"
	"testing"

	"github.com/cvilsmeier/sqinn-go/v2"
)

// testDB launches an in-memory database, seeds it, and registers cleanup.
func testDB(t *testing.T) *sqinn.Sqinn {
	t.Helper()
	db, err := openDB(":memory:")
	if err != nil {
		t.Fatalf("openDB: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := initDB(db); err != nil {
		t.Fatalf("initDB: %v", err)
	}
	return db
}

func TestInitSeedsOnce(t *testing.T) {
	db := testDB(t)

	n, err := countUsers(db)
	if err != nil {
		t.Fatal(err)
	}
	if n != len(seedUsers) {
		t.Fatalf("got %d seeded users, want %d", n, len(seedUsers))
	}

	// A second init must not re-seed.
	if err := initDB(db); err != nil {
		t.Fatal(err)
	}
	if n, _ := countUsers(db); n != len(seedUsers) {
		t.Fatalf("re-seeded: got %d, want %d", n, len(seedUsers))
	}
}

func TestAllUsersOrderedByID(t *testing.T) {
	db := testDB(t)

	users, err := allUsers(db)
	if err != nil {
		t.Fatal(err)
	}
	if len(users) != len(seedUsers) {
		t.Fatalf("got %d users, want %d", len(users), len(seedUsers))
	}
	if users[0].Name != "Ada Lovelace" || users[0].Role != "admin" {
		t.Fatalf("unexpected first row: %+v", users[0])
	}
	for i, u := range users {
		if u.ID != int64(i+1) {
			t.Fatalf("row %d has id %d, want %d", i, u.ID, i+1)
		}
	}
}

func TestInsertAndDelete(t *testing.T) {
	db := testDB(t)

	if err := insertUser(db, "Barbara Liskov", "barbara@example.com", "member"); err != nil {
		t.Fatal(err)
	}
	if n, _ := countUsers(db); n != len(seedUsers)+1 {
		t.Fatalf("after insert got %d, want %d", n, len(seedUsers)+1)
	}

	if err := deleteUser(db, 6); err != nil {
		t.Fatal(err)
	}
	if n, _ := countUsers(db); n != len(seedUsers) {
		t.Fatalf("after delete got %d, want %d", n, len(seedUsers))
	}

	// Deleting again is a no-op.
	if err := deleteUser(db, 6); err != nil {
		t.Fatal(err)
	}
	if n, _ := countUsers(db); n != len(seedUsers) {
		t.Fatalf("after re-delete got %d, want %d", n, len(seedUsers))
	}
}

func TestInsertRejectsDuplicateEmail(t *testing.T) {
	db := testDB(t)

	err := insertUser(db, "Impostor", "ada@example.com", "member")
	if !errors.Is(err, ErrDuplicateEmail) {
		t.Fatalf("got %v, want ErrDuplicateEmail", err)
	}
	if n, _ := countUsers(db); n != len(seedUsers) {
		t.Fatalf("count changed after rejected insert: %d", n)
	}
}
