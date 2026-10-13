#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# QSDK's native controller owns firmware, calibration and MLO orchestration.
. /lib/netifd/netifd-wireless.sh
init_wireless_driver "$@"

drv_qcawificfg80211_init_device_config() {
	config_add_string type phy macaddr band country txpower device_if distance
	config_add_boolean doth disabled
	config_add_boolean legacy_rates noscan
	config_add_int dfs_puncture_en enable_ema wpa_group_rekey
}

drv_qcawificfg80211_init_iface_config() {
	config_add_string ifname mld macaddr wds rrm bssid macfilter nasid mobility_domain r1_key_holder
	config_add_string accept_mac_file deny_mac_file
	config_add_int macaddr_acl
	config_add_string auth_server auth_secret acct_server acct_secret dae_client dae_secret
	config_add_string eap_type ca_cert client_cert priv_key priv_key_pwd auth identity anonymous_identity password pac_file
	config_add_int fast_provisioning
	config_add_int sae_pwe preferred_assoc_link
	config_add_string ca_cert2 client_cert2 priv_key2 priv_key2_pwd auth2 subject_match subject_match2
	config_add_array domain_match domain_suffix_match domain_match2 domain_suffix_match2
	config_add_boolean hidden isolate sae owe wps_pbc wps wmm
	config_add_boolean shpreamble skip_inactivity_poll disassoc_low_ack ieee80211r ft_over_ds
	config_add_boolean ft_psk_generate_local pmk_r1_push wpa_disable_eapol_key_retries add_sha256
	config_add_int ieee80211w dtim_period maxsta
	config_add_int max_inactivity max_listen_interval reassociation_deadline r0_key_lifetime
	config_add_int ieee80211w_max_timeout ieee80211w_retry_timeout auth_port acct_port dae_port suite_b
	config_add_array sae_password
	config_add_array maclist r0kh r1kh altsubject_match altsubject_match2
	config_add_string wps_pin
	config_add_int bintval copy_enable disablecoext en_6g_sec_comp enable_lci enable_lcr
	config_add_int enable_rtt force_invalid_group guest_separation he_dl_ofdma he_mubfer
	config_add_int he_subfer he_ul_mimo he_ul_ofdma igmpmcasten implicitbf mcastenhance
	config_add_int rnr sae_confirm_immediate set_eht_mu_bfmr set_eht_su_bfmr
	config_add_int set_eht_ulmumimo set_eht_ulofdma ssid_change txpower vhtmubfer
	config_add_int vhtsubfer wpa_group_rekey wps_state
	config_add_string rts
	config_add_int frag
}

drv_qcawificfg80211_cleanup() { :; }

qca_maclist() {
	local vif="$1" maclist mac
	config_get maclist "$vif" maclist
	printf '%s\n' "$maclist" | tr ' ' '\n' | while IFS= read -r mac; do
		[ -n "$mac" ] || continue
		printf '%s\n' "$mac" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || return 1
		printf '%s\n' "$mac"
	done
}

qca_cleanup_maclists() {
	local file
	for file in /etc/luci-qsdk/maclist-ath*; do
		[ -f "$file" ] || continue
		printf '%s\n' "${file##*/}" | grep -qE '^maclist-ath[0-9]+$' || continue
		uci -q show wireless | grep -Fq "$file" || rm -f "$file"
	done
}

