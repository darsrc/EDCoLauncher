#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# EDCoLauncher - patched and hardened
#
# What changed in this revision:
# - Uses the script directory instead of $PWD for config/log paths.
# - Resolves required tools explicitly and fails early with clear errors.
# - Fixes the MinEdLauncher game-window counter bug.
# - Uses the app-specific compatdata directory for STEAM_COMPAT_DATA_PATH.
# - Reduces default Wine logging noise to +err,+warn.
# - Guards RunningOnLinux INI edits when the files do not exist yet.
# - Stops treating EDCoPilotGUI2.exe as the only valid success condition.
# - Uses process-pattern checks after launch instead of only checking $!.
# - Adds a more reliable Steam Linux Runtime client path fallback.
# - Removes the accidental extra "EDCoPTER" argument when launching EDCoPTER.
# - Cleans up stale EDCoPilot / EDCoPTER processes from previous failed runs.
# - Improves quoting and path handling throughout.
# -----------------------------------------------------------------------------

set -o pipefail

# -----------------------------------------------------------------------------
# Script-local paths
# -----------------------------------------------------------------------------
# Use the directory that contains this script, not $PWD. Steam / Proton launchers
# often invoke scripts with a working directory that is not the script directory.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_file_path="${script_dir}/EDCoLauncher_config"
log_file_path="${script_dir}/EDCoLauncher.log"

# -----------------------------------------------------------------------------
# Command resolution helpers
# -----------------------------------------------------------------------------
# Steam Runtime environments sometimes have a reduced PATH. Resolve tools from
# common host locations as well, so the script behaves consistently.
resolve_cmd() {
    local name="$1"
    local candidate=""

    candidate="$(command -v -- "$name" 2>/dev/null || true)"
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in "/usr/bin/${name}" "/bin/${name}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

require_cmd() {
    local name="$1"
    local resolved=""

    resolved="$(resolve_cmd "$name" || true)"
    if [[ -z "$resolved" ]]; then
        echo "ERROR: Required command '${name}' was not found in PATH, /usr/bin, or /bin. Exiting." >&2
        exit 1
    fi

    printf '%s\n' "$resolved"
}

READLINK_BIN="$(require_cmd readlink)"
AWK_BIN="$(require_cmd awk)"
SED_BIN="$(require_cmd sed)"
GREP_BIN="$(require_cmd grep)"
PGREP_BIN="$(require_cmd pgrep)"
TEE_BIN="$(require_cmd tee)"
STDBUF_BIN="$(require_cmd stdbuf)"
CURL_BIN="$(require_cmd curl)"
HEAD_BIN="$(require_cmd head)"
DIRNAME_BIN="$(require_cmd dirname)"
BASENAME_BIN="$(require_cmd basename)"
RM_BIN="$(require_cmd rm)"

# tput is optional. If unavailable, colours are disabled.
TPUT_BIN="$(resolve_cmd tput || true)"

# -----------------------------------------------------------------------------
# General vars
# -----------------------------------------------------------------------------
username="$(whoami)"
os_pretty_name="$({ . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Unknown}"; } || echo "Unknown")"
os_id="$({ . /etc/os-release 2>/dev/null && echo "${ID:-unknown}"; } || echo "unknown")"
os_like="$({ . /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}"; } || true)"

# -----------------------------------------------------------------------------
# Text helpers
# -----------------------------------------------------------------------------
# Only emit colour when stdout is an interactive terminal and tput is present.
if [[ -t 1 && -n "${TPUT_BIN}" ]]; then
    colour_red="$(${TPUT_BIN} setaf 1)"
    colour_green="$(${TPUT_BIN} setaf 2)"
    colour_yellow="$(${TPUT_BIN} setaf 3)"
    colour_cyan="$(${TPUT_BIN} setaf 6)"
    colour_reset="$(${TPUT_BIN} sgr0)"
else
    colour_red=""
    colour_green=""
    colour_yellow=""
    colour_cyan=""
    colour_reset=""
fi

strip_colour() {
    "${SED_BIN}" -Eu 's/\x1b(\[[0-9;]*[mGK]|\(B)//g'
}

log_info() {
    echo "${colour_cyan}INFO:${colour_reset} $*"
}

log_warn() {
    echo "${colour_yellow}WARNING:${colour_reset} $*"
}

log_error() {
    echo "${colour_red}ERROR:${colour_reset} $*"
}

# Send output to the log file with timestamps and without ANSI colour escapes.
exec > >(
    "${STDBUF_BIN}" -oL "${TEE_BIN}" -a >(
        strip_colour | "${GREP_BIN}" --line-buffered . | while IFS= read -r line; do
            printf '%(%Y-%m-%d %H:%M:%S)T %s\n' -1 "$line"
        done >> "${log_file_path}"
    )
) 2>&1

