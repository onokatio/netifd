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
json_select() { :; }
json_get_var() { eval "$1="; }
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
config_foreach() { :; }
config_set() { eval "$1_$2=$3"; }
uci_load() {
    [ "$1" != missing ] || return 1
    config_set wifi1 disabled 0
    config_set wifi2 disabled 0
}
qca_native up
'''
    subprocess.run(['sh'], input=harness, text=True, check=True, timeout=5)
    harness = source + r'''
config_get() { eval "$1=\"\${cfg_${2}_${3}-$4}\""; }
config_foreach() { "$1" link1; "$1" link2; }
cfg_wifi0_type=qcawificfg80211
cfg_wifi0_hwmode=11beg
cfg_wifi1_type=qcawificfg80211
cfg_wifi1_hwmode=11bea
cfg_mld3_TYPE=wifi-mld
cfg_link1_device=wifi0
cfg_link2_device=wifi1
cfg_link1_mld=mld3
cfg_link2_mld=mld3
cfg_link1_mode=sta
cfg_link2_mode=sta
cfg_link1_ssid=test
cfg_link2_ssid=test
qca_validate_mlo || exit 80
cfg_link2_mode=ap
! qca_validate_mlo || exit 81
cfg_link2_mode=sta
cfg_link2_device=wifi0
! qca_validate_mlo || exit 82
cfg_link2_device=wifi1
cfg_wifi1_hwmode=11axa
! qca_validate_mlo || exit 83
cfg_wifi1_hwmode=11bea
cfg_link2_mld=mld3/invalid
! qca_validate_mlo || exit 84
cfg_link2_disabled=1
qca_validate_mlo || exit 85
'''
    subprocess.run(['sh'], input=harness, text=True, check=True, timeout=5, stderr=subprocess.DEVNULL)
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

with tempfile.TemporaryDirectory() as temp:
    pathlib.Path(temp, 'ath-test').mkdir()
    fixture_source = source.replace('/sys/class/net', temp).replace('/var/run/', temp + '/').replace('/etc/luci-qsdk', temp)
    harness = fixture_source + r'''
config_get() { eval "$1=\"\${fixture_$3-}\""; }
config_list_foreach() { "$3" one.example; "$3" two.example; }
json_select() { :; }
json_get_vars() { for name do eval "$name=\"\${fixture_$name-}\""; done; }
cfg80211tool() { printf '%s\n' "$*" >> "$calls"; }
iw() { printf '%s\n' "$*" >> "$calls"; }
wireless_add_vif() { printf '%s\n' "$*" >> "$published"; }
wireless_setup_vif_failed() { exit 30; }
fixture_ifname=ath-test
fixture_shpreamble=0
qca_publish_vif vif
[ "$(cat "$calls")" = 'ath-test shpreamble 0
ath-test set txpower fixed 0' ] || exit 31
[ "$(cat "$published")" = 'vif ath-test' ] || exit 32
: > "$calls"
qca_txpower=10
qca_publish_vif vif
[ "$(cat "$calls")" = 'ath-test shpreamble 0
ath-test set txpower fixed 10' ] || exit 33
: > "$calls"
fixture_mode=ap
qca_legacy_rates=1
qca_noscan=0
qca_publish_vif vif
[ "$(cat "$calls")" = 'ath-test shpreamble 0
ath-test maccmd 0
ath-test pureg 0
ath-test disablecoext 0
ath-test set txpower fixed 10' ] || exit 41
: > "$calls"
fixture_macfilter=allow
qca_publish_vif vif
grep -q '^ath-test maccmd 0$' "$calls" || exit 47
fixture_shpreamble=
fixture_ssid='quoted "SSID"'
fixture_key='quoted"key\here'
fixture_bssid=02:00:00:00:00:01
fixture_domain_match=present
fixture_identity='quoted"identity\here'
file="$fixture_root/wpa_supplicant-ath-test.conf"
printf 'network={\nssid="old"\npsk="old"\nbssid=02:00:00:00:00:ff\n}\n' > "$file"
qca_prepare_supplicant vif "$file" || exit 34
grep -q 'ssid=71756f74656420225353494422' "$file" || exit 35
grep -Fq 'psk="quoted\"key\\here"' "$file" || exit 36
grep -q '^.bssid=02:00:00:00:00:01$' "$file" || exit 37
grep -q '^domain_match="one.example;two.example"$' "$file" || exit 38
grep -Fq 'identity="quoted\"identity\\here"' "$file" || exit 56
fixture_bssid='invalid;command'
cp "$file" "$file.before"
qca_prepare_supplicant vif "$file" && exit 39
cmp "$file" "$file.before" || exit 40
fixture_bssid=02:00:00:00:00:01
fixture_encryption=wpa2+ccmp
fixture_eap_type=PEAP
fixture_auth=EAP-MSCHAPV2
qca_prepare_supplicant vif "$file" || exit 57
grep -q '^phase2="auth=MSCHAPV2"$' "$file" || exit 58
grep -q '^eap=PEAP$' "$file" || exit 59
grep -q '^proto=RSN$' "$file" || exit 60
fixture_eap_type=ttls
fixture_auth=EAP-TLS
qca_prepare_supplicant vif "$file" || exit 61
grep -q '^phase2="autheap=TLS"$' "$file" || exit 62
fixture_auth=PAP
qca_prepare_supplicant vif "$file" || exit 63
grep -q '^phase2="auth=PAP"$' "$file" || exit 64
fixture_eap_type=FAST
fixture_auth=EAP-GTC
fixture_fast_provisioning=0
fixture_pac_file='pac"path\here'
qca_prepare_supplicant vif "$file" || exit 65
grep -q '^phase1="fast_provisioning=0"$' "$file" || exit 66
grep -q '^phase2="auth=GTC"$' "$file" || exit 67
grep -Fq 'pac_file="pac\"path\\here"' "$file" || exit 68
fixture_eap_type=TLS
qca_prepare_supplicant vif "$file" || exit 69
! grep -q '^phase[12]=' "$file" || exit 70
for invalid_case in method auth provisioning; do
 fixture_eap_type=FAST
 fixture_auth=EAP-GTC
 fixture_fast_provisioning=0
 case "$invalid_case" in method) fixture_eap_type=UNKNOWN;; auth) fixture_auth='PAP"injected';; provisioning) fixture_fast_provisioning=4;; esac
 cp "$file" "$file.before"
 qca_prepare_supplicant vif "$file" && exit 71
 cmp "$file" "$file.before" || exit 72
