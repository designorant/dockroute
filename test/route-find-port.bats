#!/usr/bin/env bats
# Tests for `dockroute route add --find-port`
#
# Requires: bats-core (brew install bats-core)
# Run: bats test/

DOCKROUTE="${BATS_TEST_DIRNAME}/../bin/dockroute"

setup() {
	# Remove any leftover test routes
	"$DOCKROUTE" route remove test-fp.localhost 2>/dev/null || true
}

teardown() {
	"$DOCKROUTE" route remove test-fp.localhost 2>/dev/null || true
}

@test "--find-port uses given port when free" {
	# Pick a high port unlikely to be in use
	port=$("$DOCKROUTE" route add test-fp.localhost 19876 --find-port)
	[[ "$port" == "19876" ]]
}

@test "--find-port skips busy ports" {
	# Bind a port with nc, then ask --find-port to start from it
	nc -l 19877 &
	NC_PID=$!
	sleep 0.2

	port=$("$DOCKROUTE" route add test-fp.localhost 19877 --find-port)
	kill "$NC_PID" 2>/dev/null || true
	wait "$NC_PID" 2>/dev/null || true

	# Should have picked 19878 or higher, not 19877
	[[ "$port" -gt 19877 ]]
}

@test "--find-port stdout contains only the port number" {
	output=$("$DOCKROUTE" route add test-fp.localhost 19876 --find-port)
	# Should be a bare number, no ANSI codes or extra text
	[[ "$output" =~ ^[0-9]+$ ]]
}

@test "--find-port stderr contains status message" {
	stderr=$("$DOCKROUTE" route add test-fp.localhost 19876 --find-port 2>&1 1>/dev/null)
	[[ "$stderr" == *"Route"* ]]
}

@test "--find-port idempotent re-run returns same port" {
	port1=$("$DOCKROUTE" route add test-fp.localhost 19876 --find-port)
	port2=$("$DOCKROUTE" route add test-fp.localhost 19876 --find-port)
	[[ "$port1" == "$port2" ]]
}

@test "route add without --find-port does not print port to stdout" {
	output=$("$DOCKROUTE" route add test-fp.localhost 19876 2>/dev/null)
	# Should NOT contain a bare port number (may contain status text)
	! [[ "$output" =~ ^[0-9]+$ ]]
}
