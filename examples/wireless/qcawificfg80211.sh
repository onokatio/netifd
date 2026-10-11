#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# QSDK's native controller owns firmware, calibration and MLO orchestration.
. /lib/netifd/netifd-wireless.sh
init_wireless_driver "$@"

drv_qcawificfg80211_init_device_config() {
	config_add_string type phy macaddr band country txpower device_if
	config_add_boolean doth disabled
	config_add_int dfs_puncture_en enable_ema wpa_group_rekey
}

drv_qcawificfg80211_init_iface_config() {
	config_add_string ifname mld macaddr wds rrm
	config_add_boolean hidden isolate sae owe wps_pbc wps wmm
	config_add_int ieee80211w dtim_period maxsta
	config_add_array sae_password
	config_add_string wps_pin
	config_add_int bintval copy_enable disablecoext en_6g_sec_comp enable_lci enable_lcr
	config_add_int enable_rtt force_invalid_group guest_separation he_dl_ofdma he_mubfer
	config_add_int he_subfer he_ul_mimo he_ul_ofdma igmpmcasten implicitbf mcastenhance
	config_add_int rnr sae_confirm_immediate set_eht_mu_bfmr set_eht_su_bfmr
	config_add_int set_eht_ulmumimo set_eht_ulofdma ssid_change txpower vhtmubfer
	config_add_int vhtsubfer wpa_group_rekey wps_state
}

drv_qcawificfg80211_cleanup() { :; }

qca_down_devices() (
	json_load "$(ubus call network.wireless status)" || exit 1
	local devices radio autostart disabled type
	json_get_keys devices
	for radio in $devices; do
		json_select "$radio"
		json_get_vars autostart disabled
		json_select config
		json_get_var type type
		json_select ..
		json_select ..
		[ "$type" = qcawificfg80211 ] || continue
		[ "$autostart" = 1 ] && [ "$disabled" != 1 ] || echo "$radio"
	done
)

qca_native() (
	local action="$1" radio="$2" down
	down="$(qca_down_devices)" || return 1
	exec 9>&-
	# The ROM controller may call netifd; suppress only recursive owner calls.
	ubus() {
		case "$1:$2:$3" in
			call:network:reload|call:network.wireless:up|call:network.wireless:down|call:network.wireless:status) return 0;;
		esac
		command ubus "$@"
	}
	set -- status
	. /rom/sbin/wifi
	if [ "$action" = down ]; then
		# The global post-disable hook deletes sibling radios' MLDs.
		scan_qcawificfg80211 "$radio"
		disable_qcawificfg80211 "$radio"
	else
		for radio in $down; do
			config_set "$radio" disabled 1
		done
		wifi_updown enable "" "" wifi_up
	fi
)

qca_unlock() {
	exec 9>&-
}

qca_lock() {
	exec 9>/var/run/qsdk-netifd.lock
	busybox flock -x 9
}

qca_generation() {
	{ sha256sum /etc/config/wireless; qca_down_devices | sort; } | sha256sum | cut -d ' ' -f 1
}

qca_publish_vif() {
	local section="$1" ifname mld
	json_select config
	json_get_vars ifname mld
	json_select ..
	[ -n "$ifname" ] && [ -d "/sys/class/net/$ifname" ] || {
		wireless_setup_vif_failed "MISSING_NATIVE_VIF"
		qca_failed=1
		return
	}
	# netifd bridges the MLD; iwinfo uses config.ifname for each physical link.
	[ -z "$mld" ] || ifname="$mld"
	wireless_add_vif "$section" "$ifname"
}

drv_qcawificfg80211_setup() {
	local radio="$1" generation qca_failed=0
	umask 077
	mkdir -p /tmp/qsdk-netifd || return 1
	qca_lock || return 1
	generation="$(qca_generation)"
	if [ "$generation" != "$(cat /tmp/qsdk-netifd/generation 2>/dev/null)" ]; then
		qca_native up > /tmp/qsdk-netifd/controller.log 2>&1 || {
			qca_unlock
			wireless_setup_failed "NATIVE_CONTROLLER_FAILED"
			return 1
		}
		printf '%s\n' "$generation" > /tmp/qsdk-netifd/generation
	fi
	for_each_interface "" qca_publish_vif
	qca_unlock
	[ "$qca_failed" = 0 ] || { wireless_setup_failed "MISSING_NATIVE_VIF"; return 1; }
	wireless_set_up
}

qca_restart_partners() (
	local stopped="$1" devices radio up autostart disabled type
	json_load "$(ubus call network.wireless status)" || exit 1
	json_get_keys devices
	for radio in $devices; do
		json_select "$radio"
		json_get_vars up autostart disabled
		json_select config
		json_get_var type type
		json_select ..
		json_select ..
		[ "$radio" != "$stopped" ] && [ "$type" = qcawificfg80211 ] &&
			[ "$up" = 1 ] && [ "$autostart" = 1 ] && [ "$disabled" != 1 ] || continue
		# Legacy netifd removes shared MLD bridge ports when one link stops.
		json_init
		json_add_string device "$radio"
		local request="$(json_dump)"
		ubus call network.wireless down "$request" || exit 1
		ubus call network.wireless up "$request" || exit 1
		json_load "$(ubus call network.wireless status)" || exit 1
	done
)

drv_qcawificfg80211_teardown() {
	local radio="$1" autostart disabled ret
	umask 077
	mkdir -p /tmp/qsdk-netifd || return 1
	qca_lock || return 1
	# A configuration reload is followed by setup; apply the MLO group once.
	autostart="$(ubus call network.wireless status | jsonfilter -e "@.$radio.autostart")"
	disabled="$(uci -q get "wireless.$radio.disabled")"
	if [ "$autostart" = true ] && [ "$disabled" != 1 ]; then
		qca_unlock
		return 0
	fi
	rm -f /tmp/qsdk-netifd/generation
	qca_native down "$radio" > /tmp/qsdk-netifd/controller.log 2>&1
	ret="$?"
	[ "$ret" != 0 ] || qca_restart_partners "$radio" || ret="$?"
	qca_unlock
	return "$ret"
}

add_driver qcawificfg80211
