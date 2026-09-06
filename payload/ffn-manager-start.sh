#!/bin/sh
# Start the management server on the RIGHT interface, not on all of them.
#
# The unit used to hardcode `--host 0.0.0.0`, so the WebUI and API answered on
# every interface the chassis had -- data ports included -- and the only thing
# that could have narrowed that was an nftables rule. On the 5220 as found there
# was none: `nft list ruleset` was empty and ffn-bmfw was inactive.
#
# ffn_mgmt_bind.py works out the address. This exists because that computation
# does not belong in an ExecStart= line: systemd does its own $VAR expansion, so
# a `$(...)` there is at best fragile, and the TLS drop-in needs to override the
# command without duplicating the logic. Extra arguments are appended, which is
# how 20-tls.conf adds --ssl-keyfile/--ssl-certfile.
#
# INSTALLED TO /usr/local/sbin, not /opt/ffn-ngfw-v2. That matters: /opt is
# unpacked wholesale from opt-ffn-ngfw-v2.tgz, which the build HARVESTS FROM A
# LIVE BOX, so anything placed there only by this repo would silently not exist
# in an image built from a box that predates it -- and an ExecStart pointing at
# a missing file means no management server at all. /usr/local/sbin is where
# provision.sh installs payload scripts explicitly, so the file is present
# because the image put it there.
#
# NEVER FAILS TO START. If the resolver errors or prints nothing, this falls
# back to 0.0.0.0 and says so. An appliance whose management server refused to
# come up because it could not decide on an address would have no way in at all;
# binding wide is recoverable, being unreachable is not.
set -u

APP_DIR=/opt/ffn-ngfw-v2
PY="$APP_DIR/venv/bin/python3"
UVICORN="$APP_DIR/venv/bin/uvicorn"
PORT="${FFN_MGR_PORT:-8443}"

# Two locations, in this order, for the same reason the wrapper itself lives in
# /usr/local/sbin: /opt is the harvested tarball, so a manager deployed there
# should win when it is newer, but the image's own copy has to be there as a
# floor when the harvest predates this file.
RESOLVER=""
for cand in "$APP_DIR/ffn_mgmt_bind.py" /usr/local/sbin/ffn_mgmt_bind.py; do
	if [ -f "$cand" ]; then RESOLVER="$cand"; break; fi
done

HOST=""
if [ -x "$PY" ] && [ -n "$RESOLVER" ]; then
	# --explain goes to the journal so an operator can see WHICH interfaces were
	# considered and why, including the warning when nothing is enforcing the
	# distinction. Failure here is not fatal; it is diagnostics.
	"$PY" "$RESOLVER" --explain 2>&1 || true
	HOST=$("$PY" "$RESOLVER" 2>/dev/null || echo "")
fi

case "$HOST" in
	"" )
		echo "ffn-manager-start: resolver gave no address, binding 0.0.0.0" >&2
		HOST=0.0.0.0
		;;
	*[!0-9.]* )
		# Anything that is not dotted-quad is not something to hand a listener.
		echo "ffn-manager-start: resolver returned '$HOST', which is not an" \
		     "IPv4 address; binding 0.0.0.0" >&2
		HOST=0.0.0.0
		;;
esac

echo "ffn-manager-start: binding $HOST:$PORT" >&2

exec "$UVICORN" ffn_manager:app \
	--host "$HOST" \
	--port "$PORT" \
	--app-dir "$APP_DIR" \
	--loop asyncio \
	--timeout-keep-alive 30 \
	"$@"