qca_sync_mac_config() {
	local sections section device ifname filter path accept deny acl pair key value current changed=0
	sections="$(uci -q show wireless | sed -n 's/^\(wireless\.[^.]*\)=wifi-iface$/\1/p')"
	for section in $sections; do
		[ "$(uci -q get "$section.mode")" = ap ] || continue
		device="$(uci -q get "$section.device")"
		[ "$(uci -q get "wireless.$device.type")" = qcawificfg80211 ] || continue
		ifname="$(uci -q get "$section.ifname")"
		[ -n "$ifname" ] || ifname="${section#wireless.}"
		printf '%s\n' "$ifname" | grep -qE '^ath[0-9]+$' || continue
		path="/etc/luci-qsdk/maclist-$ifname"
		filter="$(uci -q get "$section.macfilter")"
		accept="$(uci -q get "$section.accept_mac_file")"
		deny="$(uci -q get "$section.deny_mac_file")"
		case "$filter" in
			allow) acl=1; accept="$path"; deny=;;
			deny) acl=0; deny="$path"; accept=;;
			'') [ "$accept" = "$path" ] || [ "$deny" = "$path" ] || continue; acl=0; accept=; deny=;;
			*) return 1;;
		esac
		for pair in "macaddr_acl:$acl" "accept_mac_file:$accept" "deny_mac_file:$deny"; do
			key="${pair%%:*}"; value="${pair#*:}"
			current="$(uci -q get "$section.$key")"
			[ "$current" != "$value" ] || continue
			if [ -n "$value" ]; then uci -q set "$section.$key=$value" || return 1
			else uci -q delete "$section.$key" || return 1; fi
			changed=1
		done
	done
	[ "$changed" = 0 ] || uci -q commit wireless
}

qca_hostapd_extra() {
	local vif="$1" pair value sha256 pmf suite_b ft enc carriage macfilter ifname macfile temporary
	config_get macfilter "$vif" macfilter
	case "$macfilter" in
		allow|deny)
			config_get ifname "$vif" ifname
			# Keep ACL configuration for native boot even when runtime downloads fail.
			mkdir -p /etc/luci-qsdk || return 1
			macfile="/etc/luci-qsdk/maclist-$ifname"
			temporary="$(mktemp "$macfile.XXXXXX")" || return 1
			if ! qca_maclist "$vif" > "$temporary" || ! mv "$temporary" "$macfile"; then
				rm -f "$temporary"
				return 1
			fi
			# Enforce the filter in native hostapd; driver ACLs are unreliable on added VAPs.
			printf 'macaddr_acl=%s\n%s_mac_file=%s\n' "$( [ "$macfilter" = allow ] && echo 1 || echo 0 )" \
				"$( [ "$macfilter" = allow ] && echo accept || echo deny )" "$macfile"
			;;
		'') ;;
		*) return 1;;
	esac
	config_get enc "$vif" encryption
	config_get sha256 "$vif" add_sha256
	config_get pmf "$vif" ieee80211w
	config_get suite_b "$vif" suite_b
	config_get ft "$vif" ieee80211r
	if [ "${enc%%+*}" = wpa2 ] && [ "$sha256" = 1 ] && [ "$pmf" = 2 ] && [ "$suite_b" != 192 ]; then
		printf 'wpa_key_mgmt=WPA-EAP-SHA256%s\n' "$( [ "$ft" = 1 ] && printf ' FT-EAP' )"
	fi
	for pair in wmm:wmm_enabled shpreamble:preamble max_inactivity:ap_max_inactivity \
		skip_inactivity_poll:skip_inactivity_poll max_listen_interval:max_listen_interval \
		disassoc_low_ack:disassoc_low_ack; do
		config_get value "$vif" "${pair%:*}"
		[ -n "$value" ] || continue
		case "$value" in *[!0-9]*) return 1;; esac
		printf '%s=%s\n' "${pair#*:}" "$value"
	done
}