done
fixture_encryption=
fixture_macfilter=deny
fixture_maclist='02:00:00:00:00:01 02:00:00:00:00:02'
file="$fixture_root/hostapd-ath-test.conf"
printf 'ssid=test\n' > "$file"
qca_prepare_hostapd vif "$file" || exit 42
grep -q '^macaddr_acl=0$' "$file" || exit 43
[ "$(wc -l < "$fixture_root/maclist-ath-test")" -eq 2 ] || exit 44
cp "$file" "$file.before"
fixture_maclist='02:00:00:00:00:01;injected'
qca_prepare_hostapd vif "$file" && exit 45
cmp "$file" "$file.before" || exit 46
mkdir "$fixture_root/uci"
uci() {
 shift
 case "$1" in
  show)
   echo wireless.vif=wifi-iface
   for field in "$fixture_root"/uci/*; do printf "wireless.vif.%s='%s'\n" "${field##*/}" "$(cat "$field")"; done;;
  get) cat "$fixture_root/uci/${2##*.}" 2>/dev/null;;
  set) key="${2%%=*}"; printf '%s' "${2#*=}" > "$fixture_root/uci/${key##*.}";;
  delete) rm "$fixture_root/uci/${2##*.}";;
  commit) :;;
  *) exit 48;;
 esac
}
for item in mode:ap device:wifi0 type:qcawificfg80211 ifname:ath06 macfilter:allow; do
 printf '%s' "${item#*:}" > "$fixture_root/uci/${item%%:*}"
done
qca_sync_mac_config || exit 49
[ "$(cat "$fixture_root/uci/macaddr_acl")" = 1 ] || exit 50
[ "$(cat "$fixture_root/uci/accept_mac_file")" = "$fixture_root/maclist-ath06" ] || exit 51
touch "$fixture_root/maclist-ath06" "$fixture_root/maclist-ath07" "$fixture_root/maclist-ath06.backup"
qca_cleanup_maclists
[ -f "$fixture_root/maclist-ath06" ] && [ ! -f "$fixture_root/maclist-ath07" ] || exit 52
: > "$fixture_root/uci/macfilter"
qca_sync_mac_config || exit 53
[ "$(cat "$fixture_root/uci/macaddr_acl")" = 0 ] && [ ! -f "$fixture_root/uci/accept_mac_file" ] || exit 54
qca_cleanup_maclists
[ ! -f "$fixture_root/maclist-ath06" ] && [ -f "$fixture_root/maclist-ath06.backup" ] || exit 55
'''
    subprocess.run(['sh'], input=harness, text=True, check=True, timeout=5,
                   env={'PATH': '/usr/bin:/bin', 'calls': temp + '/calls',
                        'published': temp + '/published', 'fixture_root': temp})
print('QSDK VIF/authenticator selfcheck passed: power reset, preamble, coexistence, escaped key, BSSID, TLS and ACL validation')
