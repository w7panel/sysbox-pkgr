package scripts

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"text/template"
)

// Exercise the installer's real heredoc through sh, then render it as K3s does.
// Only the template-writing block runs; no runtime setup or restart is executed.
func TestInnerK3sCNITemplate(t *testing.T) {
	script, err := os.ReadFile("sysbox-inner-k3s.sh")
	if err != nil {
		t.Fatal(err)
	}
	_, block, ok := strings.Cut(string(script), "cat >\"$config_template\" <<EOF\n")
	if !ok {
		t.Fatal("containerd template heredoc not found")
	}
	block, _, ok = strings.Cut(block, "\nEOF\n")
	if !ok {
		t.Fatal("containerd template heredoc terminator not found")
	}
	path := filepath.Join(t.TempDir(), "config-v3.toml.tmpl")
	cmd := exec.Command("sh", "-eu", "-c", `config_template=$1
snapshotter_socket=/run/sysbox/sysbox-snapshotter.sock
pause_image=rancher/mirrored-pause:3.6
bin_dir=/opt/sysbox/bin/generic
cat >"$config_template" <<EOF
`+block+"\nEOF\n", "sh", path)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate template: %v: %s", err, output)
	}
	generated, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	tmpl, err := template.New("containerd").Parse(string(generated))
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, bin, conf string }{
		{"image", "/bin", "/var/lib/rancher/k3s/agent/etc/cni/net.d"},
		{"extracted", "/var/lib/rancher/k3s/data/cni", "/var/lib/rancher/k3s/agent/etc/cni/net.d"},
		{"custom", "/opt/custom cni/bin", "/etc/custom \"cni\"/net.d"},
		{"bin-only", "/bin", ""},
		{"conf-only", "", "/etc/cni/net.d"},
		{"disabled", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var config struct {
				NodeConfig struct {
					AgentConfig struct{ CNIBinDir, CNIConfDir string }
				}
			}
			config.NodeConfig.AgentConfig.CNIBinDir = tc.bin
			config.NodeConfig.AgentConfig.CNIConfDir = tc.conf
			var out bytes.Buffer
			if err := tmpl.Execute(&out, config); err != nil {
				t.Fatal(err)
			}
			got := out.String()
			_, cni, hasCNI := strings.Cut(got, "[plugins.'io.containerd.cri.v1.runtime'.cni]\n")
			if hasCNI != (tc.bin != "" || tc.conf != "") {
				t.Fatalf("unexpected CNI section presence: %v", hasCNI)
			}
			cni, _, _ = strings.Cut(cni, "\n[plugins.")
			var want []string
			if tc.bin != "" {
				want = append(want, "bin_dirs = ["+strconv.Quote(tc.bin)+"]")
			}
			if tc.conf != "" {
				want = append(want, "conf_dir = "+strconv.Quote(tc.conf))
			}
			if strings.Join(strings.Fields(cni), " ") != strings.Join(strings.Fields(strings.Join(want, "\n")), " ") {
				t.Fatalf("CNI config = %q, want %q", cni, want)
			}
			for _, preserved := range []string{
				`address = "/run/sysbox/sysbox-snapshotter.sock"`,
				`[plugins.'io.containerd.cri.v1.images'.runtime_platforms.sysbox-runc-lite]`,
				`BinaryName = "/opt/sysbox/bin/generic/sysbox-runc-lite"`,
			} {
				if !strings.Contains(got, preserved) {
					t.Errorf("missing runtime config: %s", preserved)
				}
			}
		})
	}
}
