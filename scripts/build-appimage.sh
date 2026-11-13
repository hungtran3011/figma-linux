#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"

echo '--- Starting AppImage Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

component_id='io.github.nickvdp.figma-desktop-linux'

# Determine update information for GearLever, AM, and AppImageUpdate
update_repo="${FIGMA_UPDATE_REPO:-}"
if [[ -z $update_repo && -n ${GITHUB_REPOSITORY:-} ]]; then
	update_repo="$GITHUB_REPOSITORY"
fi
if [[ -z $update_repo ]]; then
	git_remote=$(git config --get remote.origin.url 2>/dev/null || true)
	if [[ $git_remote =~ github\.com[:/]([^/]+)/([^/.]+?)(\.git)?$ ]]; then
		update_repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
	fi
fi
[[ -z $update_repo ]] && update_repo='hungtran3011/figma-linux'

update_info=''
if [[ ${FIGMA_NO_UPDATE_INFO:-0} != '1' ]]; then
	update_info="${FIGMA_UPDATE_INFO:-gh-releases-zsync|${update_repo%/*}|${update_repo#*/}|latest|${package_name}-*${architecture}.AppImage.zsync}"
fi
echo "Update repository: $update_repo"
echo "Update information: ${update_info:-none}"

# Define AppDir structure path
appdir_path="$work_dir/${component_id}.AppDir"
rm -rf "$appdir_path"
mkdir -p "$appdir_path/usr/bin" || exit 1
mkdir -p "$appdir_path/usr/lib" || exit 1
mkdir -p "$appdir_path/usr/share/icons/hicolor/256x256/apps" || exit 1
mkdir -p "$appdir_path/usr/share/applications" || exit 1

echo 'Staging application files into AppDir...'
# Copy node_modules first to set up Electron directory structure
if [[ -d $app_staging_dir/node_modules ]]; then
	echo 'Copying node_modules from staging to AppDir...'
	cp -a "$app_staging_dir/node_modules" "$appdir_path/usr/lib/" || exit 1
fi

# Install app.asar in Electron's resources directory
resources_dir="$appdir_path/usr/lib/node_modules/electron/dist/resources"
mkdir -p "$resources_dir" || exit 1
if [[ -f $app_staging_dir/app.asar ]]; then
	cp -a "$app_staging_dir/app.asar" "$resources_dir/" || exit 1
fi
if [[ -d $app_staging_dir/app.asar.unpacked ]]; then
	cp -a "$app_staging_dir/app.asar.unpacked" "$resources_dir/" || exit 1
fi
echo 'Application files copied to Electron resources directory'

# Copy shared launcher library
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$appdir_path/usr/lib/figma-desktop" || exit 1
cp "$script_dir/launcher-common.sh" "$appdir_path/usr/lib/figma-desktop/" || exit 1
echo 'Shared launcher library copied'

# Ensure Electron is bundled
bundled_electron_path="$appdir_path/usr/lib/node_modules/electron/dist/electron"
echo "Checking for executable at: $bundled_electron_path"
if [[ ! -x $bundled_electron_path ]]; then
	echo 'Electron executable not found or not executable in staging area.' >&2
	exit 1
fi
chmod +x "$bundled_electron_path" || exit 1

# --- Create AppRun Script ---
echo 'Creating AppRun script...'
cat > "$appdir_path/AppRun" << 'EOF'
#!/usr/bin/env bash

# Find the location of the AppRun script
appdir=$(dirname "$(readlink -f "$0")")
appimage_path="$(readlink -f "$0")"
# If launched from mounted AppImage, APPIMAGE env var points to the actual .AppImage file
[[ -n $APPIMAGE ]] && appimage_path="$APPIMAGE"

# Source shared launcher library
source "$appdir/usr/lib/figma-desktop/launcher-common.sh"

# Setup logging and environment
setup_logging || exit 1
setup_electron_env