log_info "Starting execution"

# -----------------------------------------------------------------------------
# Process helpers
# -----------------------------------------------------------------------------
pgrep_any() {
    local pattern="$1"
    "${PGREP_BIN}" -f -- "$pattern" >/dev/null 2>&1
}

pgrep_first() {
    local pattern="$1"
    "${PGREP_BIN}" -f -- "$pattern" 2>/dev/null | "${HEAD_BIN}" -n 1
}

pgrep_list() {
    local pattern="$1"
    "${PGREP_BIN}" -f -- "$pattern" 2>/dev/null || true
}

kill_pattern_term() {
    local pattern="$1"
    local pids=""

    pids="$(pgrep_list "$pattern")"
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -15 $pids >/dev/null 2>&1 || true
    fi
}

kill_pattern_kill() {
    local pattern="$1"
    local pids=""

    pids="$(pgrep_list "$pattern")"
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids >/dev/null 2>&1 || true
    fi
}

wait_for_process_pattern() {
    # Generic countdown-based wait loop.
    local pattern="$1"
    local timeout="$2"
    local label="$3"
    local count=0

    while ! pgrep_any "$pattern"; do
        local seconds_left=$(( timeout - count ))
        echo -ne "${seconds_left} seconds remaining...\r"

        if (( count >= timeout )); then
            echo
            log_error "Failed to detect ${label} after ${timeout} seconds. Exiting"
            return 1
        fi

        sleep 1
        ((count++))
    done

    echo
    return 0
}

# -----------------------------------------------------------------------------
# Steam vars
# -----------------------------------------------------------------------------
steam_install_type="Unknown"

if [[ -f "/.flatpak-info" ]] && [[ "${FLATPAK_ID:-}" == "com.valvesoftware.Steam" ]]; then
    log_info "This is a Flatpak install of Steam"
    steam_install_type="Flatpak"
else
    log_info "This is a Native install of Steam"
    steam_install_type="Native"
fi

steam_install_path="$(${READLINK_BIN} -f "$HOME/.steam/root")"

if [[ ! -d "${steam_install_path}" ]]; then
    log_error "Couldn't find your Steam install path. If you're using a flatpak install, run this from the game's Launch Options instead of manually. Exiting."
    exit 1
fi

steam_base_path="${steam_install_path}/steamapps"
steam_pressure_vessel_bin_path="${steam_base_path}/common/SteamLinuxRuntime_sniper/pressure-vessel/bin"
steam_compat_data_path="${steam_base_path}/compatdata"
steam_library_file="${steam_install_path}/config/libraryfolders.vdf"

if [[ ! -f "${steam_library_file}" ]]; then
    log_error "Couldn't find Steam libraryfolders.vdf at: ${steam_library_file}. Exiting."
    exit 1
fi

# -----------------------------------------------------------------------------
# Elite Dangerous vars
# -----------------------------------------------------------------------------
ed_app_id="359320"
ed_wine_prefix=""
ed_steam_library_base_path=""

mapfile -t ed_library_paths < <(
    "${AWK_BIN}" -v appid="${ed_app_id}" '
        /"path"/ {
            current_path = $2
            gsub(/"/, "", current_path)
        }
        /"apps"/ { in_apps = 1 }
        in_apps && $1 ~ "\""appid"\"" {
            print current_path
        }
        /}/ && in_apps { in_apps = 0 }
    ' "${steam_library_file}"
)

for path in "${ed_library_paths[@]}"; do
    full_prefix="${path}/steamapps/compatdata/${ed_app_id}/pfx"
    if [[ -e "${full_prefix}" ]]; then
        ed_wine_prefix="${full_prefix}"
        ed_steam_library_base_path="${path}"
        break
    fi
done

if [[ -z "${ed_wine_prefix}" ]]; then
    log_error "Couldn't find a suitable game prefix in libraryfolders.vdf. Make sure the Steam library containing Elite Dangerous is accessible."
    exit 1
fi

ed_compatdata_dir="$(${DIRNAME_BIN} -- "${ed_wine_prefix%/}")"
config_info_path="${ed_compatdata_dir}/config_info"

if [[ -f "${config_info_path}" ]]; then
    ed_proton_path="$(${GREP_BIN} -m 1 -E '/(common|compatibilitytools\.d)/[^/]*(Proton|proton)' "${config_info_path}" | "${SED_BIN}" 's|/files/.*||')"
else
    ed_proton_path=""
fi