qca_supplicant_extra() {
	local vif="$1" pair value sha256 pmf suite_b ft enc carriage joined method auth prefix provisioning
	qca_join_match() { joined="${joined:+$joined;}$1"; }
	config_get enc "$vif" encryption
	config_get sha256 "$vif" add_sha256
	config_get pmf "$vif" ieee80211w
	config_get suite_b "$vif" suite_b
	config_get ft "$vif" ieee80211r
	case "$enc" in
		wpa2*)
			config_get method "$vif" eap_type
			method="$(printf '%s' "$method" | tr 'a-z' 'A-Z')"
			case "$method" in
				TLS) ;;
				PEAP|TTLS|FAST)
					config_get auth "$vif" auth MSCHAPV2
					[ -n "$auth" ] || auth=MSCHAPV2
					case "$auth" in PAP|CHAP|MSCHAP|MSCHAPV2|EAP-GTC|EAP-MD5|EAP-MSCHAPV2|EAP-TLS) ;; *) return 1;; esac
					prefix=auth
					case "$auth" in EAP-*) auth="${auth#EAP-}"; [ "$method" != TTLS ] || prefix=autheap;; esac
					printf 'phase2="%s=%s"\n' "$prefix" "$auth"
					if [ "$method" = FAST ]; then
						config_get provisioning "$vif" fast_provisioning 0
						case "$provisioning" in 0|1|2|3) ;; *) return 1;; esac
						printf 'phase1="fast_provisioning=%s"\n' "$provisioning"
					fi
					;;
				'') ;;
				*) return 1;;
			esac
			[ -z "$method" ] || printf 'eap=%s\n' "$method"
			printf 'proto=RSN\n'
			;;
	esac
	if [ "${enc%%+*}" = wpa2 ] && [ "$sha256" = 1 ] && [ "$pmf" = 2 ] && [ "$suite_b" != 192 ]; then
		printf 'key_mgmt=WPA-EAP-SHA256%s\n' "$( [ "$ft" = 1 ] && printf ' FT-EAP' )"
	fi
	for pair in identity:identity anonymous_identity:anonymous_identity password:password pac_file:pac_file \
		ca_cert:ca_cert client_cert:client_cert priv_key:private_key priv_key_pwd:private_key_passwd \
		subject_match:subject_match domain_match:domain_match domain_suffix_match:domain_suffix_match \
		altsubject_match:altsubject_match ca_cert2:ca_cert2 client_cert2:client_cert2 priv_key2:private_key2 \
		priv_key2_pwd:private_key2_passwd subject_match2:subject_match2 altsubject_match2:altsubject_match2 \
		domain_match2:domain_match2 domain_suffix_match2:domain_suffix_match2; do
		config_get value "$vif" "${pair%:*}"
		[ -n "$value" ] || continue
		case "${pair%:*}" in
			altsubject_match*|domain_match*|domain_suffix_match*)
				joined=""
				config_list_foreach "$vif" "${pair%:*}" qca_join_match
				[ -z "$joined" ] || value="$joined"
				;;
		esac
		carriage="$(printf '\r')"
		case "$value" in *'
'*|*"$carriage"*) return 1;; esac
		value="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
		printf '%s="%s"\n' "${pair#*:}" "$value"
	done
}

qca_prepare_hostapd() {
	local vif="$1" file="$2" ifname extra keys temporary
	config_get ifname "$vif" ifname
	[ -n "$ifname" ] && [ "$file" = "/var/run/hostapd-$ifname.conf" ] && [ -f "$file" ] || return 1
	extra="$(qca_hostapd_extra "$vif")" || return 1
	[ -n "$extra" ] || return 0
	keys="$(printf '%s\n' "$extra" | cut -d= -f1 | tr '\n' '|' | sed 's/|$//')"
	temporary="$(mktemp "$file.XXXXXX")" || return 1
	# Keep the native generator; add standard hostapd options before its ADD request.
	if ! sed -E "/^($keys)=/d" "$file" > "$temporary" ||
		! printf '%s\n' "$extra" >> "$temporary" || ! mv "$temporary" "$file"; then
		rm -f "$temporary"
		return 1
	fi
}

