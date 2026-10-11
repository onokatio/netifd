#!/usr/bin/env python3
"""Exercise the backend lifecycle without controlling any hardware."""
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = (root / 'examples/wireless/qcawificfg80211.sh').read_text()
source = '\n'.join(line for line in source.splitlines()
                   if not line.startswith(('. /lib/', 'init_wireless_driver ', 'add_driver ')))
with tempfile.TemporaryDirectory() as temp:
    source = source.replace('/tmp/qsdk-netifd', temp).replace('/var/run/qsdk-netifd.lock', temp + '/lock')
    flock = shutil.which('flock')
    mutex = 'busybox() { shift; command flock "$@"; }\n' if flock else 'busybox() { :; }\n'
    harness = source + mutex + '''
ubus() { echo status; }
jsonfilter() { echo "$autostart_test"; }
uci() { echo "$disabled_test"; }
qca_native() { sleep 0.1; echo "$1" >> "$calls"; }
qca_restart_partners() { echo partners >> "$calls"; }
qca_generation() { echo "$revision"; }
for_each_interface() { :; }
wireless_set_up() { echo up >> "$published"; }
wireless_setup_failed() { echo "$1" >&2; exit 1; }
revision=first
autostart_test=true
disabled_test=0
drv_qcawificfg80211_setup wifi1
drv_qcawificfg80211_setup wifi2
[ "$(wc -l < "$calls")" -eq 1 ] || exit 10
drv_qcawificfg80211_teardown wifi1
[ "$(wc -l < "$calls")" -eq 1 ] || exit 11
revision=changed
drv_qcawificfg80211_setup wifi1
[ "$(wc -l < "$calls")" -eq 2 ] || exit 12
autostart_test=false
drv_qcawificfg80211_teardown wifi2
[ "$(tail -2 "$calls" | head -1)" = down ] && [ "$(tail -1 "$calls")" = partners ] || exit 13
drv_qcawificfg80211_setup wifi2
[ "$(tail -1 "$calls")" = up ] || exit 14
autostart_test=true
disabled_test=1
drv_qcawificfg80211_teardown wifi1
[ "$(tail -2 "$calls" | head -1)" = down ] && [ "$(tail -1 "$calls")" = partners ] || exit 15
'''
    if flock:
        harness += f'''
rm -f "$calls" "{temp}/generation"
revision=parallel
(drv_qcawificfg80211_setup wifi1) & first=$!
(drv_qcawificfg80211_setup wifi2) & second=$!
wait "$first" && wait "$second" || exit 16
[ "$(wc -l < "$calls")" -eq 1 ] || exit 17
(qca_lock; touch "$published.locked"; exec sleep 30) & owner=$!
while [ ! -f "$published.locked" ]; do sleep 0.1; done
kill -9 "$owner"
wait "$owner" 2>/dev/null || :
qca_lock && qca_unlock || exit 18
'''
    result = subprocess.run(['sh'], input=harness, text=True, timeout=15,
                            env={'PATH': '/usr/bin:/bin', 'calls': temp + '/calls', 'published': temp + '/published'})
    assert result.returncode == 0, f'Lifecycle selfcheck failed: {result.returncode}'
print('QSDK lifecycle selfcheck passed: coalesced reload, runtime stop/start, disabled radio'
      + (', kernel mutex and forced cancellation' if flock else ''))
