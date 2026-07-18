// Data layer for the users table: schema, first-run seeding, queries, insert,
// delete. Built on sqinn-go, which drives SQLite in a child process over
// stdin/stdout (no cgo). The child serializes calls with an internal mutex, so
// a single *sqinn.Sqinn is shared by every request goroutine.

package main

import (
	"errors"
	"strings"

	"github.com/cvilsmeier/sqinn-go/v2"
)

// User is one row of the users table.
type User struct {
	ID    int64
	Name  string
	Email string
	Role  string
}

// ErrDuplicateEmail is returned by insertUser when the email UNIQUE constraint
// is violated.
var ErrDuplicateEmail = errors.New("email already in use")

const schema = `
CREATE TABLE IF NOT EXISTS users (
    id    INTEGER PRIMARY KEY,
    name  TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    role  TEXT NOT NULL DEFAULT 'member'
);`

var seedUsers = []User{
	{Name: "Ada Lovelace", Email: "ada@example.com", Role: "admin"},
	{Name: "Alan Turing", Email: "alan@example.com", Role: "admin"},
	{Name: "Grace Hopper", Email: "grace@example.com", Role: "member"},
	{Name: "Katherine Johnson", Email: "katherine@example.com", Role: "member"},
	{Name: "Dennis Ritchie", Email: "dennis@example.com", Role: "member"},
}

// openDB launches a sqinn child process bound to the database file. Passing
// ":memory:" opens a transient database (used by the tests).
func openDB(path string) (*sqinn.Sqinn, error) {
	return sqinn.Launch(sqinn.Options{Db: path})
}

// initDB creates the schema, then seeds sample rows if the table is empty.
// Idempotent: a non-empty database is left untouched.
func initDB(db *sqinn.Sqinn) error {
	if err := db.ExecSql(schema); err != nil {
		return err
	}
	n, err := countUsers(db)
	if err != nil {
		return err
	}
	if n == 0 {
		return seed(db)
	}
	return nil
}

// seed inserts the sample rows in a single transaction using one batched
// multi-iteration Exec.
func seed(db *sqinn.Sqinn) error {
	if err := db.ExecSql("BEGIN;"); err != nil {
		return err
	}
	params := make([]sqinn.Value, 0, len(seedUsers)*3)
	for _, u := range seedUsers {
		params = append(params, sqinn.StringValue(u.Name), sqinn.StringValue(u.Email), sqinn.StringValue(u.Role))
	}
	if err := db.ExecParams("INSERT INTO users (name, email, role) VALUES (?, ?, ?);", len(seedUsers), 3, params); err != nil {
		if rbErr := db.ExecSql("ROLLBACK;"); rbErr != nil {
			return errors.Join(err, rbErr)
		}
		return err
	}
	return db.ExecSql("COMMIT;")
}

func countUsers(db *sqinn.Sqinn) (int, error) {
	rows, err := db.QueryRows("SELECT COUNT(*) FROM users;", nil, []byte{sqinn.ValInt64})
	if err != nil {
		return 0, err
	}
	return int(rows[0][0].Int64), nil
}

// allUsers fetches every user ordered by id.
func allUsers(db *sqinn.Sqinn) ([]User, error) {
	coltypes := []byte{sqinn.ValInt64, sqinn.ValString, sqinn.ValString, sqinn.ValString}
	rows, err := db.QueryRows("SELECT id, name, email, role FROM users ORDER BY id;", nil, coltypes)
	if err != nil {
		return nil, err
	}
	users := make([]User, 0, len(rows))
	for _, r := range rows {
		users = append(users, User{
			ID:    r[0].Int64,
			Name:  r[1].String,
			Email: r[2].String,
			Role:  r[3].String,
		})
	}
	return users, nil
}

// insertUser inserts a new user. Returns ErrDuplicateEmail if the email is
// already taken (the UNIQUE constraint).
func insertUser(db *sqinn.Sqinn, name, email, role string) error {
	err := db.ExecParams("INSERT INTO users (name, email, role) VALUES (?, ?, ?);", 1, 3,
		[]sqinn.Value{sqinn.StringValue(name), sqinn.StringValue(email), sqinn.StringValue(role)})
	if err != nil {
		if isUniqueViolation(err) {
			return ErrDuplicateEmail
		}
		return err
	}
	return nil
}

// deleteUser deletes the user with the given id. Deleting a non-existent id is
// a no-op.
func deleteUser(db *sqinn.Sqinn, id int64) error {
	return db.ExecParams("DELETE FROM users WHERE id = ?;", 1, 1, []sqinn.Value{sqinn.Int64Value(id)})
}

// isUniqueViolation reports whether err is a SQLite UNIQUE constraint failure.
// sqinn surfaces SQLite errors as text, so this matches the message.
func isUniqueViolation(err error) bool {
	return err != nil && strings.Contains(strings.ToUpper(err.Error()), "UNIQUE CONSTRAINT")
}