if [[ -z "${ed_proton_path}" ]]; then
    log_error "Couldn't determine the Proton path from: ${config_info_path}. Exiting."
    exit 1
fi

# -----------------------------------------------------------------------------
# WINE & Steam environment vars
# -----------------------------------------------------------------------------
export WINEFSYNC=1
export WINEPREFIX="${ed_wine_prefix}"
export WINELOADER="${ed_proton_path}/files/bin/wine"
export WINESERVER="${ed_proton_path}/files/bin/wineserver"
export SteamGameId="${ed_app_id}"
export STEAM_COMPAT_DATA_PATH="${ed_compatdata_dir}"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="${steam_install_path}"
export STEAM_LINUX_RUNTIME_LOG=1
export STEAM_LINUX_RUNTIME_VERBOSE=1
export PROTON_LOG=1
export PROTON_WINE="${WINELOADER}"
export WINEDEBUG="${WINEDEBUG_CHANNELS:-+err,+warn}"
unset LD_PRELOAD
unset LD_LIBRARY_PATH

if [[ ! -x "${WINELOADER}" ]]; then
    log_error "WINELOADER not found or not executable: ${WINELOADER}. Exiting."
    exit 1
fi

if [[ ! -x "${WINESERVER}" ]]; then
    log_error "WINESERVER not found or not executable: ${WINESERVER}. Exiting."
    exit 1
fi

# -----------------------------------------------------------------------------
# EDCoPilot & EDCoPTER vars
# -----------------------------------------------------------------------------
edcopilot_log_file="${script_dir}/EDCoLauncher_EDCoPilot.log"
edcopter_log_file="${script_dir}/EDCoLauncher_EDCoPTER.log"
edcopilot_install_log_file="${script_dir}/EDCoLauncher_EDCoPilot_Install.log"
edcopter_install_log_file="${script_dir}/EDCoLauncher_EDCoPTER_Install.log"
edcopilot_default_install_exe_path="${ed_wine_prefix}/drive_c/EDCoPilot/LaunchEDCoPilot.exe"
edcopter_default_per_user_exe_path="${ed_wine_prefix}/drive_c/users/steamuser/AppData/Local/Programs/EDCoPTER/EDCoPTER.exe"
edcopter_default_all_users_exe_path="${ed_wine_prefix}/drive_c/Program Files/EDCoPTER/EDCoPTER.exe"

if [[ -f "${edcopter_default_per_user_exe_path}" ]]; then
    edcopter_default_install_exe_path="${edcopter_default_per_user_exe_path}"
else
    edcopter_default_install_exe_path="${edcopter_default_all_users_exe_path}"
fi

edcopilot_process_pattern='EDCoPilot\.exe|LaunchEDCoPilot\.exe|EDCoPilotGUI2\.exe'
edcopter_process_pattern='EDCoPTER\.exe'

# -----------------------------------------------------------------------------
# Handle config file
# -----------------------------------------------------------------------------
if [[ -f "${config_file_path}" ]]; then
    # shellcheck disable=SC1090
    . "${config_file_path}"
else
    log_warn "Config file does not exist. Using defaults."
fi

# General settings
install_edcopilot="${INSTALL_EDCOPILOT:-false}"
install_edcopter="${INSTALL_EDCOPTER:-false}"
launcher_detection_timeout="${LAUNCHER_DETECTION_TIMEOUT:-30}"

# EDCoPilot Settings
edcopilot_enabled="${EDCOPILOT_ENABLED:-true}"
edcopilot_detection_timeout="${EDCOPILOT_DETECTION_TIMEOUT:-50}"

# EDCoPTER Settings
edcopter_enabled="${EDCOPTER_ENABLED:-true}"
edcopter_headless_enabled="${EDCOPTER_HEADLESS_ENABLED:-false}"
edcopter_listen_port="${EDCOPTER_LISTEN_PORT:-}"
edcopter_listen_ip="${EDCOPTER_LISTEN_IP:-}"
edcopter_edcopilot_server_ip="${EDCOPTER_EDCOPILOT_SERVER_IP:-}"

# Stability options
hotas_fix_enabled="${HOTAS_FIX_ENABLED:-true}"

# Optional paths
edcopilot_path="${EDCOPILOT_EXE_PATH:-}"
edcopter_path="${EDCOPTER_EXE_PATH:-}"

# Handle empty path variables
if [[ -z "${edcopilot_path}" ]]; then
    edcopilot_final_path="${edcopilot_default_install_exe_path}"
else
    edcopilot_final_path="${edcopilot_path}"
fi

if [[ -z "${edcopter_path}" ]]; then
    edcopter_final_path="${edcopter_default_install_exe_path}"
else
    edcopter_final_path="${edcopter_path}"
