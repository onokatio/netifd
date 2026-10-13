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
pristine = source
with tempfile.TemporaryDirectory() as temp:
    source = source.replace('/tmp/qsdk-netifd', temp).replace('/var/run/qsdk-netifd.lock', temp + '/lock')
    flock = shutil.which('flock')
    mutex = 'busybox() { shift; command flock "$@"; }\n' if flock else 'busybox() { :; }\n'
    harness = source + mutex + '''
ubus() { echo status; }
jsonfilter() { case "$*" in *retry_setup_failed*) echo "$retry_failed_test";; *) echo "$autostart_test";; esac; }
uci() { echo "$disabled_test"; }
json_select() { :; }
json_get_var() { eval "$1="; }
qca_native() { sleep 0.1; echo "$1" >> "$calls"; }
qca_restart_partners() { echo partners >> "$calls"; }
qca_apply_distances() { :; }
config_load() { :; }
qca_validate_controls() { :; }
qca_validate_airtime_totals() { :; }
qca_sync_atf_config() { :; }
qca_generation() { echo "$revision"; }
for_each_interface() { :; }
wireless_set_up() { echo up >> "$published"; }
wireless_setup_failed() { echo "$1" >&2; exit 1; }
revision=first
autostart_test=true
disabled_test=0
retry_failed_test=false
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
qca_apply_distances() { return 1; }
wireless_setup_failed() { echo "$1" >> "$published"; }
revision=failed
! drv_qcawificfg80211_setup wifi1 || exit 19
[ "$(tail -1 "$calls")" = down ] || exit 20
[ "$(tail -1 "$published")" = DISTANCE_CONFIGURATION_FAILED ] || exit 21
qca_apply_distances() { :; }
retry_failed_test=true
disabled_test=0
qca_configure_distance() { return 1; }
! drv_qcawificfg80211_teardown wifi1 || exit 22
[ "$(tail -2 "$calls" | head -1)" = down ] && [ "$(tail -1 "$calls")" = partners ] || exit 23
qca_configure_distance() { :; }
retry_failed_test=false
for_each_interface() { qca_failed=1; }
revision=publication-failed
! drv_qcawificfg80211_setup wifi1 || exit 24
[ ! -e "${calls%/*}/generation" ] || exit 25
for_each_interface() { :; }
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

    harness = source + '''
cfg80211tool() {
    case "$2" in
        get_acktimeout)
            [ "$read_failure" != 1 ] || return 1
            printf '%s\\tget_acktimeout:%s\\n' "$1" "$(cat "$ack_probe_dir/$1")";;
        acktimeout)
            echo "$1 $3" >> "$ack_probe_dir/writes"
            [ "$write_failure" != 1 ] || return 1
            [ "$read_mismatch" = 1 ] || echo "$3" > "$ack_probe_dir/$1";;
        *) exit 40;;
    esac
}
echo 112 > "$ack_probe_dir/wifi1"
echo 120 > "$ack_probe_dir/wifi2"
qca_configure_distance wifi1 '' && qca_configure_distance wifi1 0 || exit 41
[ ! -f "$ack_probe_dir/writes" ] || exit 42
for invalid in auto -1 1.5 21151 99999999999999999999; do
    ! qca_configure_distance wifi1 "$invalid" || exit 43
