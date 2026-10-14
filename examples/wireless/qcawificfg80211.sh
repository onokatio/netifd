#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# QSDK's native controller owns firmware, calibration and MLO orchestration.
. /lib/functions.sh
. /lib/netifd/netifd-wireless.sh
init_wireless_driver "$@"

drv_qcawificfg80211_init_device_config() {
	config_add_string type phy macaddr band country txpower device_if distance
	config_add_boolean doth disabled
	config_add_boolean atf_enabled atfstrictsched
	config_add_array qsdk_atf_groups
	config_add_string he_bsscolor puncture_bitmap
	config_add_int ccfs puncture_strict
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
	config_add_boolean wnm bss_transition rrm_neighbor_report rrm_beacon_report twt_responder
	config_add_array rrm_neighbors
	config_add_int atf_airtime
	config_add_array atf_station_airtime qsdk_wmm qsdk_dscp_map qsdk_atf_ac
	config_add_string qsdk_atf_group
	config_add_int ieee80211w dtim_period maxsta
	config_add_int max_inactivity max_listen_interval reassociation_deadline r0_key_lifetime
	config_add_int ieee80211w_max_timeout ieee80211w_retry_timeout auth_port acct_port dae_port suite_b
	config_add_array sae_password
	config_add_array maclist r0kh r1kh altsubject_match altsubject_match2
	config_add_string wps_pin
	config_add_int bintval copy_enable disablecoext en_6g_sec_comp enable_lci enable_lcr
	config_add_int enable_rtt force_invalid_group guest_separation he_dl_ofdma he_mubfer
	config_add_int he_subfer he_ul_mimo he_ul_ofdma implicitbf mcastenhance
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
		disassoc_low_ack:disassoc_low_ack bss_transition:bss_transition \
		rrm_neighbor_report:rrm_neighbor_report rrm_beacon_report:rrm_beacon_report; do
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

qca_vif_ssid() {
	local ssid mld
	config_get mld "$1" mld
	[ -z "$mld" ] || config_get ssid "$mld" mld_ssid
	[ -n "$ssid" ] || config_get ssid "$1" ssid
	printf '%s' "$ssid"
}

qca_neighbor_report() {
	printf '%s\n' "$1" | awk '
		NR != 1 || NF != 4 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ { exit 1 }
		$2 < 1 || $2 > 255 || $3 < 1 || $3 > 233 || $4 < 1 || $4 > 16 { exit 1 }
		{
			n=split($1,mac,":"); if (n != 6 || $1 == "00:00:00:00:00:00") exit 1;
			for (i=1;i<=6;i++) if (length(mac[i]) != 2 || mac[i] !~ /^[0-9a-fA-F]+$/) exit 1;
			if (substr(mac[1],2,1) ~ /[13579bBdDfF]/) exit 1;
			gsub(":","",$1); printf "%s00000000%02x%02x%02x",$1,$2+0,$3+0,$4+0;
		}'
}

qca_station_airtime() {
	local mac="${1%% *}" percent="${1#* }"
	qca_neighbor_report "$mac 1 1 1" >/dev/null || return 1
	case "$percent" in ''|*[!0-9]*) return 1;; esac
	[ "${#percent}" -le 3 ] && [ "$percent" -ge 1 ] && [ "$percent" -le 100 ]
}