fi

# -----------------------------------------------------------------------------
# Pre-flight cleanup
# -----------------------------------------------------------------------------
for tmp_log in "${edcopilot_log_file}" "${edcopter_log_file}"; do
    if [[ -f "${tmp_log}" ]]; then
        log_info "Cleaning up temp log file: ${tmp_log}"
        "${RM_BIN}" -f -- "${tmp_log}"
    fi
done

# Remove stale EDCoPilot request files from previous failed runs.
stale_request_file="$(${DIRNAME_BIN} -- "${edcopilot_final_path}")/EDCoPilot.request.txt"
if [[ -f "${stale_request_file}" ]]; then
    log_info "Removing stale EDCoPilot request file"
    "${RM_BIN}" -f -- "${stale_request_file}"
fi

# Kill stale processes left behind by earlier failed runs.
if pgrep_any "${edcopilot_process_pattern}"; then
    log_warn "Found stale EDCoPilot processes from a previous run. Terminating them before launch."
    kill_pattern_term "${edcopilot_process_pattern}"
    sleep 2
    if pgrep_any "${edcopilot_process_pattern}"; then
        kill_pattern_kill "${edcopilot_process_pattern}"
    fi
fi

if pgrep_any "${edcopter_process_pattern}"; then
    log_warn "Found stale EDCoPTER processes from a previous run. Terminating them before launch."
    kill_pattern_term "${edcopter_process_pattern}"
    sleep 2
    if pgrep_any "${edcopter_process_pattern}"; then
        kill_pattern_kill "${edcopter_process_pattern}"
    fi
fi

# -----------------------------------------------------------------------------
# Check for existing installs
# -----------------------------------------------------------------------------
edcopilot_installed="false"
edcopter_installed="false"

if [[ -f "${edcopilot_final_path}" ]]; then
    edcopilot_installed="true"
fi

if [[ -f "${edcopter_final_path}" ]]; then
    edcopter_installed="true"
fi

# -----------------------------------------------------------------------------
# Print configuration summary
# -----------------------------------------------------------------------------
echo "${colour_cyan}Current User:${colour_reset} ${username}"
echo "${colour_cyan}OS Pretty Name:${colour_reset} ${os_pretty_name}"
echo "${colour_cyan}OS ID:${colour_reset} ${os_id}"
echo "${colour_cyan}OS Like:${colour_reset} ${os_like}"
echo "${colour_cyan}Config File Path:${colour_reset} ${config_file_path}"
echo "--"
echo "${colour_cyan}Steam Install Type:${colour_reset} ${steam_install_type}"
echo "${colour_cyan}Steam Install Path:${colour_reset} ${steam_install_path}"
echo "${colour_cyan}Steam Library File Path:${colour_reset} ${steam_library_file}"
echo "--"
echo "${colour_cyan}Elite Dangerous Steam Library Path:${colour_reset} ${ed_steam_library_base_path}"
echo "${colour_cyan}Elite Dangerous Wine Prefix:${colour_reset} ${ed_wine_prefix}"
echo "${colour_cyan}Elite Dangerous Proton Path:${colour_reset} ${ed_proton_path}"
echo "${colour_cyan}Elite Dangerous Steam App ID:${colour_reset} ${ed_app_id}"
echo "--"
echo "${colour_cyan}EDCoPilot Installed:${colour_reset} ${edcopilot_installed}"
echo "${colour_cyan}EDCoPilot Path:${colour_reset} ${edcopilot_final_path}"
echo "${colour_cyan}EDCoPilot Enabled:${colour_reset} ${edcopilot_enabled}"
echo "--"
echo "${colour_cyan}EDCoPTER Installed:${colour_reset} ${edcopter_installed}"
echo "${colour_cyan}EDCoPTER Path:${colour_reset} ${edcopter_final_path}"
echo "${colour_cyan}EDCoPTER Enabled:${colour_reset} ${edcopter_enabled}"
echo "${colour_cyan}EDCoPTER Headless Mode Enabled:${colour_reset} ${edcopter_headless_enabled}"
echo "${colour_cyan}EDCoPTER Listen IP Override:${colour_reset} ${edcopter_listen_ip}"
echo "${colour_cyan}EDCoPTER Listen Port Override:${colour_reset} ${edcopter_listen_port}"
echo "${colour_cyan}EDCoPTER EDCoPilot Server IP Override:${colour_reset} ${edcopter_edcopilot_server_ip}"
echo "--"
echo "${colour_cyan}HOTAS Fix Enabled:${colour_reset} ${hotas_fix_enabled}"
echo ""

# -----------------------------------------------------------------------------
# Install logic
# -----------------------------------------------------------------------------
edcopter_install_failed="false"

