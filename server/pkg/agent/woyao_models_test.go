package agent

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestCodexWoyaoProviderReadsActiveProvider(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	t.Setenv("TEST_WOYAO_KEY", "secret-value")
	config := `model_provider = "woyao"
[model_providers.woyao]
base_url = "https://woyao.example.test/v1/"
env_key = "TEST_WOYAO_KEY"
wire_api = "responses"
`
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	provider, configured, err := codexWoyaoProvider()
	if err != nil {
		t.Fatal(err)
	}
	if !configured || provider.BaseURL != "https://woyao.example.test/v1" || provider.APIKey != "secret-value" {
		t.Fatalf("provider = %+v, configured = %v", provider, configured)
	}
}

func TestCodexWoyaoProviderIgnoresOtherProvider(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte(`model_provider = "openai"`), 0o600); err != nil {
		t.Fatal(err)
	}
	_, configured, err := codexWoyaoProvider()
	if err != nil || configured {
		t.Fatalf("configured = %v, err = %v", configured, err)
	}
}

func TestCodexWoyaoProviderUsesCatalogCredentialOverride(t *testing.T) {
	home := t.TempDir()
	t.Setenv("CODEX_HOME", home)
	t.Setenv(codexCatalogAPIKeyEnvOverride, "SHARED_WOYAO_KEY")
	t.Setenv("SHARED_WOYAO_KEY", "shared-secret")
	config := `model_provider = "woyao"
[model_providers.woyao]
base_url = "https://woyao.example.test/v1"
env_key = "WOYAO_API_KEY"
`
	if err := os.WriteFile(filepath.Join(home, "config.toml"), []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	provider, configured, err := codexWoyaoProvider()
	if err != nil || !configured || provider.APIKey != "shared-secret" {
		t.Fatalf("provider = %+v, configured = %v, err = %v", provider, configured, err)
	}
}

func TestDiscoverWoyaoModels(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-key" {
			t.Fatalf("authorization = %q", got)
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"gpt-6.1-sol"},{"id":"claude-fable-5-1"},{"id":"gpt-6.1-sol"}]}`))
	}))
	t.Cleanup(server.Close)

	models, err := discoverWoyaoModels(context.Background(), woyaoProviderConfig{
		BaseURL: server.URL + "/v1",
		APIKey:  "test-key",
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 || models[0].ID != "claude-fable-5-1" || models[1].ID != "gpt-6.1-sol" {
		t.Fatalf("models = %+v", models)
	}
	if models[1].Thinking == nil || len(models[1].Thinking.SupportedLevels) == 0 {
		t.Fatal("known Codex model lost its reasoning catalog")
	}
	if models[0].Thinking != nil {
		t.Fatal("unknown model must not claim an unsupported reasoning catalog")
	}
}