qca_puncture_valid() {
	# Same non-OFDMA patterns used by native UMAC and hostapd; bit 1 disables 20 MHz.
	printf '%s\n' "$*" | awk '
	NF!=6 || $1!~/^[0-9]+$/ || length($1)>5 || $1>65535 {exit 1}
	$1==0 {exit 0}
	$2!~/^11bea$/ || $3!~/^(HT|EHT)(80|160|320)$/ || $4!~/^[0-9]+$/ || length($4)>3 || $4<1 || $4>233 || $6!~/^[0-9]+$/ {exit 1}
	{
	 width=$3; sub(/^(HT|EHT)/,"",width); width+=0; bits=width/20; ch=$4+0; center=$6+0; low=0;
	 if($5==3) {
	  if((ch-1)%4 || ch>221) exit 1;
	  if(width==320) { if(center==0) center=(ch<=61?31:int((ch-1)/32)*32-1); if(center<31 || center>191 || (center-31)%32) exit 1; low=center-30; }
	  else low=int((ch-1)/(bits*4))*bits*4+1;
	 } else {
	  if(width==320) exit 1;
	  starts=width==80?"36 52 100 116 132 149 165":"36 100 149";
	  split(starts,s); for(i in s) if(ch>=s[i] && ch<s[i]+bits*4 && (ch-s[i])%4==0)low=s[i];
	  if(!low) exit 1;
	 }
	 pos=(ch-low)/4; if(pos<0 || pos>=bits || $1>=2^bits || int($1/(2^pos))%2) exit 1;
	 patterns=width==80?"0 1 2 4 8":width==160?"0 1 2 4 8 16 32 64 128 3 12 48 192":"0 3 12 48 192 768 3072 12288 49152 15 240 3840 61440 63 207 783 3087 12303 49167 61443 61452 61488 61632 62208 64512";
	 split(patterns,p); for(i in p) if($1==p[i])exit 0; exit 1;
	 }'
}

qca_verify_puncture() (
	local failed=0
	qca_verify_puncture_vif() {
		local radio ifname wanted actual
		config_get radio "$1" device; config_get ifname "$1" ifname
		config_get wanted "$radio" puncture_bitmap
		[ -n "$wanted" ] && [ -d "/sys/class/net/$ifname" ] || return 0
		actual="$(cfg80211tool "$ifname" get_puncture_bitmap)" || { failed=1; return; }
		[ "${actual##*:}" = "$wanted" ] || { echo "Puncturing readback failed: $ifname wanted=$wanted actual=${actual##*:}" >&2; failed=1; }
	}
	config_foreach qca_verify_puncture_vif wifi-iface
	[ "$failed" = 0 ]
)

qca_wmm_rule() {
	printf '%s\n' "$1" | awk '
	NF!=4 || $1!~/^(cwmin|cwmax|aifs|txop|acm|noack)$/ || $2!~/^(BE|BK|VI|VO)$/ || $3!~/^(local|bss)$/ || $4!~/^[0-9]+$/ {exit 1}
	{ if (length($4)>5 || ($1~/^cw/ && $4>15) || ($1=="aifs" && ($4<1 || $4>15)) || ($1=="txop" && $4>65535) || ($1~/^(acm|noack)$/ && $4>1) || ($1=="noack" && $3=="bss")) exit 1;
	 split("cwmin cwmax aifs txop acm noack",p); for(i=1;i<=6;i++) if(p[i]==$1) param=i;
	 split("BE BK VI VO",a); for(i=1;i<=4;i++) if(a[i]==$2) ac=i-1;
	 print param,ac,($3=="bss"?1:0),$4+0 }'
}

qca_dscp_rule() {
	printf '%s\n' "$1" | awk 'NF!=2 || $1!~/^[0-9]+$/ || $2!~/^[0-9]+$/ || length($1)>2 || $1>63 || $2>7 {exit 1} {print $1*4,$2+0}'
}

qca_atf_group_rule() {
	printf '%s\n' "$1" | awk 'NF!=3 || $1!~/^[A-Za-z][A-Za-z0-9_-]*$/ || length($1)>31 || $2!~/^[0-9]+$/ || length($2)>3 || $2<1 || $2>100 || $3!~/^[012]$/ {exit 1} {print $1,$2+0,$3+0}'
}

qca_atf_ac_rule() {
	printf '%s\n' "$1" | awk 'NF!=2 || $1!~/^(BE|BK|VI|VO)$/ || $2!~/^[0-9]+$/ || length($2)>3 || $2<1 || $2>100 {exit 1} {print $1,$2+0}'
}

