#! /usr/bin/env expect -f

source [file join [file dirname $argv0] common.tcl]

# This test ensures that the memory monitor does its main job, namely
# prevent the server from dying because of lack of memory when a
# client runs a "large" query.
# To test this 4 steps are needed:
# 1. a baseline memory usage is measured;
# 2. memory is limited using 'ulimit', and the server restarted with
#    that limit;
# 3. a first test ensure that the server does indeed crash when memory
#    consumption is not limited by a monitor;
# 4. the monitor is configured with a limit and a 2nd test ensures
#    that the server does not crash any more.
# Note that step 3 is needed so as to ensure that the mechanism used
# in step 4 does indeed push memory consumption past the limit.

# Set up the initial cluster.
start_server $argv
stop_server $argv

# Start the cluster anew. This ensures fresh memory state.
start_server $argv

# Make some initial request to check the data is there and define the
# baseline memory consumption.
system "echo 'select * from information_schema.columns;' | $argv sql >/dev/null"

# What memory is currently consumed by the server?
set vmem [ exec ps --no-headers o vsz -p [ exec cat server_pid ] ]

# Now play. First, shut down the running server.
stop_server $argv

# Spawn a shell, so we get access to 'ulimit'.
spawn /bin/bash
set shell_spawn_id $spawn_id
send "PS1=':''/# '\r"
eexpect ":/# "

# Set the max memory usage to the baseline plus some margin.
send "ulimit -v [ expr {2*$vmem+400} ]\r"
eexpect ":/# "

# Start a server with this limit set. The server will now run in the foreground.
send "$argv start --insecure --no-redirect-stderr\r"
eexpect "restarted pre-existing node"
sleep 1

# Spawn a client.
spawn $argv sql
set client_spawn_id $spawn_id
eexpect root@

# Test the client is sane.
send "select 1;\r"
eexpect "1 row"
eexpect root@

# Now try to run a large-ish query on the client.
# The query is a 4-way cross-join on information_schema.columns,
# resulting in ~8 million rows loaded into memory when run on an
# empty database.
send "set database=information_schema;\r"
eexpect root@
send "select * from columns as a, columns as b, columns as c, columns as d limit 10;\r"

# Check that the query crashed the server
set spawn_id $shell_spawn_id
# Error is either "out of memory" (Go) or "cannot allocate memory" (C++)
expect {
    "out of memory" {}
    "cannot allocate memory" {}
    "std::bad_alloc" {}
    timeout {exit 1}
}
eexpect ":/# "

# Check that the client got a bad connection error
set spawn_id $client_spawn_id
eexpect "bad connection"
eexpect root@

# Re-launch a server with relatively lower limit for SQL memory
set spawn_id $shell_spawn_id
send "$argv start --insecure --max-sql-memory=150K --no-redirect-stderr\r"
eexpect "restarted pre-existing node"
sleep 2

# Now try the large query again.
set spawn_id $client_spawn_id
send "select 1;\r"
eexpect root@
send "set database=information_schema;\r"
eexpect root@
send "select * from columns as a, columns as b, columns as c, columns as d limit 10;\r"
eexpect "memory budget exceeded"
eexpect root@

# Check we can send another query without error -- the server has survived.
send "select 1;\r"
eexpect "1 row"
eexpect root@

# We just terminate, this will kill both server and client.
