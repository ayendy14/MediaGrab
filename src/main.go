// MediaGrab launcher: unpacks the embedded script and runs it with Windows' built-in PowerShell.
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

//go:embed MediaGrab.ico
var icon []byte // also built into this exe (rsrc_windows_amd64.syso); the app uses this copy for the tray and its windows

func main() {
	dir := filepath.Join(os.Getenv("LOCALAPPDATA"), "MediaGrab")
	os.MkdirAll(dir, 0o755)
	ps1 := filepath.Join(dir, "MediaGrab.ps1")
	if err := os.WriteFile(ps1, script, 0o644); err != nil {
		return
	}
	os.WriteFile(filepath.Join(dir, "MediaGrab.ico"), icon, 0o644)
	exe, _ := os.Executable()
	cmd := exec.Command("powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", ps1, "-ExePath", exe)
	// No console window (CREATE_NO_WINDOW). Do not also ask for a hidden start: Windows would then
	// hide the first window MediaGrab opens, and the download window would never appear.
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000}
	if cmd.Start() != nil {
		return
	}
	if os.Getenv("MEDIAGRAB_SELFTEST") != "" { // the automatic build check waits for the test result
		if err := cmd.Wait(); err != nil {
			if exit, ok := err.(*exec.ExitError); ok {
				os.Exit(exit.ExitCode())
			}
			os.Exit(1)
		}
	}
}
