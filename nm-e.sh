
#!/bin/bash
# nm-e.sh – NetworkManager Easy: A simplified, dialog‑based interface for nmcli`

VERSION="0.23"

set -euo pipefail
APP_TITLE="nm-e.sh ver ${VERSION} ||  by Ewald Jeitler  ||  https://www.jeitler.guru"
DIALOG=${DIALOG:-dialog}
NMCLI=${NMCLI:-nmcli}
IPCMD=${IPCMD:-ip}
TMPDIR=${TMPDIR:-/tmp}
TMPFILE="$(mktemp "${TMPDIR}/nmcli-manager.XXXXXX")"
trap 'rm -f "$TMPFILE"' EXIT

# ---------------------------------------------------------
# check root privileges - req. sudo password 
# ---------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    "$DIALOG" --backtitle "$APP_TITLE" --title "Authentication required" \
        --msgbox "This program requires root privileges.\nYou will now be prompted for your sudo password." \
        8 60 || true

    sudo -v || {
        "$DIALOG" --title "Error" --msgbox "Authentication failed." 7 40 || true
        exit 1
    }

    exec sudo -E "$0" "$@"
fi

# ---------------------------------------------------------
# Utilities
# ---------------------------------------------------------
error_exit() {
    local msg="$1"
    echo "ERROR: $msg" >&2
    "$DIALOG" --backtitle "$APP_TITLE" --title "Error" --msgbox "$msg" 10 60 || true
    exit 1
}

show_message() {
    "$DIALOG" --backtitle "$APP_TITLE" --title "$1" --msgbox "$2" 12 70
}

check_requirements() {
    local bin
    for bin in "$NMCLI" "$DIALOG" "$IPCMD" bc awk sed grep cut tr ps; do
        command -v "$bin" >/dev/null 2>&1 || error_exit "Required binary '$bin' not found."
    done
    [ "$(id -u)" -eq 0 ] || error_exit "This script must be run as root."
}

nmcli_run() {
    "$NMCLI" "$@"
}

read_tmpfile() {
    cat "$TMPFILE"
}

read_menu_args_into() {
    local generator="$1"
    local -n out_ref="$2"
    out_ref=()
    while IFS= read -r -d '' item; do
        out_ref+=("$item")
    done < <("$generator")
}

connection_exists() {
    local conn="$1"
    nmcli_run connection show "$conn" >/dev/null 2>&1
}

reactivate_connection() {
    local conn="$1"
    nmcli_run connection down "$conn" >/dev/null 2>&1 || true
    nmcli_run connection up "$conn" >/dev/null 2>&1 || true
}