qca_prepare_supplicant() {
	local vif="$1" file="$2" ifname ssid key bssid quoted temporary hex extra keys enc
	config_get ifname "$vif" ifname
	[ -n "$ifname" ] && [ "$file" = "/var/run/wpa_supplicant-$ifname.conf" ] && [ -f "$file" ] || return 1
	config_get ssid "$vif" ssid
	config_get key "$vif" key
	config_get bssid "$vif" bssid
	case "$bssid" in '') ;; *) printf '%s\n' "$bssid" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' || return 1;; esac
	hex="$(printf '%s' "$ssid" | hexdump -ve '1/1 "%02x"')"
	quoted="$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/"/\\"/g')"
	extra="$(qca_supplicant_extra "$vif")" || return 1
	keys="$(printf '%s\n' "$extra" | cut -d= -f1 | tr '\n' '|' | sed 's/|$//')"
	config_get enc "$vif" encryption
	case "$enc" in wpa2*) keys="${keys:+$keys|}phase1|phase2|eap|proto";; esac
	temporary="$(mktemp "$file.XXXXXX")" || return 1
	if ! QCA_SSID_HEX="$hex" QCA_KEY="$key" QCA_QUOTED_KEY="$quoted" QCA_BSSID="$bssid" QCA_EXTRA="$extra" QCA_KEYS="$keys" awk '
		length(ENVIRON["QCA_KEYS"]) && $0 ~ "^[[:space:]]*(" ENVIRON["QCA_KEYS"] ")=" { next }
		/^[[:space:]]*bssid=/ { next }
		/^[[:space:]]*ssid=/ { print "\tssid=" ENVIRON["QCA_SSID_HEX"]; next }
		/^[[:space:]]*psk=/ && length(ENVIRON["QCA_KEY"]) {
			if (length(ENVIRON["QCA_KEY"]) == 64 && ENVIRON["QCA_KEY"] ~ /^[0-9a-fA-F]+$/)
				print "\tpsk=" ENVIRON["QCA_KEY"];
			else print "\tpsk=\"" ENVIRON["QCA_QUOTED_KEY"] "\"";
			next
		}
		/^[[:space:]]*sae_password=/ && length(ENVIRON["QCA_KEY"]) {
			print "\tsae_password=\"" ENVIRON["QCA_QUOTED_KEY"] "\""; next
		}
		{ print }
		/^network=\{/ {
			if (length(ENVIRON["QCA_BSSID"])) print "\tbssid=" ENVIRON["QCA_BSSID"];
			if (length(ENVIRON["QCA_EXTRA"])) print ENVIRON["QCA_EXTRA"];
		}
	' "$file" > "$temporary" || ! mv "$temporary" "$file"; then
		rm -f "$temporary"
		return 1
	fi
}

qca_down_devices() (
	json_load "$(ubus call network.wireless status)" || exit 1
	local devices radio autostart disabled retry_setup_failed type
	json_get_keys devices
	for radio in $devices; do
		json_select "$radio"
		json_get_vars autostart disabled retry_setup_failed
		json_select config
		json_get_var type type
		json_select ..
		json_select ..
		[ "$type" = qcawificfg80211 ] || continue
		[ "$autostart" = 1 ] && [ "$disabled" != 1 ] && [ "$retry_setup_failed" != 1 ] || echo "$radio"
	done
)

