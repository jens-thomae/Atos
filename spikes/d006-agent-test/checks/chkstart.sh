#!/bin/bash
# chkstart.sh <iced|slint> <n>: fresh fixture, desktop, app running on small
t=$1; n=$t$2; B=$HOME/agent-test
cp $B/target-$t/release/d006-$t $B/$n/bin 2>/dev/null || true
rm -rf $B/chk; sh $B/tools/../$n/../tools/make-fixture.sh $B/chk >/dev/null
$B/tools/start-desktop.sh >/dev/null; source $B/tools/desktop.env
pkill -f 'wtype -s 600000'; setsid wtype -s 600000 -k Shift_L >/dev/null 2>&1 &
setsid $B/$n/bin $B/chk/small >/tmp/chk-app.log 2>&1 &
sleep 5; grim /tmp/c0.png; (cd $B/chk/small && ls)
