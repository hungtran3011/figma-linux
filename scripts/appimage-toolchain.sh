#!/usr/bin/env bash
# Pinned AppImage tooling shared by packaging and CI smoke tests.

select_appimage_architecture() {
	case "$1" in
		amd64)
			tool_arch='x86_64'
			appimagetool_sha256='ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0'
			runtime_sha256='2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d'
			;;
		arm64)
			tool_arch='aarch64'
			appimagetool_sha256='f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158'
			runtime_sha256='00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444'
			;;
		*)
			echo "Unsupported architecture for appimagetool: $1" >&2
			exit 1
			;;
	esac
}

download_verified() {
	local url="$1"
	local output="$2"
	local expected_sha256="$3"

	if [[ -f $output ]] && printf '%s  %s\n' "$expected_sha256" "$output" | sha256sum --check --status; then
		echo "Using verified cached artifact: $output"
		return
	fi

	echo "Downloading $url"
	rm -f "$output"

	local download_success=false
	# Try direct download first with curl or wget (short timeout for quick failover)
	if curl -fSL --retry 1 --connect-timeout 5 --max-time 15 -o "$output" "$url" 2>/dev/null; then
		download_success=true
	elif wget -q --tries=1 --timeout=15 -O "$output" "$url"; then
		download_success=true
	fi

	# If direct download failed and it is a GitHub release URL, fall back to GitHub API endpoint
	# (bypasses GitHub frontend 504 gateway timeout issues on /releases/download/)
	if [[ $download_success != true && $url =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/(.+)$ ]]; then
		local owner="${BASH_REMATCH[1]}"
		local repo="${BASH_REMATCH[2]}"
		local tag="${BASH_REMATCH[3]}"
		local filename="${BASH_REMATCH[4]}"
		echo "Direct release download failed. Querying GitHub API fallback for $filename..." >&2

		local api_url="https://api.github.com/repos/${owner}/${repo}/releases/tags/${tag}"
		local asset_url=''
		for _ in 1 2 3; do
			if command -v jq &>/dev/null; then
				asset_url=$(curl -sL --connect-timeout 5 --max-time 15 "$api_url" | jq -r --arg name "$filename" '.assets[] | select(.name == $name) | .url' 2>/dev/null | head -n 1)
			elif command -v node &>/dev/null; then
				asset_url=$(curl -sL --connect-timeout 5 --max-time 15 "$api_url" | node -e '
					const fs = require("fs");
					try {
						const data = JSON.parse(fs.readFileSync(0, "utf8"));
						const asset = data.assets?.find(a => a.name === process.argv[1]);
						if (asset?.url) console.log(asset.url);
					} catch(_) {}
				' "$filename" 2>/dev/null)
			fi
			[[ -n $asset_url && $asset_url != 'null' ]] && break
			sleep 1
		done

		if [[ -n $asset_url && $asset_url != 'null' ]]; then
			if curl -fSL --retry 2 --connect-timeout 10 --max-time 180 -H 'Accept: application/octet-stream' -o "$output" "$asset_url"; then
				download_success=true
			fi
		fi
	fi

	if [[ $download_success != true ]]; then
		echo "Failed to download $url" >&2
		rm -f "$output"
		exit 1
	fi

	if ! printf '%s  %s\n' "$expected_sha256" "$output" | sha256sum --check --status; then
		echo "Checksum verification failed for $output" >&2
		rm -f "$output"
		exit 1
	fi
}

prepare_appimage_tools() {
	local architecture="$1" work_dir="$2"
	local appimagetool_version='1.9.1' runtime_version='20251108'
	select_appimage_architecture "$architecture" || return 1
	appimagetool_path="$work_dir/appimagetool-${appimagetool_version}-${tool_arch}.AppImage"
	runtime_path="$work_dir/runtime-${runtime_version}-${tool_arch}"
	download_verified \
		"https://github.com/AppImage/appimagetool/releases/download/${appimagetool_version}/appimagetool-${tool_arch}.AppImage" \
		"$appimagetool_path" "$appimagetool_sha256"
	download_verified \
		"https://github.com/AppImage/type2-runtime/releases/download/${runtime_version}/runtime-${tool_arch}" \
		"$runtime_path" "$runtime_sha256"
	chmod +x "$appimagetool_path" || exit 1
}