qca_validate_advanced() (
	set -f
	local invalid=0 rows
	rows="$(mktemp /tmp/qsdk-netifd/advanced.XXXXXX)" || return 1
	trap 'rm -f "$rows"' EXIT HUP INT TERM
	qca_check_group() { local rule; rule="$(qca_atf_group_rule "$1")" || { invalid=1; return; }; printf 'G %s %s\n' "$radio" "$rule" >> "$rows"; }
	qca_check_wmm() { local rule; rule="$(qca_wmm_rule "$1")" || { invalid=1; return; }; printf 'W %s %s\n' "$vif" "$rule" >> "$rows"; }
	qca_check_dscp() { local rule; rule="$(qca_dscp_rule "$1")" || { invalid=1; return; }; printf 'D %s %s\n' "$vif" "$rule" >> "$rows"; }
	qca_check_ac() { local rule; rule="$(qca_atf_ac_rule "$1")" || { invalid=1; return; }; printf 'A %s %s\n' "$ac_target" "$rule" >> "$rows"; }
	qca_check_advanced_radio() {
		local radio="$1" type value hwmode htmode channel band ccfs
		config_get type "$radio" type
		[ "$type" = qcawificfg80211 ] || return 0
		config_get value "$radio" atfstrictsched
		case "$value" in ''|0|1) ;; *) invalid=1;; esac
		config_get value "$radio" puncture_bitmap
		if [ -n "$value" ]; then
			config_get hwmode "$radio" hwmode; config_get htmode "$radio" htmode; config_get channel "$radio" channel
			config_get band "$radio" band 1; config_get ccfs "$radio" ccfs 0
			qca_puncture_valid "$value" "$hwmode" "$htmode" "$channel" "$band" "$ccfs" || invalid=1
		fi
		config_get value "$radio" puncture_strict
		case "$value" in ''|0|1) ;; *) invalid=1;; esac
		config_get value "$radio" dfs_puncture_en
		case "$value" in ''|0|1) ;; *) invalid=1;; esac
		config_list_foreach "$radio" qsdk_atf_groups qca_check_group
	}
	qca_check_advanced_vif() {
		local vif="$1" radio type value found=0 group mode ac_target
		config_get radio "$vif" device; config_get type "$radio" type
		[ "$type" = qcawificfg80211 ] || return 0
		config_get group "$vif" qsdk_atf_group
		if [ -n "$group" ]; then
			config_get mode "$vif" mode; [ "$mode" = ap ] || invalid=1
			qca_group_match() { [ "${1%% *}" != "$group" ] || found=1; }
			config_list_foreach "$radio" qsdk_atf_groups qca_group_match
			[ "$found" = 1 ] || invalid=1
			printf 'V %s %s %s\n' "$radio" "$group" "$(printf '%s' "$(qca_vif_ssid "$vif")" | hexdump -ve '1/1 "%02x"')" >> "$rows"
			config_get value "$vif" atf_airtime; [ -z "$value" ] || invalid=1
		fi
		ac_target="$vif"
		[ -z "$group" ] || ac_target="$radio:$group"
		config_get value "$vif" atf_airtime
		[ -z "$value" ] || printf 'S %s %s %s\n' "$radio" "$(printf '%s' "$(qca_vif_ssid "$vif")" | hexdump -ve '1/1 "%02x"')" "$value" >> "$rows"
		config_list_foreach "$vif" qsdk_wmm qca_check_wmm
		config_list_foreach "$vif" qsdk_dscp_map qca_check_dscp
		config_list_foreach "$vif" qsdk_atf_ac qca_check_ac
	}
	config_foreach qca_check_advanced_radio wifi-device
	config_foreach qca_check_advanced_vif wifi-iface
	[ "$invalid" = 0 ] || return 1
	awk '
	$1=="G" {k=$2 ":" $3; if(k in groups) bad=1; groups[k]=1; totals[$2]+=$4}
	$1=="V" {members[$2 ":" $3]++; k=$2 ":" $4; if(k in membergroup && membergroup[k]!=$3)bad=1; membergroup[k]=$3}
	$1=="S" {k=$2 ":" $3; if(k in ssids && ssids[k]!=$4)bad=1; ssids[k]=$4; ssidradio[k]=$2}
	$1=="W" {k=$2 ":" $3 ":" $4 ":" $5; if(k in wmm) bad=1; wmm[k]=$6; if($3==1 || $3==2) cw[$2 ":" $4 ":" $5 ":" $3]=$6}
	$1=="D" {k=$2 ":" $3; if(k in dscp) bad=1; dscp[k]=$4}
	$1=="A" {k=$2 ":" $3; if(k in ac) bad=1; ac[k]=$4; actotal[$2]+=$4}
	END {for(k in ssids)totals[ssidradio[k]]+=ssids[k];for(k in groups) if(!members[k]) bad=1; for(k in totals) if(totals[k]>100) bad=1; for(k in actotal) if(actotal[k]>100) bad=1;
	for(k in cw) if(k~/:[12]$/) {base=substr(k,1,length(k)-1); if((base "1") in cw && (base "2") in cw && cw[base "1"]>cw[base "2"]) bad=1} exit bad?1:0}' "$rows"
)

