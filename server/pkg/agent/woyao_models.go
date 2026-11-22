package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/pelletier/go-toml/v2"
)

type woyaoProviderConfig struct {
	BaseURL string
	APIKey  string
}

type codexProviderConfig struct {
	ModelProvider  string `toml:"model_provider"`
	ModelProviders map[string]struct {
		BaseURL string `toml:"base_url"`
		EnvKey  string `toml:"env_key"`
	} `toml:"model_providers"`
}

const codexCatalogAPIKeyEnvOverride = "MULTICA_CODEX_MODEL_CATALOG_API_KEY_ENV"

// codexWoyaoProvider reports whether the host Codex configuration uses the
// named woyao provider. The API key remains in the process environment; it is
// never returned by Multica's model-list endpoint or written to its cache.
func codexWoyaoProvider() (woyaoProviderConfig, bool, error) {
	home := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil {
			return woyaoProviderConfig{}, false, nil
		}
		home = filepath.Join(userHome, ".codex")
	}
	data, err := os.ReadFile(filepath.Join(home, "config.toml"))
	if os.IsNotExist(err) {
		return woyaoProviderConfig{}, false, nil
	}
	if err != nil {
		return woyaoProviderConfig{}, false, fmt.Errorf("read Codex config for model discovery: %w", err)
	}
	var cfg codexProviderConfig
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return woyaoProviderConfig{}, false, fmt.Errorf("parse Codex config for model discovery: %w", err)
	}
	if !strings.EqualFold(strings.TrimSpace(cfg.ModelProvider), "woyao") {
		return woyaoProviderConfig{}, false, nil
	}
	provider, ok := cfg.ModelProviders[cfg.ModelProvider]
	if !ok {
		return woyaoProviderConfig{}, false, fmt.Errorf("Codex woyao provider is not defined")
	}
	baseURL := strings.TrimRight(strings.TrimSpace(provider.BaseURL), "/")
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return woyaoProviderConfig{}, false, fmt.Errorf("Codex woyao provider has an invalid base URL")
	}
	envKey := strings.TrimSpace(provider.EnvKey)
	catalogEnvKey := strings.TrimSpace(os.Getenv(codexCatalogAPIKeyEnvOverride))
	if catalogEnvKey == "" {
		catalogEnvKey = envKey
	}
	apiKey := strings.TrimSpace(os.Getenv(catalogEnvKey))
	if catalogEnvKey == "" || apiKey == "" {
		return woyaoProviderConfig{}, false, fmt.Errorf("Codex woyao provider credential is unavailable")
	}
	return woyaoProviderConfig{BaseURL: baseURL, APIKey: apiKey}, true, nil
}

type openAICompatibleModelsResponse struct {
	Data []struct {
		ID string `json:"id"`
	} `json:"data"`
}

func discoverWoyaoModels(ctx context.Context, provider woyaoProviderConfig) ([]Model, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, provider.BaseURL+"/models", nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+provider.APIKey)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("query woyao model catalog: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("query woyao model catalog: HTTP %d", resp.StatusCode)
	}
	var payload openAICompatibleModelsResponse
	decoder := json.NewDecoder(io.LimitReader(resp.Body, 4<<20))
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode woyao model catalog: %w", err)
	}
	thinking := make(map[string]*ModelThinking)
	for _, model := range codexStaticModels() {
		thinking[model.ID] = model.Thinking
	}
	seen := make(map[string]struct{}, len(payload.Data))
	models := make([]Model, 0, len(payload.Data))
	for _, raw := range payload.Data {
		id := strings.TrimSpace(raw.ID)
		if id == "" {
			continue
		}
		if _, exists := seen[id]; exists {
			continue
		}
		seen[id] = struct{}{}
		models = append(models, Model{ID: id, Label: id, Provider: "woyao", Thinking: thinking[id]})
	}
	if len(models) == 0 {
		return nil, fmt.Errorf("woyao returned an empty model catalog")
	}
	sort.Slice(models, func(i, j int) bool { return models[i].ID < models[j].ID })
	return models, nil
}