set_config_flag_false() {
    local key="$1"
    if [[ -f "${config_file_path}" ]]; then
        "${SED_BIN}" -i "s/^${key}=.*/${key}=\"false\"/" "${config_file_path}"
    else
        log_warn "Cannot update ${key} in config because ${config_file_path} does not exist."
    fi
}

if [[ "${install_edcopilot}" == "true" ]]; then
    if [[ "${edcopilot_installed}" == "false" ]]; then
        latest_edcopilot_msi_url="$(${CURL_BIN} -fsSL "https://api.github.com/repos/Razzafrag/EDCoPilot-Installer/releases/latest" | "${SED_BIN}" -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\.msi\)".*/\1/p' | "${HEAD_BIN}" -n 1)"

        if [[ -z "${latest_edcopilot_msi_url}" ]]; then
            log_error "Failed to determine the latest EDCoPilot MSI download URL. Exiting."
            exit 1
        fi

        latest_edcopilot_msi_name="$(${BASENAME_BIN} -- "${latest_edcopilot_msi_url}")"
        latest_edcopilot_msi_path="${ed_wine_prefix}/drive_c/${latest_edcopilot_msi_name}"

        log_info "Downloading EDCoPilot installer. Please wait..."
        "${CURL_BIN}" -fsSL -o "${latest_edcopilot_msi_path}" "${latest_edcopilot_msi_url}"

        log_info "Installing EDCoPilot. Please wait..."
        "${WINELOADER}" start /wait msiexec /i "${latest_edcopilot_msi_path}" /quiet /qn /norestart > "${edcopilot_install_log_file}" 2>&1
        sleep 2

        if [[ ! -f "${edcopilot_final_path}" ]]; then
            log_error "It looks like EDCoPilot wasn't installed properly. Check the install log here: ${edcopilot_install_log_file}"
            exit 1
        fi

        log_info "EDCoPilot was installed successfully. Setting INSTALL_EDCOPILOT back to false."
        edcopilot_installed="true"
        set_config_flag_false "INSTALL_EDCOPILOT"

        log_info "Cleaning up EDCoPilot installer"
        "${RM_BIN}" -f -- "${latest_edcopilot_msi_path}"
    else
        log_warn "INSTALL_EDCOPILOT was true, but an existing EDCoPilot install was found at: $("${DIRNAME_BIN}" -- "${edcopilot_final_path}"). Setting INSTALL_EDCOPILOT back to false."
        set_config_flag_false "INSTALL_EDCOPILOT"
    fi
fi

if [[ "${install_edcopter}" == "true" ]]; then
    if [[ -f "${edcopilot_final_path}" ]]; then
        if [[ ! -f "${edcopter_final_path}" ]]; then
            latest_edcopter_exe_url="$(${CURL_BIN} -fsSL "https://api.github.com/repos/markhollingworth-worthit/EDCoPTER2.0-public-releases/releases/latest" | "${SED_BIN}" -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\.exe\)".*/\1/p' | "${HEAD_BIN}" -n 1)"

            if [[ -z "${latest_edcopter_exe_url}" ]]; then
                log_error "Failed to determine the latest EDCoPTER EXE download URL. Exiting."
                exit 1
            fi

            latest_edcopter_exe_name="$(${BASENAME_BIN} -- "${latest_edcopter_exe_url}")"
            latest_edcopter_exe_path="${ed_wine_prefix}/drive_c/${latest_edcopter_exe_name}"

            log_info "Downloading EDCoPTER installer. Please wait..."
            "${CURL_BIN}" -fsSL -o "${latest_edcopter_exe_path}" "${latest_edcopter_exe_url}"

            log_info "Installing EDCoPTER. Please wait..."
            "${WINELOADER}" start /wait /unix "${latest_edcopter_exe_path}" /S /allusers /D="C:\Program Files\EDCoPTER" > "${edcopter_install_log_file}" 2>&1
            sleep 2

            if [[ ! -f "${edcopter_final_path}" ]]; then
                log_error "It looks like EDCoPTER wasn't installed properly. Check the install log here: ${edcopter_install_log_file}"
                edcopter_install_failed="true"
            else
                log_info "EDCoPTER was installed successfully. Setting INSTALL_EDCOPTER back to false."
                edcopter_installed="true"
                set_config_flag_false "INSTALL_EDCOPTER"
            fi

            log_info "Cleaning up EDCoPTER installer"
            "${RM_BIN}" -f -- "${latest_edcopter_exe_path}"
        else
            log_warn "INSTALL_EDCOPTER was true, but an existing EDCoPTER install was found at: $("${DIRNAME_BIN}" -- "${edcopter_final_path}"). Setting INSTALL_EDCOPTER back to false."
            set_config_flag_false "INSTALL_EDCOPTER"
        fi
    else
        log_warn "Can't install EDCoPTER because a valid EDCoPilot install was not detected."
    fi
