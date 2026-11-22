package auth

import "testing"

func TestDisabledUsersUsePrivateConfiguration(t *testing.T) {
	t.Setenv("MULTICA_DISABLED_USER_IDS", " 00000000-0000-4000-8000-000000000001, ")
	t.Setenv("MULTICA_DISABLED_USER_EMAILS", " DISABLED@example.invalid, other@example.invalid ")
	if !IsTemporarilyDisabledUserID("00000000-0000-4000-8000-000000000001") {
		t.Fatal("configured ID must be disabled")
	}
	if !IsTemporarilyDisabledUserEmail("disabled@EXAMPLE.invalid") {
		t.Fatal("configured email must be disabled case-insensitively")
	}
	if !IsTemporarilyDisabledUser("allowed-id", "other@example.invalid") {
		t.Fatal("any configured email must disable an otherwise unrelated ID")
	}
	if IsTemporarilyDisabledUser("", "") || IsTemporarilyDisabledUser("other", "other2@example.invalid") {
		t.Fatal("empty or unrelated identifiers must not be disabled")
	}
}

func TestDisabledUsersWithEmptyConfiguration(t *testing.T) {
	t.Setenv("MULTICA_DISABLED_USER_IDS", "")
	t.Setenv("MULTICA_DISABLED_USER_EMAILS", "")
	if IsTemporarilyDisabledUser("00000000-0000-4000-8000-000000000001", "disabled@example.invalid") {
		t.Fatal("empty configuration must not disable synthetic accounts")
	}
}