# --- Desktop Integration for figma:// URL scheme and Taskbar Icon ---
# Register .desktop file so the system knows how to handle figma:// URLs and taskbar icons
integrate_desktop() {
	local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
	local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
	local desktop_file="$desktop_dir/figma-desktop.desktop"
	local legacy_desktop_file="$desktop_dir/figma-desktop-appimage.desktop"
	local needs_update=false

	mkdir -p "$desktop_dir" "$icon_dir" 2>/dev/null

	# Copy icon if available
	local icon_src="$appdir/io.github.nickvdp.figma-desktop-linux.png"
	[[ ! -f $icon_src && -f "$appdir/figma-desktop.png" ]] && icon_src="$appdir/figma-desktop.png"
	local icon_dest="$icon_dir/figma-desktop.png"
	if [[ -f $icon_src ]]; then
		if [[ ! -f $icon_dest ]] || ! cmp -s "$icon_src" "$icon_dest"; then
			cp "$icon_src" "$icon_dest" 2>/dev/null
			needs_update=true
		fi
	fi

	# Create/update .desktop file if AppImage path changed or file doesn't exist
	local current_exec=''
	[[ -f $desktop_file ]] && current_exec=$(grep '^Exec=' "$desktop_file" 2>/dev/null | head -1)

	if [[ ! -f $desktop_file ]] || [[ $current_exec != "Exec=\"${appimage_path}\" %u" ]]; then
		cat > "$desktop_file" << DESKTOP
[Desktop Entry]
Name=Figma
Exec="${appimage_path}" %u
Icon=figma-desktop
Type=Application
Terminal=false
Categories=Graphics;
Comment=Figma Desktop for Linux (AppImage)
MimeType=x-scheme-handler/figma;
StartupWMClass=figma-desktop
X-AppImage-Version=${app_version}
X-AppImage-Name=Figma Desktop
DESKTOP
		if [[ -n $update_info ]]; then
			echo "X-AppImage-Update-Information=${update_info}" >> "$desktop_file"
		fi
		# Ensure backward compatibility symlink exists
		ln -sf "$desktop_file" "$legacy_desktop_file" 2>/dev/null || true
		needs_update=true
		log_message "Desktop file created/updated: $desktop_file"
	fi

	# Update MIME database if changed
	if [[ $needs_update == true ]]; then
		update-desktop-database "$desktop_dir" 2>/dev/null || true
		xdg-mime default figma-desktop.desktop x-scheme-handler/figma 2>/dev/null || true
		log_message 'Desktop integration updated (figma:// URL scheme registered)'
	fi
}

