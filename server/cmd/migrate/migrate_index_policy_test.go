package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Historical SQL is immutable. Migration 133 is the last existing migration
// with a non-concurrent explicit index build; never rebuild a healthy index
// merely to change how its historical CREATE statement was executed.
func TestMigrationIndexPolicy(t *testing.T) {
	paths, err := filepath.Glob("../../migrations/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	create := regexp.MustCompile(`(?i)CREATE\s+(?:UNIQUE\s+)?INDEX\s+(CONCURRENTLY\s+)?`)
	comments := regexp.MustCompile(`(?m)--[^\n]*`)
	for _, path := range paths {
		name := filepath.Base(path)
		version, err := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if err != nil {
			t.Fatal(err)
		}
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		sql := comments.ReplaceAllString(string(body), "")
		builds := create.FindAllStringSubmatch(sql, -1)
		for _, build := range builds {
			if version > 133 && build[1] == "" {
				t.Errorf("%s: new index must use CONCURRENTLY", name)
			}
		}
		// Enforce the current single-statement contract on all future additions,
		// including rollback files, without rewriting applied migrations.
		if version > 563 && len(builds) > 0 {
			statements := 0
			for _, part := range strings.Split(sql, ";") {
				if strings.TrimSpace(part) != "" {
					statements++
				}
			}
			if len(builds) != 1 || statements != 1 {
				t.Errorf("%s: each concurrent index needs one single-statement migration", name)
			}
		}
	}
}
