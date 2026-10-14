package config

import (
	"os"
	"path/filepath"
	"testing"
)

// Overlay this test into the exact staged Node source. It consumes Installer
// output with the production parser; it starts no network or kernel services.
func TestInstallerNativeAuthorizationConsumer(t *testing.T) {
	root := os.Getenv("TXNODE_INSTALLER_FIXTURE_DIR")
	if root == "" { t.Skip("requires explicit installer fixture directory") }
	for _, name := range []string{"single", "multi"} {
		loaded, err := LoadRoot(filepath.Join(root, name, "config.yml"))
		if err != nil { t.Fatal(name, err) }
		instances, err := loaded.NormalizeInstances()
		if err != nil { t.Fatal(name, err) }
		if len(instances) != map[string]int{"single":1,"multi":2}[name] { t.Fatal("unexpected instances", name) }
		for _, instance := range instances {
			a := instance.Authorization
			if !a.Enabled || a.CoreInstanceID != "core-example-01" || a.KeyID != "core-key-1" || a.KeyEpoch != "1" || a.PublicKey != "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" || a.PolicyVersion != NativeAuthorizationPolicyVersion || a.RefreshInterval != 30 { t.Fatal("installer lost explicit trust", name) }
			if a.StateDir != filepath.Join(instance.Kernel.ConfigDir,"authorization") { t.Fatal("authorization state did not follow instance persistent root", a.StateDir) }
		}
		if len(instances)==2 && instances[0].Authorization.StateDir==instances[1].Authorization.StateDir { t.Fatal("different panel targets share revision state") }
	}
}
