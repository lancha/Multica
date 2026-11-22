package handler

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
)

// No database or membership cache is needed: malformed input must be rejected
// before either dependency is accessed.
func TestDaemonUUIDBoundaries(t *testing.T) {
	h := &Handler{}
	for _, endpoint := range []struct {
		name, param string
		handler     http.HandlerFunc
	}{
		{"cancel task", "taskId", h.CancelTask},
		{"workspace repos", "workspaceId", h.GetDaemonWorkspaceRepos},
	} {
		for _, value := range []string{"", "not-a-uuid", "1234"} {
			t.Run(endpoint.name+"/"+value, func(t *testing.T) {
				r := httptest.NewRequest(http.MethodPost, "/", nil)
				route := chi.NewRouteContext()
				route.URLParams.Add(endpoint.param, value)
				r = r.WithContext(context.WithValue(r.Context(), chi.RouteCtxKey, route))
				w := httptest.NewRecorder()
				endpoint.handler(w, r)
				if w.Code != http.StatusBadRequest {
					t.Fatalf("status = %d, want 400", w.Code)
				}
			})
		}
	}
}
