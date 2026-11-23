// MediaGrab launcher: unpacks the embedded script and runs it with Windows' built-in PowerShell, hidden.
package main

import (
	_ "embed"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

//go:embed MediaGrab.ps1
var script []byte

func main() {
	dir := filepath.Join(os.Getenv("LOCALAPPDATA"), "MediaGrab")
	os.MkdirAll(dir, 0o755)
	ps1 := filepath.Join(dir, "MediaGrab.ps1")
	if err := os.WriteFile(ps1, script, 0o644); err != nil {
		return
	}
	exe, _ := os.Executable()
	cmd := exec.Command("powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", ps1, "-ExePath", exe)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	cmd.Start()
}