qca_advanced_fingerprint() {
	# Clearing driver tables requires a new VAP/module context.
	uci -q show wireless | grep -E '\.(qsdk_wmm|qsdk_dscp_map|qsdk_atf_groups|qsdk_atf_group|qsdk_atf_ac|atfstrictsched|puncture_bitmap)=' | md5sum | cut -d ' ' -f 1
}

qca_apply_qos() (
	set -f
	local failed=0
	qca_apply_wmm_rule() {
		local rule output param ac bss value
		rule="$(qca_wmm_rule "$1")" || { failed=1; return; }
		read -r param ac bss value <<ARGS
$rule
ARGS
		if [ "$param" = 1 ] || [ "$param" = 2 ]; then
			local other counterpart counterpart_param desired current
			counterpart_param=$((3-param))
			other="$(cfg80211tool "$ifname" getwmmparams "$counterpart_param" "$ac" "$bss")" || { failed=1; return; }
			current="${other##*:}"; desired="$current"
			qca_wmm_counterpart() {
				local row pp aa bb vv
				row="$(qca_wmm_rule "$1")" || return 1
				read -r pp aa bb vv <<ARGS
$row
ARGS
				[ "$pp:$aa:$bb" != "$counterpart_param:$ac:$bss" ] || desired="$vv"
			}
			config_list_foreach "$vif" qsdk_wmm qca_wmm_counterpart
			case "$current:$desired" in *[!0-9:]*) failed=1; return;; esac
			if { [ "$param" = 1 ] && [ "$value" -gt "$desired" ]; } || { [ "$param" = 2 ] && [ "$value" -lt "$desired" ]; }; then failed=1; return; fi
			if { [ "$param" = 1 ] && [ "$value" -gt "$current" ]; } || { [ "$param" = 2 ] && [ "$value" -lt "$current" ]; }; then
				cfg80211tool "$ifname" setwmmparams "$counterpart_param" "$ac" "$bss" "$desired" || { failed=1; return; }
			fi
		fi
		cfg80211tool "$ifname" setwmmparams "$param" "$ac" "$bss" "$value" || { failed=1; return; }
		output="$(cfg80211tool "$ifname" getwmmparams "$param" "$ac" "$bss")" || { failed=1; return; }
		[ "${output##*:}" = "$value" ] || failed=1
	}
	qca_apply_dscp_rule() {
		local rule tos tid
		rule="$(qca_dscp_rule "$1")" || { failed=1; return; }
		read -r tos tid <<ARGS
$rule
ARGS
		cfg80211tool "$ifname" s_dscp_tid_map "$tos" "$tid" || { failed=1; return; }
		local actual index=$((tos / 4))
		actual="$(ubus call luci-rpc getWirelessDscpMap "{\"device\":\"$ifname\",\"dscp\":$index}" | jsonfilter -e "@.map['$index']")"
		[ "$actual" = "$tid" ] || { echo "DSCP readback failed: $ifname DSCP=$index wanted=$tid actual=$actual" >&2; failed=1; }
	}
	qca_apply_qos_vif() {
		local vif="$1" ifname entries output
		config_get ifname "$vif" ifname
		[ -d "/sys/class/net/$ifname" ] || return 0
		config_list_foreach "$vif" qsdk_wmm qca_apply_wmm_rule
		config_get entries "$vif" qsdk_dscp_map
		if [ -n "$entries" ]; then
			cfg80211tool "$ifname" set_dscp_ovride 1 || { failed=1; return; }
			output="$(cfg80211tool "$ifname" get_dscp_ovride)" || { failed=1; return; }
			[ "${output##*:}" = 1 ] || { failed=1; return; }
			config_list_foreach "$vif" qsdk_dscp_map qca_apply_dscp_rule
		fi
	}
	config_foreach qca_apply_qos_vif wifi-iface
	[ "$failed" = 0 ]
)