fi

# -----------------------------------------------------------------------------
# Wait for the Elite Dangerous Launcher OR MinEdLauncher to start
# -----------------------------------------------------------------------------
launcher_detection_count=0
launcher_detection_interval=1

log_info "Waiting for Elite Dangerous Launcher or MinEdLauncher to start for ${launcher_detection_timeout} seconds. You can change this value in the config file."
while ! pgrep_any '[ZX]:.*steamapps.common.Elite Dangerous.EDLaunch.exe.*' && ! pgrep_any 'MinEdLauncher'; do
    seconds_left=$(( launcher_detection_timeout - launcher_detection_count ))
    echo -ne "${seconds_left} seconds remaining...\r"

    if (( launcher_detection_count >= launcher_detection_timeout )); then
        echo
        log_error "Failed to detect a running launcher. Exiting"
        exit 1
    fi

    sleep "${launcher_detection_interval}"
    ((launcher_detection_count++))
done

echo
log_info "Found a launcher. Determining the launcher type..."

# The script monitors a single anchor process. For MinEdLauncher, we anchor to the
# actual game window process (EliteDangerous64.exe). For the stock launcher, we
# anchor to EDLaunch.exe.
ed_anchor_pid=""
steam_linux_client_runtime_cmd=""

if pgrep_any 'MinEdLauncher'; then
    log_info "Detected MinEdLauncher. Waiting for game window to spawn..."

    game_window_detection_count=0
    game_window_detection_timeout=60
    while ! pgrep_any '[ZX]:.*EliteDangerous64.exe'; do
        seconds_left=$(( game_window_detection_timeout - game_window_detection_count ))
        echo -ne "${seconds_left} seconds remaining...\r"

        if (( game_window_detection_count >= game_window_detection_timeout )); then
            echo
            log_error "Failed to detect a running game window. Exiting"
            exit 1
        fi

        sleep 1
        ((game_window_detection_count++))
    done

    echo
    log_info "Getting game window PID..."
    ed_anchor_pid="$(pgrep_first '[ZX]:.*EliteDangerous64.exe')"

    log_info "Getting path to the Steam Linux Runtime Client..."
    steam_runtime_root="$(${PGREP_BIN} -fa 'SteamLinuxRuntime_.*/pressure-vessel.*/EliteDangerous64.exe' 2>/dev/null | "${SED_BIN}" -n 's|.* \(/[^ ]*/SteamLinuxRuntime_[^/]*/pressure-vessel\)/.*|\1|p' | "${HEAD_BIN}" -n 1)"
else
    log_info "Detected Elite Dangerous Launcher. Getting launcher PID..."
    ed_anchor_pid="$(pgrep_first '[ZX]:.*steamapps.common.Elite Dangerous.EDLaunch.exe.*')"

    log_info "Getting path to the Steam Linux Runtime Client..."
    steam_runtime_root="$(${PGREP_BIN} -fa 'SteamLinuxRuntime_.*pressure-vessel.*/EDLaunch.exe' 2>/dev/null | "${SED_BIN}" -n 's|.* \(/[^ ]*/SteamLinuxRuntime_[^/]*/pressure-vessel\)/.*|\1|p' | "${HEAD_BIN}" -n 1)"
fi

if [[ -n "${ed_anchor_pid}" ]]; then
    log_info "Elite Dangerous anchor PID: ${ed_anchor_pid}. Preparing to launch add-ons..."
else
    log_error "Couldn't determine the Elite Dangerous anchor PID. Exiting."
    exit 1
fi

# Prefer the runtime path discovered from the actual game process. If that fails,
# fall back to the standard Steam runtime location.
if [[ -n "${steam_runtime_root}" && -x "${steam_runtime_root}/bin/steam-runtime-launch-client" ]]; then
    steam_linux_client_runtime_cmd="${steam_runtime_root}/bin/steam-runtime-launch-client"
elif [[ -x "${steam_pressure_vessel_bin_path}/steam-runtime-launch-client" ]]; then
    steam_linux_client_runtime_cmd="${steam_pressure_vessel_bin_path}/steam-runtime-launch-client"
fi

if [[ -z "${steam_linux_client_runtime_cmd}" || ! -x "${steam_linux_client_runtime_cmd}" ]]; then
    log_error "Couldn't find a valid Steam Linux Client Runtime binary. Last attempted path: ${steam_linux_client_runtime_cmd:-<none>}. Exiting."
    exit 1