# Read version and update information from bundled desktop file
app_version=$(grep -h -m1 '^X-AppImage-Version=' "$appdir"/*.desktop 2>/dev/null | head -n 1 | cut -d= -f2-)
update_info=$(grep -h -m1 '^X-AppImage-Update-Information=' "$appdir"/*.desktop 2>/dev/null | head -n 1 | cut -d= -f2-)

# Handle update helper CLI options (--update, --check-update)
case "${1:-}" in
	--check-update|--check-updates)
		echo "Checking for updates for Figma Desktop (${app_version:-unknown})..."
		if command -v appimageupdatetool >/dev/null 2>&1; then
			appimageupdatetool --check-for-update "$appimage_path"
			exit $?
		fi
		if [[ -n $update_info && $update_info =~ gh-releases-zsync\|([^|]+)\|([^|]+)\| ]]; then
			owner="${BASH_REMATCH[1]}"
			repo="${BASH_REMATCH[2]}"
			latest_tag=$(curl -sL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/${owner}/${repo}/releases/latest" 2>/dev/null | grep -oP '"tag_name":\s*"\K[^"]+' || true)
			if [[ -n $latest_tag ]]; then
				echo "Installed: ${app_version:-unknown}"
				echo "Latest:    ${latest_tag}"
				clean_latest="${latest_tag#v}"
				clean_current="${app_version#v}"
				if [[ -n $clean_latest && -n $clean_current && "$clean_latest" != "$clean_current" ]]; then
					echo "Update available: $latest_tag"
					exit 1
				else
					echo "Figma Desktop is up to date."
					exit 0
				fi
			fi
		fi
		echo "Unable to check for updates (appimageupdatetool missing and GitHub API unreachable)." >&2
		exit 2
		;;
	--update)
		echo "Updating Figma Desktop (${app_version:-unknown})..."
		if command -v appimageupdatetool >/dev/null 2>&1; then
			appimageupdatetool -Or "$appimage_path"
			exit $?
		elif command -v am >/dev/null 2>&1; then
			am -u figma-desktop 2>/dev/null || am -u figma
			exit $?
		elif command -v flatpak >/dev/null 2>&1 && flatpak list --app 2>/dev/null | grep -q 'it.mijorus.gearlever'; then
			flatpak run it.mijorus.gearlever --update "$appimage_path"
			exit $?
		else
			echo "To update via zsync differential download, install appimageupdatetool, am, or GearLever." >&2
			if [[ -n $update_info && $update_info =~ gh-releases-zsync\|([^|]+)\|([^|]+)\| ]]; then
				echo "Latest release download: https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/releases/latest" >&2
			fi
			exit 1
		fi
		;;
esac

# Run desktop integration (non-blocking, errors are non-fatal)
integrate_desktop 2>/dev/null || true

# Detect display backend
if ! check_display; then
	echo 'Error: Figma Desktop requires a graphical desktop environment.' >&2
	exit 1
fi
detect_display_backend

# Log startup info
log_message '--- Figma Desktop AppImage Start ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $@"
log_message "APPDIR: $appdir"
log_message "APPIMAGE: $appimage_path"

# Path to the bundled Electron executable and app
electron_exec="$appdir/usr/lib/node_modules/electron/dist/electron"
app_path="$appdir/usr/lib/node_modules/electron/dist/resources/app.asar"

# Build electron args (appimage mode adds --no-sandbox)
build_electron_args 'appimage' || exit 1

# Add app path LAST
electron_args+=("$app_path")

# Change to HOME directory before exec'ing Electron to avoid CWD permission issues
cd "$HOME" || exit 1

# Execute Electron
log_message "Executing: $electron_exec ${electron_args[*]} $*"
if [[ ${FIGMA_DEBUG:-0} == 1 ]]; then
	"$electron_exec" "${electron_args[@]}" "$@" 2>&1 | tee -a "$log_file"
else
	exec "$electron_exec" "${electron_args[@]}" "$@" >> "$log_file" 2>&1
fi
EOF
chmod +x "$appdir_path/AppRun" || exit 1
echo 'AppRun script created'

# --- Create Desktop Entry ---
echo 'Creating bundled desktop entry...'
cat > "$appdir_path/$component_id.desktop" << EOF
[Desktop Entry]
Name=Figma
Exec=AppRun %u
Icon=$component_id
Type=Application
Terminal=false
Categories=Graphics;
Comment=Figma Desktop for Linux
MimeType=x-scheme-handler/figma;
StartupWMClass=figma-desktop
X-AppImage-Version=$version
X-AppImage-Name=Figma Desktop
EOF
if [[ -n $update_info ]]; then
	echo "X-AppImage-Update-Information=$update_info" >> "$appdir_path/$component_id.desktop"
fi
mkdir -p "$appdir_path/usr/share/applications" || exit 1
cp "$appdir_path/$component_id.desktop" "$appdir_path/usr/share/applications/" || exit 1
ln -sf "$component_id.desktop" "$appdir_path/usr/share/applications/figma-desktop.desktop" || true
ln -sf "$component_id.desktop" "$appdir_path/figma-desktop.desktop" || true
echo 'Desktop entry created'

# --- Copy Icons ---
echo 'Copying icons...'
# Find the best available icon (prefer 256x256)
icon_source_path=$(find "$work_dir" -maxdepth 1 -name "figma_*.png" -exec identify -format '%w %h %i\n' {} \; 2>/dev/null | awk '$1==256 && $2==256 {print $3; exit}')
if [[ -z $icon_source_path ]]; then
	# Fallback to the largest icon available
	icon_source_path=$(find "$work_dir" -maxdepth 1 -name "figma_*.png" -exec identify -format '%w %i\n' {} \; 2>/dev/null | sort -rn | head -1 | awk '{print $2}')
fi

if [[ -f $icon_source_path ]]; then
	cp "$icon_source_path" "$appdir_path/usr/share/icons/hicolor/256x256/apps/${component_id}.png" || exit 1
	cp "$icon_source_path" "$appdir_path/usr/share/icons/hicolor/256x256/apps/figma-desktop.png" || exit 1
	cp "$icon_source_path" "$appdir_path/${component_id}.png" || exit 1
	cp "$icon_source_path" "$appdir_path/figma-desktop.png" || exit 1
	cp "$icon_source_path" "$appdir_path/${component_id}" || exit 1
	cp "$icon_source_path" "$appdir_path/.DirIcon" || exit 1
	echo 'Icon copied to standard locations'
else
	echo "Warning: No icon found. AppImage icon might be missing."
fi

# --- Create AppStream Metadata ---
echo 'Creating AppStream metadata...'
metadata_dir="$appdir_path/usr/share/metainfo"
mkdir -p "$metadata_dir" || exit 1

cat > "$metadata_dir/${component_id}.appdata.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>$component_id</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>LicenseRef-proprietary=https://www.figma.com/tos/</project_license>

  <name>Figma Desktop</name>
  <summary>Collaborative design tool for Linux</summary>

  <description>
    <p>
      Figma Desktop for Linux, repackaged from the official Figma Desktop Windows installer.
      Provides the full Figma design experience natively on Linux desktop environments.
    </p>
  </description>

  <launchable type="desktop-id">${component_id}.desktop</launchable>

  <url type="homepage">https://www.figma.com</url>
  <provides>
    <binary>AppRun</binary>
  </provides>

  <categories>
    <category>Graphics</category>
  </categories>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="$version" date="$(date +%Y-%m-%d)">
      <description>
        <p>Version $version.</p>
      </description>
    </release>
  </releases>

</component>
EOF
echo "AppStream metadata created"

# --- Get verified, pinned appimagetool and Type-2 runtime ---
# shellcheck source=scripts/appimage-toolchain.sh
source "$script_dir/appimage-toolchain.sh"
prepare_appimage_tools "$architecture" "$work_dir" || exit 1

# --- Build AppImage ---
echo 'Building AppImage...'
output_filename="${package_name}-${version}-${architecture}.AppImage"
output_path="$work_dir/$output_filename"
export ARCH="$tool_arch"
echo "Using ARCH=$ARCH"

appimagetool_opts=("--runtime-file" "$runtime_path")
if [[ -n $update_info ]]; then
	echo "Building AppImage with update information: $update_info"
	appimagetool_opts+=("-u" "$update_info")
else
	echo 'Building AppImage without update information'
fi

if ! (cd "$work_dir" && APPIMAGE_EXTRACT_AND_RUN=1 "$appimagetool_path" \
	"${appimagetool_opts[@]}" "$appdir_path" "$output_filename"); then
	echo "Failed to build AppImage using $appimagetool_path" >&2
	exit 1
fi

echo "AppImage built successfully: $output_path"
echo '--- AppImage Build Finished ---'

exit 0