qca_validate_mlo() {
	local invalid=0
	qca_check_mlo_link() {
		local vif="$1" mld device type disabled mode hwmode option value count=1
		config_get mld "$vif" mld
		[ -n "$mld" ] || return 0
		config_get device "$vif" device
		config_get type "$device" type
		[ "$type" = qcawificfg80211 ] || return 0
		config_get disabled "$device" disabled
		[ "$disabled" != 1 ] || return 0
		config_get disabled "$vif" disabled
		[ "$disabled" != 1 ] || return 0
		case "$mld" in mld*) ;; *) invalid=1; return;; esac
		case "${mld#mld}" in ''|*[!0-9]*) invalid=1; return;; esac
		config_get type "$mld" TYPE
		[ "$type" = wifi-mld ] || { invalid=1; return; }
		config_get mode "$vif" mode
		config_get hwmode "$device" hwmode
		case "$mode:$hwmode" in ap:11be*|sta:11be*) ;; *) invalid=1;; esac
		qca_compare_mlo_link() {
			local other="$1" other_mld other_device other_value
			[ "$other" != "$vif" ] || return 0
			config_get other_mld "$other" mld
			[ "$other_mld" = "$mld" ] || return 0
			count=$((count + 1))
			config_get other_device "$other" device
			[ "$other_device" != "$device" ] || invalid=1
			for option in mode ssid network encryption key sae owe ieee80211w sae_pwe preferred_assoc_link; do
				config_get value "$vif" "$option"
				config_get other_value "$other" "$option"
				[ "$value" = "$other_value" ] || invalid=1
			done
		}
		config_foreach qca_compare_mlo_link wifi-iface
		[ "$count" -le 3 ] || invalid=1
	}
	config_foreach qca_check_mlo_link wifi-iface
	[ "$invalid" = 0 ] || { echo 'Invalid MLO group, radio mode or shared link configuration' >&2; return 1; }
}

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
	iw() {
		# Apply fragmentation per VAP after native setup, instead of overwriting sibling APs.
		[ "$#:$1:$3:$4" != 5:phy:set:frag ] || return 0
		# The native loop retains mld_addr from the preceding factory group.
		if [ "$#" = 8 ] && [ "$1:$3:$4:$6:$8" = phy:interface:add:type:mld_addr ]; then
			case "$5" in mld[0-9]*) set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7";; esac
		fi
		command iw "$@"
	}
	wpa_cli() {
		local argument file command=""
		for argument do
			case "$command:$argument" in
				interface_add:/var/run/wpa_supplicant-ath*.conf) qca_prepare_supplicant "$vif" "$argument" || return 1;;
			esac
			case "$argument" in
				interface_add) command=interface_add;;
				bss_config=ath*:/var/run/hostapd-ath*.conf)
					file="${argument#*:}"
					qca_prepare_hostapd "$vif" "$file" || return 1
					;;
			esac
		done
		[ -z "$CFG80211_UPDATE_FILE" ] || echo wpa_cli "$@" >> "$log_file"
		/usr/sbin/wpa_cli "$@"
	}
	if [ "$action" = down ]; then
		# The global post-disable hook deletes sibling radios' MLDs.
		scan_qcawificfg80211 "$radio"
		disable_qcawificfg80211 "$radio"
	else
		# The native controller reloads UCI between disable and enable.
		config_load() {
			local masked_radio
			uci_load "$@" || return 1
			[ "$1" = wireless ] || return 0
			for masked_radio in $down; do
				config_set "$masked_radio" disabled 1
			done
		}
		for radio in $down; do
			config_set "$radio" disabled 1
		done
		qca_validate_mlo || return 1
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
	local section="$1" ifname mld shpreamble txpower mode power macfilter frag
	json_select config
	json_get_vars ifname mld shpreamble txpower mode macfilter frag
	json_select ..
	[ -n "$ifname" ] && [ -d "/sys/class/net/$ifname" ] || {
		wireless_setup_vif_failed "MISSING_NATIVE_VIF"
		qca_failed=1
		return
	}
	if [ -n "$shpreamble" ] && ! cfg80211tool "$ifname" shpreamble "$shpreamble"; then
		wireless_setup_vif_failed "PREAMBLE_CONFIGURATION_FAILED"
		qca_failed=1
		return
	fi
	if [ "$mode" = ap ]; then
		# hostapd owns the ACL, including disabling a previously enabled filter.
		if ! cfg80211tool "$ifname" maccmd 0; then
			wireless_setup_vif_failed "MAC_FILTER_CONFIGURATION_FAILED"
			qca_failed=1
			return
		fi
		if [ -n "$qca_legacy_rates" ] && ! cfg80211tool "$ifname" pureg "$((1 - qca_legacy_rates))"; then
			wireless_setup_vif_failed "LEGACY_RATES_CONFIGURATION_FAILED"
			qca_failed=1
			return
		fi
		if [ -n "$qca_noscan" ] && ! cfg80211tool "$ifname" disablecoext "$qca_noscan"; then
			wireless_setup_vif_failed "COEXISTENCE_CONFIGURATION_FAILED"
			qca_failed=1
			return
		fi
	fi
	if [ -n "$frag" ]; then
		case "$frag" in *[!0-9]*|*[13579]) wireless_setup_vif_failed "INVALID_FRAGMENT_THRESHOLD"; qca_failed=1; return;; esac
		if [ "$frag" -lt 256 ] || [ "$frag" -gt 2346 ]; then
			wireless_setup_vif_failed "INVALID_FRAGMENT_THRESHOLD"; qca_failed=1; return
		fi
		case "$qca_hwmode" in 11a|11b|11g) :;; *) wireless_setup_vif_failed "UNSUPPORTED_FRAGMENT_THRESHOLD"; qca_failed=1; return;; esac
	fi
	case "$qca_hwmode:$mode" in
		11a:ap|11b:ap|11g:ap|11a:sta|11b:sta|11g:sta)
			if ! iwconfig "$ifname" frag "${frag:-off}"; then
				wireless_setup_vif_failed "FRAGMENT_CONFIGURATION_FAILED"; qca_failed=1; return
			fi;;
	esac
	# QSDK uses dBm and resets a fixed limit with zero, rather than txpower auto.
	power="${qca_txpower:-${txpower:-0}}"
	case "$power" in *[!0-9]*) wireless_setup_vif_failed "INVALID_TXPOWER"; qca_failed=1; return;; esac
	if ! iw "$ifname" set txpower fixed "$power"; then
		wireless_setup_vif_failed "TXPOWER_CONFIGURATION_FAILED"
		qca_failed=1
		return
	fi
	# netifd bridges the MLD; iwinfo uses config.ifname for each physical link.
	[ -z "$mld" ] || ifname="$mld"
	wireless_add_vif "$section" "$ifname"
}