else
    log_info "Steam Linux Client Runtime Path: ${steam_linux_client_runtime_cmd}"
fi

# -----------------------------------------------------------------------------
# Manage windows.gaming.input to fix HOTAS crash problem
# -----------------------------------------------------------------------------
if "${WINELOADER}" reg query 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' /v 'windows.gaming.input' &>/dev/null; then
    log_info "The HOTAS fix to override windows.gaming.input is currently active."
    if [[ "${hotas_fix_enabled}" != "true" ]]; then
        if "${WINELOADER}" reg delete 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' /v 'windows.gaming.input' /f &>/dev/null; then
            log_info "Removed the windows.gaming.input DLL override from the Wine prefix. The HOTAS fix is now NOT active."
        else
            log_warn "Failed to remove the windows.gaming.input DLL override from the Wine prefix. Consider doing this manually with protontricks."
        fi
    fi
else
    if [[ "${hotas_fix_enabled}" == "true" ]]; then
        log_info "The HOTAS fix to override windows.gaming.input was not found."
        if "${WINELOADER}" reg add 'HKEY_CURRENT_USER\Software\Wine\DllOverrides' /v 'windows.gaming.input' /t REG_SZ /d '' /f &>/dev/null; then
            log_info "Added the windows.gaming.input DLL override to the Wine prefix. The HOTAS fix is now active."
        else
            log_warn "Failed to add the windows.gaming.input DLL override to the Wine prefix. Consider doing this manually with protontricks."
        fi
    fi
fi

# -----------------------------------------------------------------------------
# Launch EDCoPilot
# -----------------------------------------------------------------------------
set_running_on_linux_flag() {
    # Some installs do not generate these INI files until first launch. We update
    # them only when they exist, instead of treating their absence as a hard error.
    local edcopilot_dir=""
    local ini=""

    edcopilot_dir="$(${DIRNAME_BIN} -- "${edcopilot_final_path}")"

    log_info "Setting the EDCoPilot RunningOnLinux flag to 1. This might need a relaunch to take effect."
    for ini in "${edcopilot_dir}/EDCoPilot.ini" "${edcopilot_dir}/edcopilotgui.ini"; do
        if [[ -f "${ini}" ]]; then
            if "${GREP_BIN}" -q 'RunningOnLinux="0"' "${ini}"; then
                "${SED_BIN}" -i 's/RunningOnLinux="0"/RunningOnLinux="1"\r/' "${ini}"
            fi
        else
            log_warn "${ini} was not found yet; skipping RunningOnLinux edit for this file."
        fi
    done
}

if [[ "${edcopilot_enabled}" == "true" && "${edcopilot_installed}" == "true" ]]; then
    set_running_on_linux_flag
    sleep 1

    echo
    log_info "Launching EDCoPilot"

    "${steam_linux_client_runtime_cmd}" \
        --bus-name="com.steampowered.App${ed_app_id}" \
        --pass-env-matching='WINE*' \
        --pass-env-matching='STEAM*' \
        --pass-env-matching='PROTON*' \
        --env="SteamGameId=${ed_app_id}" \
        -- "${WINELOADER}" "${edcopilot_final_path}" > "${edcopilot_log_file}" 2>&1 &
    edcopilot_runtime_pid=$!

    sleep 4

    # Do not rely only on $!, because steam-runtime-launch-client may fork while
    # the real child process continues running. We care about the EDCoPilot
    # processes themselves.
    if pgrep_any "${edcopilot_process_pattern}"; then
        log_info "EDCoPilot launched successfully (wrapper PID: ${edcopilot_runtime_pid})"
    else
        log_error "EDCoPilot failed to start or crashed immediately. Check ${edcopilot_log_file}"
        exit 1
    fi
else
    log_error "EDCoPilot was either disabled in the config or not found at: ${edcopilot_final_path}. Exiting."
    exit 1
fi

# -----------------------------------------------------------------------------
# Allow EDCoPilot to initialise
# -----------------------------------------------------------------------------
log_info "Waiting for EDCoPilot to fully initialise..."

edcopilot_detection_count=0
edcopilot_detection_interval=1

# NOTE:
# EDCoPilotGUI2.exe is the remote UI executable and should not be required for a
# successful local launch. Treat any EDCoPilot process as an acceptable success
# signal here.
while ! pgrep_any "${edcopilot_process_pattern}"; do
    seconds_left=$(( edcopilot_detection_timeout - edcopilot_detection_count ))
    echo -ne "${seconds_left} seconds remaining...\r"

    if (( edcopilot_detection_count >= edcopilot_detection_timeout )); then
        echo
        log_error "Failed to find a running EDCoPilot process after ${edcopilot_detection_timeout} seconds. Exiting."
        kill_pattern_term "${edcopilot_process_pattern}"
        exit 1
    fi

    sleep "${edcopilot_detection_interval}"
    ((edcopilot_detection_count++))