qca_validate_controls() (
	local invalid=0
	qca_check_neighbor() { qca_neighbor_report "$1" >/dev/null || invalid=1; }
	qca_check_station_airtime() { qca_station_airtime "$1" || invalid=1; }
	qca_check_radio_controls() {
		local value
		config_get value "$1" atf_enabled
		case "$value" in ''|0|1) ;; *) invalid=1;; esac
		config_get value "$1" he_bsscolor
		case "$value" in '') ;; *)
			printf '%s\n' "$value" | grep -qE '^([0-9]|[1-5][0-9]|6[0-3]) [01]$' || invalid=1;;
		esac
	}
	qca_check_controls() {
		local vif="$1" key value radio
		config_get radio "$vif" device
		config_get value "$radio" type
		[ "$value" = qcawificfg80211 ] || return 0
		for key in he_dl_ofdma he_ul_ofdma he_ul_mimo he_mubfer he_subfer vhtmubfer vhtsubfer \
			set_eht_ulofdma set_eht_mu_bfmr set_eht_su_bfmr \
			twt_responder wnm bss_transition rrm_neighbor_report rrm_beacon_report; do
			config_get value "$vif" "$key"
			case "$value" in ''|0|1) ;; *) invalid=1;; esac
		done
		config_get value "$vif" set_eht_ulmumimo
		case "$value" in ''|[0-7]) ;; *) invalid=1;; esac
		config_get value "$vif" maxsta
		case "$value" in '') ;; *[!0-9]*) invalid=1;; *) [ "${#value}" -le 3 ] && [ "$value" -ge 1 ] && [ "$value" -le 128 ] || invalid=1;; esac
		config_get value "$vif" mcastenhance
		case "$value" in ''|0|5) ;; *) invalid=1;; esac
		config_get value "$vif" atf_airtime
		case "$value" in '') ;; *[!0-9]*) invalid=1;; *) [ "${#value}" -le 3 ] && [ "$value" -ge 1 ] && [ "$value" -le 100 ] || invalid=1;; esac
		config_list_foreach "$vif" rrm_neighbors qca_check_neighbor
		config_list_foreach "$vif" atf_station_airtime qca_check_station_airtime
	}
	config_foreach qca_check_radio_controls wifi-device
	config_foreach qca_check_controls wifi-iface
	[ "$invalid" = 0 ] && qca_validate_advanced
)

qca_sync_atf_config() {
	local radio value desired=0 managed=0 original
	for radio in wifi0 wifi1 wifi2; do
		value="$(uci -q get "wireless.$radio.atf_enabled")"
		case "$value" in 1) desired=1; managed=1;; 0) managed=1;; '') ;; *) return 1;; esac
	done
	[ "$managed" = 1 ] || return 0
	original="$(uci -q get wireless.qcawifi.atf_mode)"
	[ "$original" != "$desired" ] || return 0
	uci -q set "wireless.qcawifi.atf_mode=$desired" && uci -q commit wireless
}

