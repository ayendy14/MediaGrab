#!/bin/sh
# Builds MediaGrab.exe (needs Go 1.24+; works on Windows, macOS or Linux)
cd "$(dirname "$0")/src" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -H windowsgui" -o ../MediaGrab.exe .
