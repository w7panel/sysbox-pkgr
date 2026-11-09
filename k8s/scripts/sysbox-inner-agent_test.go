package scripts

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Run the real in-node probe against live and stale Unix sockets. Stub only
// the clients, checking that snapshots RPC bypasses containerd metadata.
func TestInnerAgentHealth(t *testing.T) {
	script, err := os.ReadFile("sysbox-inner-agent.sh")
	if err != nil {
		t.Fatal(err)
	}
	_, probe, ok := strings.Cut(string(script), "in_node /bin/sh -ec '")
	if !ok {
		t.Fatal("status probe not found")
	}
	probe, _, ok = strings.Cut(probe, "\n  ' >/dev/null 2>&1")
	if !ok {
		t.Fatal("status probe terminator not found")
	}
	launcher, err := os.ReadFile("sysbox-inner-k3s.sh")
	if err != nil {
		t.Fatal(err)
	}
	launcherProbe := `runtime_shell() { program=$1; shift; sh -ec "$program" sh "$@"; }
run_in_runtime_ns() { "$@"; }
snapshotter_socket=$EXPECT_SOCKET
`
	for _, name := range []string{"socket_is_live", "snapshotter_is_live"} {
		_, body, ok := strings.Cut(string(launcher), name+"() {\n")
		if !ok {
			t.Fatalf("missing %s", name)
		}
		body, _, ok = strings.Cut(body, "\n}\n")
		if !ok {
			t.Fatalf("missing end of %s", name)
		}
		launcherProbe += name + "() {\n" + body + "\n}\n"
	}
	launcherProbe += "snapshotter_is_live\n"
	for _, tc := range []struct {
		name                        string
		listen, stale, rpc, runtime bool
		healthy                     bool
	}{
		{name: "absent"},
		{name: "stale", listen: true, stale: true, rpc: true, runtime: true},
		{name: "stale-prefix", listen: true, stale: true, rpc: true, runtime: true},
		{name: "rpc-failure", listen: true, runtime: true},
		{name: "empty-store", listen: true, rpc: true, runtime: true, healthy: true},
		{name: "transport-failure", listen: true, runtime: true},
		{name: "other-not-found", listen: true, runtime: true},
		{name: "missing-handler", listen: true, rpc: true},
		{name: "healthy", listen: true, rpc: true, runtime: true, healthy: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			socket := filepath.Join(dir, "snapshotter.sock")
			if tc.listen {
				listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
				if err != nil {
					t.Fatal(err)
				}
				listener.SetUnlinkOnClose(false)
				defer listener.Close()
				if tc.stale {
					listener.Close()
				}
			}
			if tc.name == "stale-prefix" {
				listener, err := net.Listen("unix", socket+".old")
				if err != nil {
					t.Fatal(err)
				}
				defer listener.Close()
			}
			ctr := filepath.Join(dir, "ctr")
			ctrScript := "#!/bin/sh\n" +
				`[ "$*" = "--address $EXPECT_SOCKET --timeout 3s snapshots ls" ] || exit 2` + "\n"
			switch tc.name {
			case "empty-store":
				ctrScript += "echo 'warning: unknown service containerd.services.introspection.v1.Introspection' >&2\necho 'ctr: bucket does not exist: not found' >&2\nexit 1\n"
			case "transport-failure":
				ctrScript += "echo 'ctr: connection error: dial unix snapshotter.sock: connect: connection refused' >&2\nexit 1\n"
			case "other-not-found":
				ctrScript += "echo 'ctr: snapshot does not exist: not found' >&2\nexit 1\n"
			default:
				if tc.rpc {
					ctrScript += "exit 0\n"
				} else {
					ctrScript += "exit 1\n"
				}
			}
			if err := os.WriteFile(ctr, []byte(ctrScript), 0755); err != nil {
				t.Fatal(err)
			}
			crictl := filepath.Join(dir, "crictl")
			criScript := "#!/bin/sh\necho runc\n"
			if tc.runtime {
				criScript += "echo sysbox-runc-lite\n"
			}
			if err := os.WriteFile(crictl, []byte(criScript), 0755); err != nil {
				t.Fatal(err)
			}
			actual := strings.NewReplacer("/run/sysbox/sysbox-snapshotter.sock", socket,
				"/bin/ctr ", ctr+" ", "/bin/crictl ", crictl+" ").Replace(probe)
			cmd := exec.Command("sh", "-c", "sh -ec '"+actual+"'")
			cmd.Env = append(os.Environ(), "EXPECT_SOCKET="+socket)
			output, err := cmd.CombinedOutput()
			if (err == nil) != tc.healthy {
				t.Fatalf("healthy=%v want=%v: %v %s", err == nil, tc.healthy, err, output)
			}
			actual = strings.ReplaceAll(launcherProbe, "/proc/1/root/bin/ctr", ctr)
			cmd = exec.Command("sh", "-ec", actual)
			cmd.Env = append(os.Environ(), "EXPECT_SOCKET="+socket)
			output, err = cmd.CombinedOutput()
			want := tc.listen && !tc.stale && tc.rpc
			if (err == nil) != want {
				t.Fatalf("launcher healthy=%v want=%v: %v %s", err == nil, want, err, output)
			}
		})
	}
}
