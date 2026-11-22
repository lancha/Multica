package handler

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	db "github.com/multica-ai/multica/server/pkg/db/generated"
)

// Exercise generated queries directly: handler prechecks cannot protect a
// caller against a parent disappearing before the insert statement runs.
func TestCommentParentIntegrity(t *testing.T) {
	if testPool == nil {
		t.Skip("database not available")
	}
	for _, supplement := range []bool{false, true} {
		name := "ordinary"
		if supplement {
			name = "supplement"
		}
		for _, state := range []string{"missing", "other issue", "other workspace", "tombstone", "root"} {
			t.Run(name+"/"+state, func(t *testing.T) {
				f, create := parentIntegrityWriter(t, supplement)
				switch state {
				case "missing":
					dbfx.Exec(t, `DELETE FROM comment WHERE id=$1`, f.triggerID)
				case "other issue":
					other := dbfx.Issue(t, "other parent issue")
					dbfx.Exec(t, `UPDATE comment SET issue_id=$2 WHERE id=$1`, f.triggerID, other)
				case "other workspace":
					other := dbfx.Workspace(t, "other parent workspace", "parent-integrity-other")
					dbfx.Exec(t, `UPDATE comment SET workspace_id=$2 WHERE id=$1`, f.triggerID, other)
				case "tombstone":
					dbfx.Exec(t, `UPDATE comment SET deleted_at=now(), content='' WHERE id=$1`, f.triggerID)
				case "root":
					f.triggerID = ""
					if supplement {
						dbfx.Exec(t, `UPDATE agent_task_queue SET trigger_comment_id=NULL WHERE id=$1`, f.taskID)
					}
				}
				var revision int64
				var activity time.Time
				dbfx.QueryRow(t, `SELECT revision,last_activity_at FROM issue WHERE id=$1`, f.issueID).Scan(&revision, &activity)
				err := create(t.Context(), f.triggerID)
				// The retained task-trigger FK clears a trigger deleted before the
				// statement starts. Concurrent deletion must instead reject the
				// already-selected trigger (covered separately below).
				valid := state == "tombstone" || state == "root" || (supplement && state == "missing")
				if valid {
					if err != nil {
						t.Fatalf("valid parent: %v", err)
					}
				} else {
					if !errors.Is(err, pgx.ErrNoRows) {
						t.Fatalf("invalid parent: want no rows, got %v", err)
					}
					assertIssueActivityState(t, f.issueID, revision, activity)
					if n := dbfx.Count(t, `SELECT count(*) FROM comment WHERE issue_id=$1 AND content='guarded reply'`, f.issueID); n != 0 {
						t.Fatal("invalid parent persisted a reply")
					}
					if supplement && dbfx.Count(t, `SELECT count(*) FROM task_supplement WHERE task_id=$1`, f.taskID) != 0 {
						t.Fatal("invalid parent persisted a supplement")
					}
				}
			})
		}
	}
}

func TestCommentParentConcurrentDeletion(t *testing.T) {
	if testPool == nil {
		t.Skip("database not available")
	}
	for _, supplement := range []bool{false, true} {
		for _, lock := range []string{"issue", "parent"} {
			name := "CreateComment"
			if supplement {
				name = "CreateTaskSupplement"
			}
			t.Run(name+"/"+lock, func(t *testing.T) {
				f, create := parentIntegrityWriter(t, supplement)
				ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
				defer cancel()
				holder, err := testPool.Begin(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer holder.Rollback(context.Background())
				query, id := `SELECT id FROM issue WHERE id=$1 FOR UPDATE`, f.issueID
				if lock == "parent" {
					query, id = `SELECT id FROM comment WHERE id=$1 FOR UPDATE`, f.triggerID
				}
				if _, err = holder.Exec(ctx, query, id); err != nil {
					t.Fatal(err)
				}
				done := make(chan error, 1)
				go func() { done <- create(ctx, f.triggerID) }()
				waitForCommentMutationLock(t, name, done)
				if _, err = holder.Exec(ctx, `DELETE FROM comment WHERE id=$1`, f.triggerID); err != nil {
					t.Fatal(err)
				}
				if err = holder.Commit(ctx); err != nil {
					t.Fatal(err)
				}
				if err = <-done; !errors.Is(err, pgx.ErrNoRows) {
					t.Fatalf("concurrent delete: want no rows, got %v", err)
				}
				if n := dbfx.Count(t, `SELECT count(*) FROM comment WHERE issue_id=$1`, f.issueID); n != 0 {
					t.Fatalf("concurrent delete left %d comments", n)
				}
			})
		}
	}
}

func TestCommentParentSupplementTriggerChangedWhileWaiting(t *testing.T) {
	if testPool == nil {
		t.Skip("database not available")
	}
	f, create := parentIntegrityWriter(t, true)
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	holder, err := testPool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Rollback(context.Background())
	if _, err = holder.Exec(ctx, `SELECT id FROM agent_task_queue WHERE id=$1 FOR UPDATE`, f.taskID); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- create(ctx, f.triggerID) }()
	waitForCommentMutationLock(t, "CreateTaskSupplement", done)
	if _, err = holder.Exec(ctx, `UPDATE agent_task_queue SET trigger_comment_id=NULL WHERE id=$1`, f.taskID); err != nil {
		t.Fatal(err)
	}
	if err = holder.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err = <-done; !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("changed trigger: want no rows, got %v", err)
	}
	if dbfx.Count(t, `SELECT count(*) FROM comment WHERE issue_id=$1 AND content='guarded reply'`, f.issueID) != 0 ||
		dbfx.Count(t, `SELECT count(*) FROM task_supplement WHERE task_id=$1`, f.taskID) != 0 {
		t.Fatal("changed trigger persisted a comment or supplement")
	}
}

func parentIntegrityWriter(t *testing.T, supplement bool) (supplementFixture, func(context.Context, string) error) {
	t.Helper()
	f := newSupplementFixture(t, "codex", "running", true)
	dbfx.Exec(t, `UPDATE issue SET last_activity_at=now() - interval '1 day' WHERE id=$1`, f.issueID)
	create := func(ctx context.Context, parent string) error {
		if supplement {
			_, err := testHandler.Queries.CreateTaskSupplement(ctx, db.CreateTaskSupplementParams{
				TaskID: parseUUID(f.taskID), IssueID: parseUUID(f.issueID), WorkspaceID: parseUUID(testWorkspaceID),
				AuthorID: parseUUID(testUserID), Content: "guarded reply", ClientRequestID: parseUUID("0199a4e8-22ce-7b01-bba5-111111111111"),
			})
			return err
		}
		params := db.CreateCommentParams{IssueID: parseUUID(f.issueID), WorkspaceID: parseUUID(testWorkspaceID), AuthorType: "member", AuthorID: parseUUID(testUserID), Content: "guarded reply", Type: "comment"}
		if parent != "" {
			params.ParentID = parseUUID(parent)
		}
		_, err := testHandler.Queries.CreateComment(ctx, params)
		return err
	}
	return f, create
}