get_device_carrier() {
    local iface="$1"
    if [ -r "/sys/class/net/$iface/carrier" ]; then
        cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

get_device_operstate() {
    local iface="$1"
    if [ -r "/sys/class/net/$iface/operstate" ]; then
        cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown
    else
        echo unknown
    fi
}

get_device_ipv4() {
    local iface="$1"
    nmcli_run -g IP4.ADDRESS device show "$iface" 2>/dev/null | head -n1 || true
}

get_device_mtu() {
    local iface="$1"
    cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo ""
}

get_interface_driver() {
    local iface="$1"
    ethtool -i "$iface" 2>/dev/null | awk '/^driver:/{print $2; exit}'
}

get_process_group_id() {
    local pid="$1"
    local tries=0
    local pgid=""
    while [ "$tries" -lt 10 ]; do
        pgid=$(ps -o pgid= "$pid" 2>/dev/null | tr -d ' ' || true)
        [ -n "$pgid" ] && { echo "$pgid"; return 0; }
        tries=$((tries + 1))
        sleep 0.1
    done
    return 1
}

terminate_pid_or_group() {
    local pid="$1"
    local pgid="${2:-}"

    if [ -n "$pgid" ] && kill -0 "-$pgid" 2>/dev/null; then
        kill -TERM "-$pgid" 2>/dev/null || true
        sleep 1
        kill -0 "-$pgid" 2>/dev/null && kill -KILL "-$pgid" 2>/dev/null || true
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
}

close_wait_dialog() {
    local wait_dialog_pid="$1"
    if [ -n "$wait_dialog_pid" ] && kill -0 "$wait_dialog_pid" 2>/dev/null; then
        kill "$wait_dialog_pid" 2>/dev/null || true
        wait "$wait_dialog_pid" 2>/dev/null || true
    fi
}

count_mask_bits() {
    local mask="$1"
    local o1 o2 o3 o4 bin
    IFS=. read -r o1 o2 o3 o4 <<< "$mask"
    bin=$(printf "%08d%08d%08d%08d" \
        "$(bc <<< "obase=2;$o1")" \
        "$(bc <<< "obase=2;$o2")" \
        "$(bc <<< "obase=2;$o3")" \
        "$(bc <<< "obase=2;$o4")")
    grep -o "1" <<< "$bin" | wc -l
}

parse_static_ip_input() {
    local input="$1"

    if [[ "$input" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]]; then
        STATIC_IP="${BASH_REMATCH[1]}"
        STATIC_PREFIX="${BASH_REMATCH[2]}"
        return 0
    fi

    if [[ "$input" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        STATIC_IP="${BASH_REMATCH[1]}"
        STATIC_PREFIX=$(count_mask_bits "${BASH_REMATCH[2]}")
        return 0
    fi

    return 1
}

parse_route_input() {
    local input="$1"
    if [[ "$input" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]]; then
        ROUTE_NET="${BASH_REMATCH[1]}"
        ROUTE_PREFIX="${BASH_REMATCH[2]}"
        return 0
    fi
    if [[ "$input" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        ROUTE_NET="${BASH_REMATCH[1]}"
        ROUTE_PREFIX=$(count_mask_bits "${BASH_REMATCH[2]}")
        return 0
    fi
    return 1
}

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    ((a<=255 && b<=255 && c<=255 && d<=255))
}

is_valid_dns_list() {
    local list="$1"
    [[ -z "$list" ]] && return 0
    local d
    IFS=',' read -ra dns <<< "$list"
    for d in "${dns[@]}"; do
        is_valid_ipv4 "$d" || return 1
    done
}

# ---------------------------------------------------------
# Connection / interface helpers
# ---------------------------------------------------------
get_active_connection_for_iface() {
    local iface="$1"
    nmcli_run -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2
}

get_never_default_for_conn() {
    local conn="$1"
    local val
    val=$(nmcli_run -g ipv4.never-default connection show "$conn" 2>/dev/null || true)
    [ -z "$val" ] && val="no"
    echo "$val"
}

get_ipv4_method_for_conn() {
    local conn="$1"
    nmcli_run -g ipv4.method connection show "$conn" 2>/dev/null | head -n1 || true
}

list_all_interfaces() {
    nmcli_run -t -f DEVICE,TYPE,STATE,CONNECTION device status | sed 's/:/|/g'
}

filter_interface() {
    local iface="$1"
    [[ "$iface" == "lo" || "$iface" == "lo0" ]] && return 1
    [[ "$iface" == p2p* || "$iface" == *p2p* || "$iface" == *-p2p* ]] && return 1
    return 0
}

build_interface_menu_args() {
    local -a args=()
    local line dev type state conn
    while IFS= read -r line; do
        IFS='|' read -r dev type state conn <<< "$line"
        filter_interface "$dev" || continue
        args+=("$dev" "Type:$type State:$state Conn:${conn:-<none>}")
    done < <(list_all_interfaces)
    printf '%s\0' "${args[@]}"
}

list_all_connections() {
    nmcli_run -t -f NAME,UUID,TYPE connection show | sed 's/:/|/g'
}

build_connection_menu_args() {
    local -a args=()
    local line name uuid type
    while IFS= read -r line; do
        IFS='|' read -r name uuid type <<< "$line"
        args+=("$name" "Type:$type UUID:$uuid")
    done < <(list_all_connections)
    printf '%s\0' "${args[@]}"
}

build_connection_menu_args_array() {
    local -n out_ref="$1"
    out_ref=()

    local -a conns=()
    mapfile -t conns < <(nmcli_run -t -f NAME connection show 2>/dev/null)
    [ "${#conns[@]}" -gt 0 ] || return 1

    local c type ifname
    for c in "${conns[@]}"; do
        [ -n "$c" ] || continue
        type=$(nmcli_run -g connection.type connection show "$c" 2>/dev/null || true)
        ifname=$(nmcli_run -g connection.interface-name connection show "$c" 2>/dev/null || true)
        [ "$type" = "loopback" ] && continue
        [ "$ifname" = "lo" ] && continue
        out_ref+=("$c" "")
    done

    if [ "${#out_ref[@]}" -eq 0 ]; then
        for c in "${conns[@]}"; do
            [ -n "$c" ] && out_ref+=("$c" "")
        done
    fi

    [ "${#out_ref[@]}" -gt 0 ]
}

delete_connections_bound_to_interface() {
    local iface="$1"
    local keep_conn="$2"
    local conn_name=""
    local conn_ifname=""

    while IFS= read -r conn_name; do
        [ -z "$conn_name" ] && continue
        [ "$conn_name" = "$keep_conn" ] && continue

        conn_ifname=$(nmcli_run -g connection.interface-name connection show "$conn_name" 2>/dev/null || true)

        if [ "$conn_ifname" = "$iface" ]; then
            nmcli_run connection down "$conn_name" >/dev/null 2>&1 || true
            nmcli_run connection modify "$conn_name" connection.interface-name "" >/dev/null 2>&1 || true
            nmcli_run connection modify "$conn_name" connection.autoconnect no >/dev/null 2>&1 || true
        fi
    done < <(nmcli_run -t -g NAME connection show 2>/dev/null || true)
}

# ---------------------------------------------------------
# Display functions
# ---------------------------------------------------------
show_interface_config() {
    local iface="$1"
    {
        echo "=== nmcli device show $iface ==="
        nmcli_run device show "$iface"
        echo
        echo "=== ip addr show dev $iface ==="
        "$IPCMD" addr show dev "$iface"
    } > "$TMPFILE"
    "$DIALOG" --backtitle "$APP_TITLE" --title "Interface Configuration: $iface" --textbox "$TMPFILE" 20 80
}

show_all_interfaces_info() {
    {
        echo "=== All interfaces (nmcli device show) ==="
        nmcli_run device show
        echo
        echo "=== ip addr ==="
        "$IPCMD" addr
    } > "$TMPFILE"
    "$DIALOG" --backtitle "$APP_TITLE" --title "All Interface Information" --textbox "$TMPFILE" 20 80
}

show_ip_route() {
    {
        echo "=== IPv4 routes ==="
        "$IPCMD" route show
        echo
        echo "=== IPv6 routes ==="
        "$IPCMD" -6 route show
    } > "$TMPFILE"
    "$DIALOG" --backtitle "$APP_TITLE" --title "Routing Table" --textbox "$TMPFILE" 20 80
}

show_connection_file() {
    local conn="$1"
    [ -n "$conn" ] || { show_message "Error" "No connection specified."; return 0; }

    local file=""
    local uuid=""
    local f

    file=$(nmcli_run -g connection.filename connection show "$conn" 2>/dev/null || true)
    if [ -z "$file" ]; then
        uuid=$(nmcli_run -g connection.uuid connection show "$conn" 2>/dev/null || true)
        for f in /etc/NetworkManager/system-connections/*; do
            [ -f "$f" ] || continue
            if [ -n "$uuid" ] && grep -q -F "$uuid" "$f" 2>/dev/null; then
                file="$f"
                break
            fi
            if grep -q -E "^\s*(id|connection\.id)\s*=\s*${conn}\s*$" "$f" 2>/dev/null; then
                file="$f"
                break
            fi
        done
    fi

    if [ -n "$file" ] && [ -f "$file" ]; then
        if ! cp "$file" "$TMPFILE" 2>/dev/null; then
            if command -v sudo >/dev/null 2>&1; then
                sudo cp "$file" "$TMPFILE" || {
                    show_message "Error" "Could not copy the configuration file with sudo."
                    return 0
                }
            else
                show_message "Error" "Could not read the configuration file and sudo is not available."
                return 0
            fi
        fi
        "$DIALOG" --backtitle "$APP_TITLE" --title "Configuration File: $conn" --textbox "$TMPFILE" 25 90 || true
        return 0
    fi

    if nmcli_run connection show "$conn" > "$TMPFILE" 2>/dev/null; then
        "$DIALOG" --backtitle "$APP_TITLE" --title "Connection Information: $conn" --textbox "$TMPFILE" 25 90 || true
        return 0
    fi

    show_message "Error" "Could not determine the configuration file or show connection details for '$conn'."
}

# ---------------------------------------------------------
# Core actions
# ---------------------------------------------------------
toggle_ipv4_defaultgw() {
    local iface="$1"
    local conn current new msg

    conn=$(get_active_connection_for_iface "$iface")
    if [ -z "$conn" ]; then
        show_message "No Active Connection" "There is no active connection on this interface."
        return 0
    fi

    current=$(get_never_default_for_conn "$conn")
    if [ "$current" = "yes" ]; then
        new="no"
        msg="The default gateway will be used again (ipv4.never-default=no)."
    else
        new="yes"
        msg="The default gateway will not be used (ipv4.never-default=yes)."
    fi

    if nmcli_run connection modify "$conn" ipv4.never-default "$new"; then
        reactivate_connection "$conn"
        show_message "Updated" "Connection: $conn\n\n$msg"
    else
        show_message "Error" "Could not change ipv4.never-default for '$conn'."
    fi
}

split_nmcli_routes() {
    local raw="$1"
    local cleaned=""
    local line current_route p
    raw=$(echo "$raw" | tr ';' '\n' | tr ',' '\n')
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
        [ -n "$line" ] || continue
        current_route=""
        read -ra parts <<< "$line"
        for p in "${parts[@]}"; do
            if [[ "$p" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ ]]; then
                [ -n "$current_route" ] && cleaned+="$current_route"$'\n'
                current_route="$p"
            else
                current_route="$current_route $p"
            fi
        done
        [ -n "$current_route" ] && cleaned+="$current_route"$'\n'
    done <<< "$raw"
    echo "$cleaned" | sed '/^$/d'
}

add_static_route() {
    local iface="$1"
    local conn route_input gw metric route_string
    local ROUTE_NET ROUTE_PREFIX

    conn=$(get_active_connection_for_iface "$iface")
    if [ -z "$conn" ]; then
        show_message "No Active Connection" "There is no active connection on this interface."
        return 0
    fi

    if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Add Static Route" --inputbox \
        "Enter the route:\nExamples:\n 10.10.20.0/24\n 10.10.20.0 255.255.255.0" \
        12 60 2> "$TMPFILE"; then
        return 0
    fi
    route_input=$(read_tmpfile)

    if ! parse_route_input "$route_input"; then
        show_message "Invalid" "Invalid route format."
        return 0
    fi

    "$DIALOG" --backtitle "$APP_TITLE" --title "Gateway" --inputbox "Enter the gateway for this route (optional):" 8 60 2> "$TMPFILE" || true
    gw=$(read_tmpfile)
    "$DIALOG" --backtitle "$APP_TITLE" --title "Metric" --inputbox "Enter the metric (optional):" 8 60 2> "$TMPFILE" || true
    metric=$(read_tmpfile)

    route_string="${ROUTE_NET}/${ROUTE_PREFIX}"
    [ -n "$gw" ] && route_string="$route_string $gw"
    [ -n "$metric" ] && route_string="$route_string $metric"

    if nmcli_run connection modify "$conn" +ipv4.routes "$route_string"; then
        reactivate_connection "$conn"
        show_message "Added" "Route added:\n$route_string"
    else
        show_message "Error" "Could not add the route."
    fi
}

delete_static_route() {
    local iface="$1"
    local conn routes_raw routes sel route_to_delete
    local -a menu_args=()
    local idx=1

    conn=$(get_active_connection_for_iface "$iface")
    if [ -z "$conn" ]; then
        show_message "No Active Connection" "There is no active connection on this interface."
        return 0
    fi

    routes_raw=$(nmcli_run -g ipv4.routes connection show "$conn" 2>/dev/null || true)
    if [ -z "$routes_raw" ]; then
        show_message "No Routes" "No static routes are configured."
        return 0
    fi

    routes=$(split_nmcli_routes "$routes_raw")
    while IFS= read -r route_to_delete; do
        menu_args+=("$idx" "$route_to_delete")
        idx=$((idx + 1))
    done <<< "$routes"

    if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Delete Static Route" --menu \
        "Select the route to delete" 20 70 10 \
        "${menu_args[@]}" 2> "$TMPFILE"; then
        return 0
    fi
    sel=$(read_tmpfile)
    route_to_delete=$(echo "$routes" | sed -n "${sel}p")

    if nmcli_run connection modify "$conn" -ipv4.routes "$route_to_delete"; then
        reactivate_connection "$conn"
        show_message "Deleted" "Route deleted:\n$route_to_delete"
    else
        show_message "Error" "Could not delete the route."
    fi
}

assign_connection_to_interface() {
    local iface="$1"
    local -a menu_args=()
    local conn_name carrier operstate ipv4_method ip nmcli_pid pgid wait_dialog_pid nmcli_rc

    read_menu_args_into build_connection_menu_args menu_args
    if [ "${#menu_args[@]}" -eq 0 ]; then
        show_message "No Connections" "No existing connections were found."
        return 0
    fi

    if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Assign Connection" --menu "Select the connection for $iface" 0 0 0 "${menu_args[@]}" 2>"$TMPFILE"; then
        return 0
    fi
    conn_name=$(read_tmpfile)

    delete_connections_bound_to_interface "$iface" "$conn_name"

    if ! nmcli_run connection modify "$conn_name" connection.interface-name "$iface" >/dev/null 2>&1; then
        show_message "Failure" "Could not bind the connection '$conn_name' to interface '$iface'."
        return 0
    fi
    if ! nmcli_run connection modify "$conn_name" connection.autoconnect yes >/dev/null 2>&1; then
        show_message "Failure" "Could not enable autoconnect for the connection '$conn_name'."
        return 0
    fi
    nmcli_run device set "$iface" autoconnect yes >/dev/null 2>&1 || true

    carrier=$(get_device_carrier "$iface")
    operstate=$(get_device_operstate "$iface")
    if [ "$carrier" != "1" ] && [ "$operstate" != "up" ]; then
        show_message "Warning" "Connection '$conn_name' was assigned to '$iface'. The link is currently down, so activation was not started."
        return 0
    fi

    ipv4_method=$(get_ipv4_method_for_conn "$conn_name")
    setsid "$NMCLI" connection up "$conn_name" ifname "$iface" >/dev/null 2>&1 &
    nmcli_pid=$!
    pgid=$(get_process_group_id "$nmcli_pid" || true)

    if [ "$ipv4_method" != "auto" ]; then
        wait "$nmcli_pid" 2>/dev/null || true
        ip=$(get_device_ipv4 "$iface")
        if [ -n "$ip" ]; then
            show_message "Success" "Connection '$conn_name' was activated on '$iface' with IP: $ip"
        else
            show_message "Success" "Connection '$conn_name' was activated on '$iface'."
        fi
        return 0
    fi

    (
        exec </dev/tty >/dev/tty 2>/dev/tty
        "$DIALOG" \
            --title "Waiting for DHCP" \
            --ok-label "Abort Waiting" \
            --msgbox "Connection: $conn_name\nInterface: $iface\n\nWaiting for activation / a DHCP address...\n\nPress ENTER, ESC, or OK to stop waiting.\nThe connection remains assigned." \
            12 70
    ) &
    wait_dialog_pid=$!

    while kill -0 "$nmcli_pid" 2>/dev/null; do
        sleep 1
        ip=$(get_device_ipv4 "$iface")
        if [ -n "$ip" ]; then
            close_wait_dialog "$wait_dialog_pid"
            wait "$nmcli_pid" 2>/dev/null || true
            show_message "Success" "Connection '$conn_name' was activated on '$iface' with IP: $ip"
            return 0
        fi

        carrier=$(get_device_carrier "$iface")
        if [ "$carrier" != "1" ]; then
            close_wait_dialog "$wait_dialog_pid"
            terminate_pid_or_group "$nmcli_pid" "$pgid"
            wait "$nmcli_pid" 2>/dev/null || true
            show_message "Warning" "Connection '$conn_name' remains assigned to '$iface', but the link went down before an IP address was received."
            return 0
        fi

        if ! kill -0 "$wait_dialog_pid" 2>/dev/null; then
            terminate_pid_or_group "$nmcli_pid" "$pgid"
            wait "$nmcli_pid" 2>/dev/null || true
            show_message "Warning" "Waiting for activation on '$iface' was aborted manually. Connection '$conn_name' remains assigned."
            return 0
        fi
    done

    close_wait_dialog "$wait_dialog_pid"
    nmcli_rc=0
    wait "$nmcli_pid" 2>/dev/null || nmcli_rc=$?

    ip=$(get_device_ipv4 "$iface")
    if [ -n "$ip" ]; then
        show_message "Success" "Connection '$conn_name' was activated on '$iface' with IP: $ip"
    elif [ "$nmcli_rc" -eq 0 ]; then
        show_message "Warning" "Connection '$conn_name' finished activation on '$iface', but no IP address was assigned."
    else
        show_message "Failure" "Activation of connection '$conn_name' on '$iface' failed."
    fi
}

create_new_connection() {
    local iface="$1"
    local conn_name mode ip_input gw="" dns=""
    local -a cmd=()

    while true; do
        if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Create Connection" --inputbox "Enter the connection name:" 8 60 2> "$TMPFILE"; then
            return 0
        fi
        conn_name=$(read_tmpfile)
        [ -n "$conn_name" ] && break
        show_message "Invalid" "The connection name must not be empty."
    done

    if ! "$DIALOG" --backtitle "$APP_TITLE" --title "IPv4 Method" --menu "Choose the method" 10 60 3 \
        static "Static IPv4" \
        dhcp "DHCP IPv4" \
        2> "$TMPFILE"; then
        return 0
    fi
    mode=$(read_tmpfile)

    case "$mode" in
        static)
            while true; do
                if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Static IPv4" --inputbox \
                    "Enter IPv4 + mask:\nExamples:\n 10.10.10.10/24\n 10.10.10.10 255.255.255.0" \
                    12 60 2> "$TMPFILE"; then
                    return 0
                fi
                ip_input=$(read_tmpfile)
                parse_static_ip_input "$ip_input" && break
                show_message "Invalid" "Invalid IPv4 or mask format."
            done
            while true; do
                if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Gateway" --inputbox "Enter the default gateway (optional):" 8 60 2> "$TMPFILE"; then
                    return 0
                fi
                gw=$(read_tmpfile)
                { [ -z "$gw" ] || is_valid_ipv4 "$gw"; } && break
                show_message "Invalid" "The gateway must be a valid IPv4 address."
            done
            while true; do
                if ! "$DIALOG" --backtitle "$APP_TITLE" --title "DNS" --inputbox "Enter DNS servers (comma-separated, optional):" 8 60 2> "$TMPFILE"; then
                    return 0
                fi
                dns=$(read_tmpfile)
                is_valid_dns_list "$dns" && break
                show_message "Invalid" "DNS must be a comma-separated list of IPv4 addresses."
            done
            ;;
        dhcp) ;;
        *)
            show_message "Failure" "Invalid IPv4 mode selected."
            return 0
            ;;
    esac

    cmd=(
        "$NMCLI" connection add
        type ethernet
        ifname "$iface"
        con-name "$conn_name"
        connection.interface-name "$iface"
        connection.autoconnect yes
        ipv6.method disabled
    )

    case "$mode" in
        static)
            cmd+=(ipv4.method manual ipv4.addresses "${STATIC_IP}/${STATIC_PREFIX}")
            [ -n "$gw" ] && cmd+=(ipv4.gateway "$gw")
            [ -n "$dns" ] && cmd+=(ipv4.dns "$dns")
            ;;
        dhcp)
            cmd+=(ipv4.method auto)
            ;;
    esac

    if ! "${cmd[@]}" >/dev/null 2>&1; then
        show_message "Failure" "Could not create the connection '$conn_name'."
        return 0
    fi

    show_message "Created" "Connection '$conn_name' was created."
}

set_interface_mtu() {
    local iface="$1"
    local current_mtu min_mtu max_mtu mtu_input
    local active_conn=""
    local errfile
    local carrier_wait=0
    local max_wait=10
    local carrier="0"

    errfile=$(mktemp)

    current_mtu=$(get_device_mtu "$iface")
    min_mtu="64"
    max_mtu="16000" 

    while true; do
        if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Set MTU" --inputbox \
            "Interface: $iface\nCurrent MTU: ${current_mtu:-unknown}\nRange depends on adapter:  $min_mtu - $max_mtu\n\nEnter the new MTU value:" \
            12 70 "${current_mtu:-}" 2> "$TMPFILE"; then
            rm -f "$errfile"
            return 0
        fi

        mtu_input=$(read_tmpfile)

        if ! [[ "$mtu_input" =~ ^[0-9]+$ ]]; then
            show_message "Invalid" "The MTU must be a numeric value."
            continue
        fi

        if [ "$mtu_input" -lt "$min_mtu" ] || [ "$mtu_input" -gt "$max_mtu" ]; then
            show_message "Invalid" "The MTU for '$iface' must be between $min_mtu and $max_mtu."
            continue
        fi

        active_conn=$(get_active_connection_for_iface "$iface")

        if [ -n "$active_conn" ]; then
            if ! "$NMCLI" connection down "$active_conn" >/dev/null 2>"$errfile"; then
                show_message "Error" "Could not temporarily disconnect '$active_conn' from '$iface'.\n\nNMCLI error:\n$(cat "$errfile")"
                rm -f "$errfile"
                return 0
            fi

            sleep 1
        fi

        if ! "$IPCMD" link set dev "$iface" down >/dev/null 2>"$errfile"; then
            [ -n "$active_conn" ] && "$NMCLI" connection up "$active_conn" ifname "$iface" >/dev/null 2>&1 || true
            show_message "Error" "Could not bring '$iface' down before changing the MTU.\n\nKernel/IP error:\n$(cat "$errfile")"
            rm -f "$errfile"
            return 0
        fi

        if ! "$IPCMD" link set dev "$iface" mtu "$mtu_input" >/dev/null 2>"$errfile"; then
            "$IPCMD" link set dev "$iface" up >/dev/null 2>&1 || true
            [ -n "$active_conn" ] && "$NMCLI" connection up "$active_conn" ifname "$iface" >/dev/null 2>&1 || true
            show_message "Error" "Could not set the MTU on '$iface'.\n\nKernel/IP error:\n$(cat "$errfile")"
            rm -f "$errfile"
            return 0
        fi

        if ! "$IPCMD" link set dev "$iface" up >/dev/null 2>"$errfile"; then
            [ -n "$active_conn" ] && "$NMCLI" connection up "$active_conn" ifname "$iface" >/dev/null 2>&1 || true
            show_message "Warning" "The MTU on '$iface' was changed to $mtu_input, but the interface could not be brought up cleanly.\n\nKernel/IP error:\n$(cat "$errfile")"
            rm -f "$errfile"
            return 0
        fi

        if [ -n "$active_conn" ]; then
            carrier_wait=0
            carrier="0"

            while [ "$carrier_wait" -lt "$max_wait" ]; do
                if [ -r "/sys/class/net/$iface/carrier" ]; then
                    carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)
                else
                    carrier="1"
                fi

                [ "$carrier" = "1" ] && break

                sleep 1
                carrier_wait=$((carrier_wait + 1))
            done

            if [ "$carrier" != "1" ]; then
                show_message "Warning" "The MTU on '$iface' was set to $mtu_input, but the link did not come back within ${max_wait}s. The connection '$active_conn' was not reactivated."
                rm -f "$errfile"
                return 0
            fi

            if ! "$NMCLI" connection up "$active_conn" ifname "$iface" >/dev/null 2>"$errfile"; then
                show_message "Warning" "The MTU on '$iface' was set to $mtu_input, but the connection '$active_conn' could not be reactivated.\n\nNMCLI error:\n$(cat "$errfile")"
                rm -f "$errfile"
                return 0
            fi

            show_message "MTU Updated" "The MTU on '$iface' was set to $mtu_input.\nThe connection '$active_conn' was restarted.\nThe connection profile was not changed."
        else
            show_message "MTU Updated" "The MTU on '$iface' was set to $mtu_input.\nNo active connection had to be restarted."
        fi

        rm -f "$errfile"
        return 0
    done
}
reset_interface_to_no_ip() {
    local iface="$1"
    local conn

    conn=$(get_active_connection_for_iface "$iface")
    if [ -n "$conn" ]; then
        nmcli_run connection modify "$conn" connection.autoconnect no >/dev/null 2>&1 || true
        nmcli_run connection down "$conn" >/dev/null 2>&1 || true
    fi

    nmcli_run device disconnect "$iface" >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.$iface.disable_ipv6=1" >/dev/null 2>&1 || true
    "$IPCMD" -4 addr flush dev "$iface" >/dev/null 2>&1 || true
    "$IPCMD" -6 addr flush dev "$iface" >/dev/null 2>&1 || true
    "$IPCMD" route flush dev "$iface" >/dev/null 2>&1 || true
    "$IPCMD" -6 route flush dev "$iface" >/dev/null 2>&1 || true
    "$IPCMD" link set dev "$iface" up >/dev/null 2>&1 || true
    "$IPCMD" -4 addr flush dev "$iface" >/dev/null 2>&1 || true
    "$IPCMD" -6 addr flush dev "$iface" >/dev/null 2>&1 || true

    show_message "Reset" "Interface '$iface' now has no IP address.\nReady for tcpdump."
}

disable_interface_link() {
    local iface="$1"
    "$IPCMD" link set dev "$iface" down && show_message "Disabled" "The interface link was disabled."
}

manage_connections_menu() {
    while true; do
        if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Connections" --menu "Manage connections" 15 70 5 \
            list "List connections" \
            delete "Delete connection" \
            show_config "Show configuration file" \
            2> "$TMPFILE"; then
            return 0
        fi

        case "$(read_tmpfile)" in
            list)
                nmcli_run connection show > "$TMPFILE"
                "$DIALOG" --backtitle "$APP_TITLE" --title "Connections" --textbox "$TMPFILE" 20 80
                ;;
            delete)
                local -a menu_args=()
                local conn
                if ! build_connection_menu_args_array menu_args; then
                    show_message "None" "No connections were found."
                    continue
                fi
                if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Delete" --menu "Select the connection" 0 0 0 "${menu_args[@]}" 2> "$TMPFILE"; then
                    continue
                fi
                conn=$(read_tmpfile)
                if ! "$DIALOG" --yesno "Delete '$conn'?" 7 50; then
                    continue
                fi
                if nmcli_run connection delete "$conn"; then
                    show_message "Deleted" "The connection was removed."
                else
                    show_message "Error" "Could not delete the connection '$conn'."
                fi
                ;;
            show_config)
                local -a menu_args=()
                local conn
                if ! build_connection_menu_args_array menu_args; then
                    show_message "None" "No connections were found."
                    continue
                fi
                if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Select Connection" --menu "Choose the connection" 0 0 0 "${menu_args[@]}" 2> "$TMPFILE"; then
                    continue
                fi
                conn=$(read_tmpfile)
                show_connection_file "$conn"
                ;;
        esac
    done
}

interface_menu() {
    local iface="$1"
    while true; do
        local conn gw_label current
        conn=$(get_active_connection_for_iface "$iface")
        if [ -z "$conn" ]; then
            gw_label="Toggle Default Gateway (no active connection)"
        else
            current=$(get_never_default_for_conn "$conn")
            if [ "$current" = "yes" ]; then
                gw_label="Enable Default Gateway (currently disabled)"
            else
                gw_label="Disable Default Gateway (currently enabled)"
            fi
        fi

        if ! "$DIALOG" --backtitle "$APP_TITLE" --title "Interface: $iface" --menu "Choose an action" 18 70 10 \
            show_config "Show interface configuration" \
            assign "Assign existing connection" \
            create "Create new connection" \
            route_add "Add static route" \
            route_del "Delete static route" \
            gw_toggle "$gw_label" \
            reset "Reset interface (enable & no IP)" \
            set_mtu "Change interface MTU temporary"\
            disable "Disable interface link" \
            2> "$TMPFILE"; then
            return 0
        fi

        case "$(read_tmpfile)" in
            show_config) show_interface_config "$iface" ;;
            assign)      assign_connection_to_interface "$iface" ;;
            create)      create_new_connection "$iface" ;;
            set_mtu)     set_interface_mtu "$iface" ;;
            route_add)   add_static_route "$iface" ;;
            route_del)   delete_static_route "$iface" ;;
            gw_toggle)   toggle_ipv4_defaultgw "$iface" ;;
            reset)       reset_interface_to_no_ip "$iface" ;;
            disable)     disable_interface_link "$iface" ;;
        esac
    done
}

main_menu() {
    while true; do
        "$DIALOG" --backtitle "$APP_TITLE" --title "Main Menu" --menu "Select an action" 18 70 10 \
            interfaces "Manage interfaces" \
            manage_conns "Manage connections" \
            show_all_info "Show all interface information" \
            show_routes "Show routing table" \
            exit "Exit" 2> "$TMPFILE" || exit 0

        case "$(read_tmpfile)" in
            interfaces)
                local -a menu_args=()
                read_menu_args_into build_interface_menu_args menu_args
                "$DIALOG" --backtitle "$APP_TITLE" --title "Interfaces" --menu "Select an interface" 0 0 0 "${menu_args[@]}" 2> "$TMPFILE" || continue
                interface_menu "$(read_tmpfile)"
                ;;
            manage_conns) manage_connections_menu ;;
            show_all_info) show_all_interfaces_info ;;
            show_routes) show_ip_route ;;
            exit) exit 0 ;;
        esac
    done
}

check_requirements
main_menu