qca_ack_timeout() {
	local value
	value="$(cfg80211tool "$1" get_acktimeout)" || return 1
	value="$(printf '%s\n' "$value" | sed -n 's/^.*get_acktimeout:\([0-9][0-9]*\)$/\1/p')"
	printf '%s\n' "$value" | grep -qE '^[1-9][0-9]{2}$' || return 1
	[ "$value" -ge 112 ] && [ "$value" -le 255 ] || return 1
	printf '%s\n' "$value"
}

qca_configure_distance() {
	local radio="$1" distance="$2" state baseline current timeout
	printf '%s\n' "$radio" | grep -qE '^wifi[0-9]+$' || return 1
	case "$distance" in
		'') ;;
		*)
			printf '%s\n' "$distance" | grep -qE '^[0-9]{1,5}$' || return 1
			distance="$(printf '%s\n' "$distance" | sed 's/^0*//')"
			distance="${distance:-0}"
			[ "$distance" -le 21150 ] || return 1;;
	esac
	state="/tmp/qsdk-netifd/ack-baseline-$radio"
	[ -n "$distance" ] && [ "$distance" != 0 ] || [ -f "$state" ] || return 0
	current="$(qca_ack_timeout "$radio")" || return 1
	if [ -f "$state" ]; then
		baseline="$(cat "$state")" || return 1
		printf '%s\n' "$baseline" | grep -qE '^[1-9][0-9]{2}$' &&
			[ "$baseline" -ge 112 ] && [ "$baseline" -le 255 ] || return 1
	else
		baseline="$current"
	fi
	# shortcut: ACK only; add CTS/slot timing when their native defaults can be read and restored.
	# Match iw's 450m coverage classes: add 3us of round-trip propagation time per class.
	timeout=$((baseline + ((${distance:-0} + 449) / 450) * 3))
	[ "$timeout" -le 255 ] || return 1
	printf '%s\n' "$baseline" > "$state" || return 1
	if ! cfg80211tool "$radio" acktimeout "$timeout" ||
		[ "$(qca_ack_timeout "$radio")" != "$timeout" ]; then
		cfg80211tool "$radio" acktimeout "$current" >/dev/null 2>&1
		return 1
	fi
	[ -n "$distance" ] && [ "$distance" != 0 ] || rm -f "$state"
	return 0
}