qca_validate_airtime_totals() (
	local rows invalid=0
	rows="$(mktemp /tmp/qsdk-netifd/airtime.XXXXXX)" || return 1
	trap 'rm -f "$rows"' EXIT HUP INT TERM
	qca_airtime_station_row() {
		printf 'M %s:%s %s %s\n' "$radio" "$hex" "${1%% *}" "${1#* }" >> "$rows"
	}
	qca_airtime_vif_row() {
		local radio ssid hex airtime
		config_get radio "$1" device
		case "$radio" in wifi0|wifi1|wifi2) ;; *) return 0;; esac
		ssid="$(qca_vif_ssid "$1")"
		local group
		config_get group "$1" qsdk_atf_group
		[ -z "$group" ] || ssid="group:$group"
		hex="$(printf '%s' "$ssid" | hexdump -ve '1/1 "%02x"')"
		config_get airtime "$1" atf_airtime
		[ -z "$airtime" ] || printf 'S %s:%s %s\n' "$radio" "$hex" "$airtime" >> "$rows"
		config_list_foreach "$1" atf_station_airtime qca_airtime_station_row
	}
	config_foreach qca_airtime_vif_row wifi-iface
	awk '
		$1 == "S" { if ($2 in ssid && ssid[$2] != $3+0) bad=1; ssid[$2]=$3+0 }
		$1 == "M" { key=$2 ":" tolower($3); if (key in sta && sta[key] != $4+0) bad=1; sta[key]=$4+0; group[key]=$2 }
		END {
			for (key in ssid) { split(key,a,":"); radio[a[1]]+=ssid[key] }
			for (key in sta) clients[group[key]]+=sta[key];
			for (key in radio) if (radio[key]>100) bad=1;
			for (key in clients) if (clients[key]>100) bad=1;
			exit bad ? 1 : 0;
		}' "$rows"
)

qca_atf_wait_vif() {
	local ifname="$1" desired="${2:-0}" attempt actual
	# Netdev creation can precede the native ATF VAP context.
	for attempt in 1 2 3 4 5 6 7 8 9 10; do
		if cfg80211tool "$ifname" commitatf "$desired"; then
			actual="$(cfg80211tool "$ifname" get_commitatf)"
			[ "${actual##*:}" != "$desired" ] || return 0
		fi
		sleep 0.2
	done
	return 1
}

qca_atf_command() {
	local output
	output="$(wlanconfig "$@" -cfg80211 2>&1)" || { printf '%s\n' "$output"; return 1; }
	printf '%s\n' "$output"
	# wlanconfig can return zero after a native netlink error.
	! printf '%s\n' "$output" | grep -Eq '^(Error received:|Could not send NL command)'
}

