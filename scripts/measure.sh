#!/bin/zsh
# Measures MacPulse CPU time and footprint with the popover open on a given tab.
# Usage: scripts/measure.sh <tab> <seconds>
set -u
TAB=${1:-overview}; SECS=${2:-40}
cd "$(dirname "$0")/.."
pkill -f 'build/MacPulse.app/Contents/MacOS/MacPulse$' 2>/dev/null
MACPULSE_OPEN=$TAB build/MacPulse.app/Contents/MacOS/MacPulse >/dev/null 2>&1 &
sleep 12   # warm-up: first samples, popover open
P=$(pgrep -f 'build/MacPulse.app/Contents/MacOS/MacPulse$')
cpu() { ps -o time= -p $P | awk -F'[:.]' '{print ($1*60+$2)+$3/100}'; }
W0=$(/private/tmp/claude-501/wins $P); T0=$(cpu); sleep $SECS; T1=$(cpu); W1=$(/private/tmp/claude-501/wins $P)
FP=$(footprint -p $P 2>/dev/null | awk '/phys_footprint:/{print $2,$3}')
echo "[$W0/$W1] $TAB: CPU $(echo "scale=2; ($T1-$T0)*100/$SECS" | bc)% avg over ${SECS}s, footprint $FP"
kill $P