qca_apply_distances() (
	local current="$1" devices radio autostart disabled retry_setup_failed type distance
	json_load "$(ubus call network.wireless status)" || exit 1
	json_get_keys devices
	for radio in $devices; do
		json_select "$radio"
		json_get_vars autostart disabled retry_setup_failed
		json_select config
		json_get_vars type distance
		json_select ..
		json_select ..
		[ "$type" = qcawificfg80211 ] && [ "$autostart" = 1 ] &&
			[ "$disabled" != 1 ] && [ "$retry_setup_failed" != 1 ] || continue
		qca_configure_distance "$radio" "$distance" && continue
		qca_native down "$radio" >> /tmp/qsdk-netifd/controller.log 2>&1
		if [ "$radio" != "$current" ]; then
			json_init
			json_add_string device "$radio"
			ubus call network.wireless down "$(json_dump)"
		fi
		exit 1
	done
)

drv_qcawificfg80211_setup() {
	local radio="$1" generation qca_failed=0 qca_txpower qca_legacy_rates qca_noscan qca_hwmode qca_distance
	json_select config
	json_get_var qca_txpower txpower
	json_get_var qca_legacy_rates legacy_rates
	json_get_var qca_noscan noscan
	json_get_var qca_hwmode hwmode
	json_get_var qca_distance distance
	json_select ..
	umask 077
	mkdir -p /tmp/qsdk-netifd || return 1
	qca_lock || return 1
	qca_sync_mac_config || { qca_unlock; wireless_setup_failed "MAC_FILTER_CONFIGURATION_FAILED"; return 1; }
	generation="$(qca_generation)"
	if [ "$generation" != "$(cat /tmp/qsdk-netifd/generation 2>/dev/null)" ]; then
		qca_native up > /tmp/qsdk-netifd/controller.log 2>&1 || {
			qca_unlock
			wireless_setup_failed "NATIVE_CONTROLLER_FAILED"
			return 1
		}
		qca_apply_distances "$radio" || {
			qca_native down "$radio" >> /tmp/qsdk-netifd/controller.log 2>&1
			qca_unlock; wireless_setup_failed "DISTANCE_CONFIGURATION_FAILED"; return 1;
		}
		printf '%s\n' "$generation" > /tmp/qsdk-netifd/generation
	fi
	qca_configure_distance "$radio" "$qca_distance" || {
		rm -f /tmp/qsdk-netifd/generation
		qca_native down "$radio" >> /tmp/qsdk-netifd/controller.log 2>&1
		qca_unlock; wireless_setup_failed "DISTANCE_CONFIGURATION_FAILED"; return 1;
	}
	qca_cleanup_maclists
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
	local radio="$1" autostart disabled retry_setup_failed ret=0
	umask 077
	mkdir -p /tmp/qsdk-netifd || return 1
	qca_lock || return 1
	# A configuration reload is followed by setup; apply the MLO group once.
	autostart="$(ubus call network.wireless status | jsonfilter -e "@.$radio.autostart")"
	retry_setup_failed="$(ubus call network.wireless status | jsonfilter -e "@.$radio.retry_setup_failed")"
	disabled="$(uci -q get "wireless.$radio.disabled")"
	if [ "$autostart" = true ] && [ "$disabled" != 1 ] && [ "$retry_setup_failed" != true ]; then
		qca_unlock
		return 0
	fi
	qca_configure_distance "$radio" "" || ret=1
	rm -f /tmp/qsdk-netifd/generation
	if qca_native down "$radio" > /tmp/qsdk-netifd/controller.log 2>&1; then
		qca_restart_partners "$radio" || ret=1
	else
		ret=1
	fi
	qca_unlock
	return "$ret"
}

add_driver qcawificfg80211