done
! qca_configure_distance '../wifi1' 450 || exit 44
[ ! -f "$ack_probe_dir/writes" ] || exit 45
qca_configure_distance wifi1 00001 && [ "$(cat "$ack_probe_dir/wifi1")" = 115 ] || exit 46
qca_configure_distance wifi1 450 && [ "$(wc -l < "$ack_probe_dir/writes")" -eq 2 ] || exit 47
qca_configure_distance wifi1 451 && [ "$(cat "$ack_probe_dir/wifi1")" = 118 ] || exit 48
qca_configure_distance wifi1 21150 && [ "$(cat "$ack_probe_dir/wifi1")" = 253 ] || exit 49
qca_configure_distance wifi2 450 && [ "$(cat "$ack_probe_dir/wifi2")" = 123 ] || exit 50
! qca_configure_distance wifi2 21150 || exit 51
qca_configure_distance wifi1 '' && [ "$(cat "$ack_probe_dir/wifi1")" = 112 ] || exit 52
qca_configure_distance wifi2 0 && [ "$(cat "$ack_probe_dir/wifi2")" = 120 ] || exit 53
read_failure=1
! qca_configure_distance wifi1 450 || exit 54
read_failure=0
write_failure=1
! qca_configure_distance wifi1 450 || exit 55
write_failure=0
read_mismatch=1
! qca_configure_distance wifi1 450 || exit 56
read_mismatch=0
[ "$(cat "$ack_probe_dir/wifi1")" = 112 ] || exit 57
qca_configure_distance wifi1 '' || exit 58
echo malformed > "$ack_probe_dir/wifi1"
! qca_configure_distance wifi1 450 || exit 59
'''
    result = subprocess.run(['sh'], input=harness, text=True, timeout=5,
                            env={'PATH': '/usr/bin:/bin', 'ack_probe_dir': temp})
    assert result.returncode == 0, f'Distance selfcheck failed: {result.returncode}'

    harness = source + '''