done

echo
initialise_count=35
log_info "Detected an EDCoPilot process. Waiting ${initialise_count} seconds for it to initialise..."
while (( initialise_count >= 0 )); do
    sleep 1
    ((initialise_count--))
done

# -----------------------------------------------------------------------------
# Start EDCoPTER
# -----------------------------------------------------------------------------
if [[ "${edcopter_enabled}" == "true" && "${edcopter_installed}" == "true" ]]; then
    echo
    log_info "Building EDCoPTER command-line arguments..."

    edcopter_runtime_args=()

    if [[ "${edcopter_headless_enabled}" == "true" ]]; then
        edcopter_runtime_args+=("--headless")
    fi

    if [[ -n "${edcopter_listen_ip}" ]]; then
        edcopter_runtime_args+=("--ip" "${edcopter_listen_ip}")
    fi

    if [[ -n "${edcopter_listen_port}" ]]; then
        edcopter_runtime_args+=("--port" "${edcopter_listen_port}")
    fi

    if [[ -n "${edcopter_edcopilot_server_ip}" ]]; then
        edcopter_runtime_args+=("--edcopilot-ip" "${edcopter_edcopilot_server_ip}")
    fi

    log_info "Launching EDCoPTER"
    "${steam_linux_client_runtime_cmd}" \
        --bus-name="com.steampowered.App${ed_app_id}" \
        --pass-env-matching='WINE*' \
        --pass-env-matching='STEAM*' \
        --pass-env-matching='PROTON*' \
        --env="SteamGameId=${ed_app_id}" \
        -- "${WINELOADER}" "${edcopter_final_path}" "${edcopter_runtime_args[@]}" > "${edcopter_log_file}" 2>&1 &
    edcopter_runtime_pid=$!

    sleep 4

    if pgrep_any "${edcopter_process_pattern}" || kill -0 "${edcopter_runtime_pid}" 2>/dev/null; then
        log_info "EDCoPTER launched successfully (wrapper PID: ${edcopter_runtime_pid})"
    else
        log_error "EDCoPTER failed to start or crashed immediately. Check ${edcopter_log_file}"
    fi
else
    log_warn "EDCoPTER was either disabled in the config or not found at: ${edcopter_final_path}. Consider installing EDCoPTER or setting its enabled flag to false."
fi

# -----------------------------------------------------------------------------
# Monitor the launcher / game anchor and exit add-ons when it closes
# -----------------------------------------------------------------------------
echo
log_info "To close EDCoPilot and EDCoPTER, close the Elite Dangerous launcher / game window."

while kill -0 "${ed_anchor_pid}" 2>/dev/null; do
    sleep 1
done

# -----------------------------------------------------------------------------
# Shut down EDCoPTER
# -----------------------------------------------------------------------------
log_info "Closing EDCoPTER. Please wait."
kill_pattern_term "${edcopter_process_pattern}"

# -----------------------------------------------------------------------------
# Gracefully shut down EDCoPilot
# -----------------------------------------------------------------------------
log_info "Closing EDCoPilot. Please wait."

if pgrep_any "${edcopilot_process_pattern}"; then
    request_file="$(${DIRNAME_BIN} -- "${edcopilot_final_path}")/EDCoPilot.request.txt"

    # If EDCoPilot supports request-file shutdown, prefer that first.
    log_info "Sending graceful shutdown request."
    echo Shutdown >> "${request_file}"

    shutdown_timeout=30
    shutdown_count=0

    while pgrep_any "${edcopilot_process_pattern}"; do
        seconds_left=$(( shutdown_timeout - shutdown_count ))
        echo -ne "${seconds_left} seconds remaining...\r"

        if (( shutdown_count >= shutdown_timeout )); then
            echo
            log_error "EDCoPilot failed to exit after ${shutdown_timeout} seconds. Forcefully killing the processes..."
            kill_pattern_kill "${edcopilot_process_pattern}"
            break
        fi

        sleep 1
        ((shutdown_count++))
    done

    echo
    log_info "EDCoPilot has closed successfully."
    "${RM_BIN}" -f -- "${request_file}" >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Ensure all processes in the Wine prefix are stopped properly
# -----------------------------------------------------------------------------
log_info "Closing EDCoPTER and cleaning up Wine prefix subprocesses."
"${WINESERVER}" -k
"${WINESERVER}" -w

log_info "All done! Exiting."