qca_apply_atf() {
	local radio="$1" enabled ifname="" value failure=0 groups strict ac_done="|"
	config_get enabled "$radio" atf_enabled 0
	# A fresh module has no ATF state on radios where ATF is disabled.
	[ "$enabled" = 1 ] || return 0
	[ "$(cat /sys/module/umac/parameters/atf_mode 2>/dev/null)" = 1 ] || return 0
	qca_atf_find_vif() {
		local device name mode
		config_get device "$1" device; config_get name "$1" ifname; config_get mode "$1" mode
		[ -n "$ifname" ] || [ "$device" != "$radio" ] || [ "$mode" != ap ] || [ ! -d "/sys/class/net/$name" ] || ifname="$name"
	}
	config_foreach qca_atf_find_vif wifi-iface
	[ -n "$ifname" ] || return 0
	# The native flush command rejects this firmware; use a fresh module context.
	# Firmware accepts group policy only after ATF has been activated.
	qca_atf_wait_vif "$ifname" 1 || return 1
	config_get strict "$radio" atfstrictsched
	config_get groups "$radio" qsdk_atf_groups
	if [ -n "$groups" ]; then
		# Native groups reject strict inner queues with fair outer scheduling.
		cfg80211tool "$radio" atfgrouppolicy "${strict:-0}" || return 1
		value="$(cfg80211tool "$radio" gatfgrouppolicy)" || return 1
		[ "${value##*:}" = "${strict:-0}" ] || return 1
	fi
	if [ -n "$strict" ]; then
		cfg80211tool "$radio" atfstrictsched "$strict" || return 1
		value="$(cfg80211tool "$radio" gatfstrictsched)" || return 1
		[ "${value##*:}" = "$strict" ] || return 1
	fi
	if [ -n "$groups" ]; then
		cfg80211tool "$ifname" atfssidgroup 1 || return 1
		value="$(cfg80211tool "$ifname" g_atfssidgroup)" || return 1
		[ "${value##*:}" = 1 ] || return 1
	fi
	qca_atf_group_member() {
		local device member ssid hex
		[ "$failure" = 0 ] || return 0
		config_get device "$1" device; config_get member "$1" qsdk_atf_group
		[ "$device" = "$radio" ] && [ "$member" = "$group" ] || return 0
		ssid="$(qca_vif_ssid "$1")"
		hex="$(printf '%s' "$ssid" | hexdump -ve '1/1 "%02x"')"
		case "$member_done" in *"|$hex|"*) return 0;; esac
		member_done="$member_done$hex|"
		qca_atf_command "$ifname" addatfgroup "$group" "$ssid" || failure=1
	}
	qca_atf_group() {
		local rule group percent policy member_done="|"
		rule="$(qca_atf_group_rule "$1")" || { failure=1; return; }
		read -r group percent policy <<ARGS
$rule
ARGS
		config_foreach qca_atf_group_member wifi-iface
		[ "$failure" = 0 ] || return 1
		qca_atf_command "$ifname" configatfgroup "$group" "$percent" || { failure=1; return 1; }
		qca_atf_command "$ifname" atfgroupsched "$group" "$policy" || failure=1
	}
	qca_atf_ac() {
		local rule ac percent
		rule="$(qca_atf_ac_rule "$1")" || { failure=1; return; }
		read -r ac percent <<ARGS
$rule
ARGS
		case "$ac_done" in *"|$target:$ac|"*) return 0;; esac
		ac_done="$ac_done$target:$ac|"
		qca_atf_command "$ifname" atfaddac "$target" "$ac:$percent" || failure=1
	}
	[ "$enabled" != 1 ] || config_list_foreach "$radio" qsdk_atf_groups qca_atf_group
	[ "$failure" = 0 ] || return 1
	qca_atf_station() {
		local entry="$1" mac="${1%% *}" percent="${1#* }"
		qca_station_airtime "$entry" || { failure=1; return; }
		qca_atf_command "$ifname" addsta "$(printf '%s' "$mac" | tr -d :)" "$percent" "$ssid" || failure=1
	}
	qca_atf_vif() {
		local device ssid airtime target
		config_get target "$1" qsdk_atf_group
		config_get device "$1" device
		[ "$device" = "$radio" ] || return 0
		ssid="$(qca_vif_ssid "$1")"
		config_get airtime "$1" atf_airtime
		[ -z "$airtime" ] || qca_atf_command "$ifname" addssid "$ssid" "$airtime" || failure=1
		config_list_foreach "$1" atf_station_airtime qca_atf_station
		[ -n "$target" ] || target="$ssid"
		config_list_foreach "$1" qsdk_atf_ac qca_atf_ac
	}
	[ "$enabled" != 1 ] || config_foreach qca_atf_vif wifi-iface
	[ "$failure" = 0 ] || return 1
	qca_atf_commit_vif() {
		local device name mode value
		config_get device "$1" device; config_get name "$1" ifname; config_get mode "$1" mode
		[ "$device" = "$radio" ] && [ "$mode" = ap ] && [ -d "/sys/class/net/$name" ] || return 0
		qca_atf_wait_vif "$name" "$enabled" || failure=1
	}
	config_foreach qca_atf_commit_vif wifi-iface
	if [ "$enabled" = 1 ] && [ -n "$groups" ]; then
		local group_table
		group_table="$(wlanconfig "$ifname" showatfgroup -cfg80211 2>&1)" || return 1
		qca_atf_verify_group() {
			local rule group percent policy
			rule="$(qca_atf_group_rule "$1")" || { failure=1; return; }
			read -r group percent policy <<ARGS
$rule
ARGS
			printf '%s\n' "$group_table" | awk -v group="$group" -v quota="$((percent*10))" -v policy="$policy" '$1==group && $2==quota && $3==policy {found=1} END {exit found?0:1}' || failure=1
		}
		config_list_foreach "$radio" qsdk_atf_groups qca_atf_verify_group
	fi
	[ "$failure" = 0 ]
}

