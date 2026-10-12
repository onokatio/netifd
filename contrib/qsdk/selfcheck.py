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

    native = pathlib.Path(temp) / 'native-wifi'
    native.write_text('''
wifi_updown() {
    config_load wireless || exit 20
    [ "$wifi1_disabled" = 1 ] && [ "$wifi2_disabled" = 0 ] || exit 21
    config_load wireless || exit 22
    [ "$wifi1_disabled" = 1 ] && [ "$wifi2_disabled" = 0 ] || exit 23
    ! config_load missing || exit 24
}
''')
    harness = source.replace('/rom/sbin/wifi', str(native)) + '''
qca_down_devices() { echo wifi1; }
config_set() { eval "$1_$2=$3"; }
uci_load() {
    [ "$1" != missing ] || return 1
    config_set wifi1 disabled 0
    config_set wifi2 disabled 0
}
qca_native up
'''
    subprocess.run(['sh'], input=harness, text=True, check=True, timeout=5)
print('QSDK lifecycle selfcheck passed: coalesced reload, runtime stop/start, disabled radio'
      + ', native configuration reload mask'
      + (', kernel mutex and forced cancellation' if flock else ''))

extra_test = source + r"""
config_get() {
 case "$3" in
  wmm) value=0;;
  max_inactivity) value=120;;
  *) value=;;
 esac
}
expected='wmm_enabled=0
ap_max_inactivity=120'
[ "$(qca_hostapd_extra vif)" = "$expected" ] || exit 21
config_get() { value='1
ssid=injected'; }
qca_hostapd_extra vif && exit 22
exit 0
"""
subprocess.run(['sh', '-c', extra_test], check=True)
print('QSDK hostapd option selfcheck passed: translation and invalid line rejection')