json_load() { :; }
json_select() { :; }
json_get_keys() { eval "$1='wifi0 wifi1 wifi2'"; }
json_get_vars() {
    local key
    for key do
        case "$key" in
            type) type=qcawificfg80211;;
            autostart) autostart=1;;
            disabled) disabled=0; [ "$radio" != wifi0 ] || disabled=1;;
            retry_setup_failed) retry_setup_failed=0; [ "$radio" != "$failed_setup" ] || retry_setup_failed=1;;
            distance) distance=450; [ "$radio" != wifi2 ] || distance=900;;
        esac
    done
}
json_get_var() { eval "$1=qcawificfg80211"; }
json_init() { :; }
json_add_string() { request="$2"; }
json_dump() { echo "$request"; }
ubus() { [ "$3" != down ] || echo "down $4" >> "$probe/actions"; }
qca_configure_distance() { echo "$1 $2" >> "$probe/applied"; [ "$1" != "$failed_write" ]; }
qca_native() { echo "native $*" >> "$probe/actions"; }
qca_apply_distances wifi1 || exit 60
[ "$(cat "$probe/applied")" = 'wifi1 450
wifi2 900' ] || exit 61
failed_setup=wifi2
[ "$(qca_down_devices)" = 'wifi0
wifi2' ] || exit 62
rm "$probe/applied"
qca_apply_distances wifi1 || exit 63
[ "$(cat "$probe/applied")" = 'wifi1 450' ] || exit 64
failed_setup=''
failed_write=wifi2
! qca_apply_distances wifi1 || exit 65
[ "$(cat "$probe/actions")" = 'native down wifi2
down wifi2' ] || exit 66
rm "$probe/actions"
failed_write=wifi1
! qca_apply_distances wifi1 || exit 67
[ "$(cat "$probe/actions")" = 'native down wifi1' ] || exit 68
'''
    result = subprocess.run(['sh'], input=harness, text=True, timeout=5,
                            env={'PATH': '/usr/bin:/bin', 'probe': temp})
    assert result.returncode == 0, f'Global distance selfcheck failed: {result.returncode}'

    native = pathlib.Path(temp) / 'native-wifi'
    native.write_text('''
wifi_load() {
    [ "$#" = 0 ] && [ "$DRIVERS" = qcawificfg80211 ] || return 1
    echo "$requested_mode" > "$mode_path"
    wifi_updown
}
wifi_updown() {
    [ "$native_failure" != 1 ] || return 1
    config_load wireless || exit 20
    [ "$wifi1_disabled" = 1 ] && [ "$wifi2_disabled" = 0 ] || exit 21
    config_load wireless || exit 22
    [ "$wifi1_disabled" = 1 ] && [ "$wifi2_disabled" = 0 ] || exit 23
    ! config_load missing || exit 24
    iw phy mld-phy0 interface add mld3 type managed mld_addr
    iw phy mld-phy0 interface add mld0 type __ap mld_addr 02:00:00:00:00:01
}
''')
    iw_command = pathlib.Path(temp) / 'iw'
    iw_command.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$iw_calls"\n')
    iw_command.chmod(0o755)
    modefile = pathlib.Path(temp) / 'atf-mode'
    modefile.write_text('0\n')
    harness = source.replace('/rom/sbin/wifi', str(native)).replace('/sys/module/umac/parameters/atf_mode', str(modefile)) + '''
qca_down_devices() { echo wifi1; }
qca_validate_controls() { :; }
qca_apply_atf() { :; }
config_get() { if [ "$3" = atf_mode ]; then eval "$1=$requested_mode"; else eval "$1=\"${4-}\""; fi; }
config_foreach() { :; }
config_set() { eval "$1_$2=$3"; }
uci_load() {
    [ "$1" != missing ] || return 1
    config_set wifi1 disabled 0
    config_set wifi2 disabled 0
}
requested_mode=0
qca_native up || exit 25
native_failure=1
! qca_native up || exit 26
native_failure=0; requested_mode=1
qca_native up || exit 27
[ "$(cat "$mode_path")" = 1 ] || exit 28
'''
    subprocess.run(['sh'], input=harness, text=True, check=True, timeout=5,
                   env={'PATH': temp + ':/usr/bin:/bin', 'iw_calls': temp + '/iw-calls', 'mode_path': str(modefile)})
    assert pathlib.Path(temp, 'iw-calls').read_text().splitlines() == [
        'phy mld-phy0 interface add mld3 type managed',
        'phy mld-phy0 interface add mld0 type __ap mld_addr 02:00:00:00:00:01'] * 2
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
with tempfile.TemporaryDirectory() as temp:
    controls = pristine.replace('/tmp/qsdk-netifd', temp) + r'''
config_get() { eval "$1=\"\${cfg_${2}_${3}-$4}\""; }
config_foreach() { case "$2" in wifi-iface) "$1" ap1; "$1" ap2;; wifi-device) "$1" wifi1;; esac; }
config_list_foreach() { :; }
cfg_wifi1_type=qcawificfg80211
cfg_ap1_device=wifi1
cfg_ap2_device=wifi1
cfg_ap1_ssid=first
cfg_ap2_ssid=second
cfg_ap1_atf_airtime=60
cfg_ap2_atf_airtime=40
qca_validate_controls && qca_validate_airtime_totals || exit 90
cfg_ap2_atf_airtime=41
! qca_validate_airtime_totals || exit 91
cfg_ap2_atf_airtime=40
cfg_ap1_he_dl_ofdma=2
! qca_validate_controls || exit 92
cfg_ap1_he_dl_ofdma=0
cfg_ap1_maxsta=129
! qca_validate_controls || exit 93
cfg_ap1_maxsta=128
cfg_ap1_set_eht_ulmumimo=7
qca_validate_controls || exit 94
cfg_ap1_set_eht_ulmumimo=8
! qca_validate_controls || exit 99
cfg_ap1_set_eht_ulmumimo=3
[ "$(qca_neighbor_report '02:11:22:33:44:66 115 036 9')" = 02112233446600000000732409 ] || exit 95
for entry in '01:11:22:33:44:66 115 36 9' '02:11:22:33:44:66 256 36 9' '00:00:00:00:00:00 115 36 9'; do
 ! qca_neighbor_report "$entry" || exit 96
done
qca_station_airtime '02:11:22:33:44:66 100' || exit 97
! qca_station_airtime '02:11:22:33:44:66 101' || exit 98
'''
    subprocess.run(['sh'], input=controls, text=True, check=True, timeout=5)
print('QSDK wireless controls selfcheck passed: bounds, unicast neighbors and airtime totals')
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
iwconfig() { printf '%s\n' "$*" >> "$calls"; }
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
qca_hwmode=11g
fixture_frag=512
: > "$calls"
qca_publish_vif vif
grep -q '^ath-test frag 512$' "$calls" || exit 61
fixture_frag=
: > "$calls"
qca_publish_vif vif
grep -q '^ath-test frag off$' "$calls" || exit 62
fixture_frag=513
(qca_publish_vif vif) && exit 63 || [ "$?" = 30 ] || exit 64
fixture_frag=512
qca_hwmode=11axg
(qca_publish_vif vif) && exit 65 || [ "$?" = 30 ] || exit 66
fixture_frag=
qca_hwmode=
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