qca_apply_neighbors() {
	local vif="$1" radio mode ifname ssid hex directory
	config_get radio "$vif" device
	config_get mode "$vif" mode
	[ "$mode" = ap ] || return 0
	config_get ifname "$vif" ifname
	case "$radio" in wifi0|wifi1|wifi2) ;; *) return 1;; esac
	printf '%s\n' "$ifname" | grep -qE '^ath[0-9]+$' || return 1
	directory="/var/run/hostapd-$radio"
	[ -S "$directory/$ifname" ] || return 0
	ssid="$(qca_vif_ssid "$vif")"
	hex="$(printf '%s' "$ssid" | hexdump -ve '1/1 "%02x"')"
	qca_add_neighbor() {
		local entry="$1" report reply mac="${1%% *}"
		report="$(qca_neighbor_report "$entry")" || { qca_neighbor_failure=1; return; }
		reply="$(hostapd_cli -p "$directory" -i "$ifname" set_neighbor "$mac" "ssid=$hex" "nr=$report")" || { qca_neighbor_failure=1; return; }
		[ "$reply" = OK ] || qca_neighbor_failure=1
	}
	config_list_foreach "$vif" rrm_neighbors qca_add_neighbor
}

qca_native() (
	local action="$1" radio="$2" down reload=0 desired current color
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
		qca_validate_controls || return 1
		desired="$(uci -q get wireless.qcawifi.atf_mode)"
		case "$desired" in '') desired=0;; 0|1) ;; *) return 1;; esac
		local advanced
		advanced="$(qca_advanced_fingerprint)"
		[ ! -f /tmp/qsdk-netifd/advanced ] || [ "$(cat /tmp/qsdk-netifd/advanced)" = "$advanced" ] || reload=1
		current="$(cat /sys/module/umac/parameters/atf_mode 2>/dev/null)"
		[ "$desired" = "$current" ] || reload=1
		[ "$desired" != 1 ] || reload=1
		for radio in wifi0 wifi1 wifi2; do
			config_get color "$radio" he_bsscolor
			[ -n "$color" ] || [ ! -f "/tmp/qsdk-netifd/color-$radio" ] || reload=1
		done
		if [ "$reload" = 1 ]; then
			# wifi_load also forwards its first argument as a device name.
			DRIVERS=qcawificfg80211
			wifi_load || return 1
		else wifi_updown enable "" "" wifi_up || return 1; fi
		config_load wireless || return 1
		[ "$(cat /sys/module/umac/parameters/atf_mode 2>/dev/null)" = "$desired" ] || return 1
		for radio in wifi0 wifi1 wifi2; do
			qca_apply_atf "$radio" || return 1
			config_get color "$radio" he_bsscolor
			if [ -n "$color" ]; then printf '%s\n' "$color" > "/tmp/qsdk-netifd/color-$radio"
			else rm -f "/tmp/qsdk-netifd/color-$radio"; fi
		done
		qca_apply_qos && qca_verify_puncture || return 1
		printf '%s\n' "$advanced" > /tmp/qsdk-netifd/advanced
		qca_neighbor_failure=0
		config_foreach qca_apply_neighbors wifi-iface
		[ "$qca_neighbor_failure" = 0 ] || return 1
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
	config_load wireless || { qca_unlock; wireless_setup_failed "WIRELESS_CONFIGURATION_UNAVAILABLE"; return 1; }
	qca_validate_controls && qca_validate_airtime_totals || {
		qca_unlock; wireless_setup_failed "INVALID_WIRELESS_CONTROLS_OR_AIRTIME_TOTAL"; return 1;
	}
	qca_sync_mac_config || { qca_unlock; wireless_setup_failed "MAC_FILTER_CONFIGURATION_FAILED"; return 1; }
	qca_sync_atf_config || { qca_unlock; wireless_setup_failed "ATF_CONFIGURATION_FAILED"; return 1; }
	generation="$(qca_generation)"
	if [ "$generation" != "$(cat /tmp/qsdk-netifd/generation 2>/dev/null)" ]; then
		qca_native up > /tmp/qsdk-netifd/controller.log 2>&1 || {
			local failed_radio
			for failed_radio in wifi0 wifi1 wifi2; do qca_native down "$failed_radio" >> /tmp/qsdk-netifd/controller.log 2>&1; done
			rm -f /tmp/qsdk-netifd/generation
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
	[ "$qca_failed" = 0 ] || { rm -f /tmp/qsdk-netifd/generation; wireless_setup_failed "NATIVE_VIF_CONFIGURATION_FAILED"; return 1; }
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
