#!/usr/bin/env bash
# Common launcher functions for Figma Desktop (AppImage, deb, and rpm).

# Setup logging directory and file
# Sets: log_dir, log_file
setup_logging() {
	log_dir="${XDG_CACHE_HOME:-$HOME/.cache}/figma-desktop-linux"
	mkdir -p "$log_dir" || return 1
	log_file="$log_dir/launcher.log"
}

# Log a message to the log file
# Usage: log_message "message"
log_message() {
	echo "$1" >> "$log_file"
}

# Detect display backend (Wayland vs X11)
# Sets: is_wayland, use_x11_on_wayland
detect_display_backend() {
	# Detect if Wayland is running
	is_wayland=false
	[[ -n ${WAYLAND_DISPLAY:-} ]] && is_wayland=true

	# Default: Use native Wayland on Wayland for touchpad gestures and performance
	# Use X11/XWayland if explicitly requested via FIGMA_USE_X11=1 or FIGMA_USE_WAYLAND=0.
	use_x11_on_wayland=false
	if [[ ${FIGMA_USE_X11:-} == '1' || ${FIGMA_USE_WAYLAND:-} == '0' ]]; then
		use_x11_on_wayland=true
	fi
	return 0
}

# Check if we have a valid display (not running from TTY)
# Returns: 0 if display available, 1 if not
check_display() {
	[[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]]
}

# Keep Electron's graphics defaults unless X11 is confirmed to lack GLX.
# The optional probe is bounded and never examines X11 when using native Wayland.
select_renderer() {
	local requested_renderer=${FIGMA_RENDERER:-auto}
	selected_renderer='hardware'
	case "$requested_renderer" in
		hardware) log_message 'Renderer: Electron defaults (hardware requested)' ;;
		software) selected_renderer='software'; log_message 'Renderer: SwiftShader (software requested)' ;;
		auto)
			local display_info
			if [[ ( $is_wayland != true || $use_x11_on_wayland == true ) && -n ${DISPLAY:-} ]] \
				&& command -v xdpyinfo > /dev/null 2>&1 && command -v timeout > /dev/null 2>&1 \
				&& display_info=$(LC_ALL=C timeout 3s xdpyinfo -display "$DISPLAY" -queryExtensions 2>/dev/null) \
				&& [[ $display_info == *'number of extensions:'* ]]; then
				if [[ ! $display_info =~ (^|[[:space:]])GLX([[:space:]]|$) ]]; then
					selected_renderer='software'
					log_message 'Renderer: SwiftShader (X11 display has no GLX)'
				else
					log_message 'Renderer: Electron defaults (X11 GLX available)'
				fi
			else
				log_message 'Renderer: Electron defaults (native Wayland or X11 probe unavailable)'
			fi
			;;
		*)
			echo "Invalid FIGMA_RENDERER: $requested_renderer (expected auto, hardware, or software)" >&2
			return 1
			;;
	esac
	if [[ $selected_renderer == 'software' ]]; then
		# SwiftShader as an OpenGL ES driver; keep WebGL enabled.
		electron_args+=('--use-gl=angle' '--use-angle=swiftshader')
	fi
}

# Build Electron arguments array based on display backend
# Requires: is_wayland, use_x11_on_wayland to be set
#           (call detect_display_backend first)
# Sets: electron_args array
# The optional package-type argument is accepted by all package launchers.
build_electron_args() {
	electron_args=()

	# Disable Chromium sandbox for all package types. Figma's
	# web_app_binding_renderer.js preload uses process.getSystemMemoryInfo()
	# and process.getHeapStatistics(), which Electron blocks inside a sandboxed
	# renderer. Without this flag, the preload fails to load and the desktop
	# bridge never initializes, so OAuth callbacks ("Unable to get profile
	# information from Google") and IPC silently break. AppImage already needed
	# this for FUSE; deb/rpm need it for the preload.
	electron_args+=('--no-sandbox')

	# Disable CustomTitlebar for better Linux integration
	electron_args+=('--disable-features=CustomTitlebar')

	select_renderer || return 1

	# X11 session - no backend override needed
	if [[ $is_wayland != true ]]; then
		log_message 'X11 session detected'
		return
	fi

	if [[ $use_x11_on_wayland == true ]]; then
		# Fallback: Use X11 via XWayland when requested
		log_message 'Using X11 backend via XWayland'
		electron_args+=('--ozone-platform=x11')
	else
		# Native Wayland mode (default on Wayland)
		log_message 'Using native Wayland backend'
		electron_args+=('--enable-features=UseOzonePlatform,WaylandWindowDecorations')
		electron_args+=('--ozone-platform=wayland')
		electron_args+=('--enable-wayland-ime')
		electron_args+=('--wayland-text-input-version=3')
	fi
}

# Set common environment variables
setup_electron_env() {
	export ELECTRON_FORCE_IS_PACKAGED=true
	export ELECTRON_USE_SYSTEM_TITLE_BAR=1
}

# Register figma-desktop as the per-user default handler for figma:// URLs.
# Idempotent (safe to call on every launch); non-fatal on failure.
# update-desktop-database alone is enough on some distros (Fedora), but
# Ubuntu/snap-sandboxed browsers need an explicit xdg-mime default.
#
# Inside distrobox the exported desktop file is renamed to
# <container>-<name>.desktop, so the un-prefixed id only exists inside the
# container. The OS handler lookup happens outside (in the browser's
# environment, against the shared ~/.local/share/applications) and finds
# nothing there, so the "Open in Figma Desktop" button on the login page
# silently does nothing. Register the exported name when there is one.
register_url_scheme() {
	local desktop_id="${1:-figma-desktop.desktop}"
	command -v xdg-mime > /dev/null 2>&1 || return 0
	if [ -z "${1:-}" ] && [ -n "${CONTAINER_ID:-}" ]; then
		local exported_id="${CONTAINER_ID}-${desktop_id}"
		if [ -f "${XDG_DATA_HOME:-${HOME}/.local/share}/applications/${exported_id}" ]; then
			desktop_id="$exported_id"
		fi
	fi
	xdg-mime default "$desktop_id" x-scheme-handler/figma > /dev/null 2>&1 || true
}
