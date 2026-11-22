package auth

import (
	"errors"
	"os"
	"strings"
)

const TemporarilyDisabledUserError = "account disabled"

var ErrTemporarilyDisabledUser = errors.New(TemporarilyDisabledUserError)

func disabledListContains(variable, candidate string) bool {
	candidate = strings.ToLower(strings.TrimSpace(candidate))
	if candidate == "" {
		return false
	}
	for _, entry := range strings.Split(os.Getenv(variable), ",") {
		if strings.ToLower(strings.TrimSpace(entry)) == candidate {
			return true
		}
	}
	return false
}

func IsTemporarilyDisabledUser(userID, email string) bool {
	return IsTemporarilyDisabledUserID(userID) || IsTemporarilyDisabledUserEmail(email)
}

func IsTemporarilyDisabledUserID(userID string) bool {
	return disabledListContains("MULTICA_DISABLED_USER_IDS", userID)
}

func IsTemporarilyDisabledUserEmail(email string) bool {
	return disabledListContains("MULTICA_DISABLED_USER_EMAILS", email)
}
