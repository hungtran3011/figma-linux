// Inject frame fix before main app loads
const fs = require('fs');
const path = require('path');
const Module = require('module');
const originalRequire = Module.prototype.require;

console.log('[Frame Fix] Wrapper loaded');

let resolvedAppIcon = null;
function resolveAppIconPath() {
	if (resolvedAppIcon !== null) return resolvedAppIcon;
	const candidates = [
		path.join(process.resourcesPath || '', 'icon.png'),
		path.join(__dirname, 'icon.png'),
		path.join(__dirname, 'assets', 'icon.png'),
		process.env.APPDIR ? path.join(process.env.APPDIR, 'usr/share/icons/hicolor/256x256/apps/figma-desktop.png') : '',
		process.env.APPDIR ? path.join(process.env.APPDIR, 'figma-desktop.png') : '',
		process.env.APPDIR ? path.join(process.env.APPDIR, 'io.github.nickvdp.figma-desktop-linux.png') : '',
		path.join(process.env.XDG_DATA_HOME || path.join(process.env.HOME || '', '.local/share'), 'icons/hicolor/256x256/apps/figma-desktop.png'),
		'/usr/share/icons/hicolor/256x256/apps/figma-desktop.png',
	];
	for (const p of candidates) {
		if (p && fs.existsSync(p)) {
			resolvedAppIcon = p;
			console.log(`[Frame Fix] Found app icon: ${p}`);
			return resolvedAppIcon;
		}
	}
	resolvedAppIcon = '';
	return '';
}

const WIN_USER_AGENT = `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${process.versions.chrome} Safari/537.36`;

function applyWindowsUserAgent(webContents) {
	if (process.platform !== 'linux' || !webContents) return;
	try {
		webContents.setUserAgent(WIN_USER_AGENT);
	} catch (_err) {
		// Some utility views may not expose a mutable user agent.
	}
}

// Build the patched BrowserWindow class and Menu interceptor once,
// on first require('electron'), then reuse via Proxy on every access.
let PatchedBrowserWindow = null;
let PatchedWebContentsView = null;
let PatchedBrowserView = null;
let PatchedTray = null;
let patchedSetApplicationMenu = null;

Module.prototype.require = function(id) {
	const result = originalRequire.apply(this, arguments);

	if (id === 'electron' || id === 'electron/main') {
		// Build patches once from the real electron module
		if (!PatchedBrowserWindow) {
			console.log('[Frame Fix] Intercepting electron module');

			if (result.app && typeof result.app.setDesktopName === 'function') {
				result.app.setDesktopName('figma-desktop');
				console.log('[Frame Fix] Set desktop name to figma-desktop');
			}

			const OriginalBrowserWindow = result.BrowserWindow;
			const OriginalWebContentsView = result.WebContentsView;
			const OriginalBrowserView = result.BrowserView;
			const OriginalMenu = result.Menu;
			const OriginalTray = result.Tray;
			const appIconPath = resolveAppIconPath();

			PatchedBrowserWindow = class BrowserWindowWithFrame extends OriginalBrowserWindow {
				constructor(options) {
					// Detect tray window by its preload script path
					const preloadPath = options?.webPreferences?.preload || '';
					const isTrayWindow = preloadPath.includes('tray_binding_renderer');

					if (isTrayWindow) {
						console.log('[Frame Fix] Tray notification BrowserWindow detected');
					} else {
						console.log('[Frame Fix] BrowserWindow constructor called');
					}

					if (process.platform === 'linux') {
						options = options || {};
						// Set window icon for X11 _NET_WM_ICON and GTK window icon
						if (!options.icon && appIconPath && !isTrayWindow) {
							options.icon = appIconPath;
						}
						const originalFrame = options.frame;
						// Force native frame
						options.frame = true;
						// Hide the menu bar by default (Alt key will toggle it)
						options.autoHideMenuBar = true;
						// Remove custom titlebar options
						delete options.titleBarStyle;
						delete options.titleBarOverlay;
						console.log(`[Frame Fix] Modified frame from ${originalFrame} to true`);
					}
					super(options);

					if (process.platform === 'linux') {
						if (!isTrayWindow) {
							applyWindowsUserAgent(this.webContents);
							if (appIconPath) {
								try {
									this.setIcon(appIconPath);
								} catch (_) {}
							}
						}

						// Hide menu bar after window creation
						this.setMenuBarVisibility(false);

						// Ensure menu bar stays hidden on show events
						this.on('show', () => {
							this.setMenuBarVisibility(false);
						});

						if (!isTrayWindow) {
							// Patch getContentBounds() to read from getSize() directly,
							// bypassing Chromium's LayoutManagerBase cache. The cache is
							// only invalidated via OnWindowStateChanged() -> ScheduleRelayout()
							// -> InvalidateLayout(), which requires _NET_WM_STATE atom changes.
							// KWin's corner-snap/quick-tile and Wayland compositors never set
							// those atoms, so the cache stays stale after tiling/maximize.
							// getSize() reads from Widget/platform window bounds updated by
							// X11 ConfigureNotify before JS events fire, so it always reflects
							// the real geometry. Under XWayland, frame overhead is 0x0 (WM
							// draws outside app bounds), so frameW/H will calibrate to zero.
							let frameW = 0;
							let frameH = 0;
							let calibrated = false;
							const origGetContentBounds = this.getContentBounds.bind(this);

							this.getContentBounds = () => {
								if (calibrated && !this.isDestroyed()) {
									const [w, h] = this.getSize();
									const width = w - frameW;
									const height = h - frameH;
									// Guard against stale/invalid getSize() data during
									// transitions — fall back rather than set child to 0x0.
									if (width > 0 && height > 0) {
										return { x: 0, y: 0, width, height };
									}
								}
								return origGetContentBounds();
							};

							// For maximize/unmaximize/fullscreen, Chromium's layout cache
							// is definitively stale. Re-emit resize twice — immediately
							// and after one frame — so the app's layout handler runs with
							// fresh getSize() data from our patched getContentBounds().
							const reemitResize = () => {
								if (this.isDestroyed()) return;
								this.emit('resize');
								setTimeout(() => {
									if (!this.isDestroyed()) this.emit('resize');
								}, 16);
							};

							this.on('maximize', reemitResize);
							this.on('unmaximize', reemitResize);
							this.on('enter-full-screen', reemitResize);
							this.on('leave-full-screen', reemitResize);

							// ready-to-show fires once per window lifecycle
							this.once('ready-to-show', () => {
								this.setMenuBarVisibility(false);
								// One-time jiggle for initial layout
								const [w, h] = this.getSize();
								this.setSize(w + 1, h + 1);
								setTimeout(() => {
									if (this.isDestroyed()) return;
									this.setSize(w, h);
									// Calibrate frame overhead after layout stabilizes.
									// origGetContentBounds() is accurate at rest; stale data
									// only occurs during active geometry operations.
									setTimeout(() => {
										if (this.isDestroyed()) return;
										const [winW, winH] = this.getSize();
										const cb = origGetContentBounds();
										const fw = winW - cb.width;
										const fh = winH - cb.height;
										// Reject if content bounds are zero or overhead is
										// implausibly large (would indicate a bad read).
										if (cb.width > 0 && cb.height > 0 && fw >= 0 && fh >= 0
											&& fw < 200 && fh < 200) {
											frameW = fw;
											frameH = fh;
											calibrated = true;
											console.log(`[Frame Fix] Frame overhead calibrated: ${fw}x${fh}`);
										} else {
											console.log(`[Frame Fix] Calibration failed, using fallback. win=${winW}x${winH} content=${cb.width}x${cb.height}`);
											// Fallback: assume zero frame overhead (safe for XWayland/Wayland)
											frameW = 0;
											frameH = 0;
											calibrated = true;
										}
									}, 100);
								}, 50);
							});

							// Fallback calibration if ready-to-show doesn't fire
							this.once('show', () => {
								setTimeout(() => {
									if (this.isDestroyed() || calibrated) return;
									console.log('[Frame Fix] Fallback calibration via show event');
									const [winW, winH] = this.getSize();
									const cb = origGetContentBounds();
									const fw = winW - cb.width;
									const fh = winH - cb.height;
									if (cb.width > 0 && cb.height > 0 && fw >= 0 && fh >= 0
										&& fw < 200 && fh < 200) {
										frameW = fw;
										frameH = fh;
									}
									calibrated = true;
									console.log(`[Frame Fix] Fallback calibrated: ${frameW}x${frameH}`);
								}, 500);
							});
						}

						// Debug: open DevTools for tray notification window
						if (isTrayWindow && process.env.FIGMA_DEBUG === '1') {
							console.log('[Frame Fix] DEBUG: Opening DevTools for tray window');
							this.webContents.on('dom-ready', () => {
								this.webContents.openDevTools({ mode: 'detach' });
							});
						}

						console.log('[Frame Fix] Linux patches applied');
					}
				}
			};

			if (OriginalWebContentsView) {
				PatchedWebContentsView = class WebContentsViewWithUserAgent extends OriginalWebContentsView {
					constructor(options) {
						super(options);
						applyWindowsUserAgent(this.webContents);
					}
				};
			}

			if (OriginalBrowserView) {
				PatchedBrowserView = class BrowserViewWithUserAgent extends OriginalBrowserView {
					constructor(options) {
						super(options);
						applyWindowsUserAgent(this.webContents);
					}
				};
			}

			// Copy static methods and properties from original
			for (const key of Object.getOwnPropertyNames(OriginalBrowserWindow)) {
				if (key !== 'prototype' && key !== 'length' && key !== 'name') {
					try {
						const descriptor = Object.getOwnPropertyDescriptor(OriginalBrowserWindow, key);
						if (descriptor) {
							Object.defineProperty(PatchedBrowserWindow, key, descriptor);
						}
					} catch (e) {
						// Ignore errors for non-configurable properties
					}
				}
			}

			// Intercept Menu.setApplicationMenu to hide menu bar on Linux
			const originalSetAppMenu = OriginalMenu.setApplicationMenu.bind(OriginalMenu);
			patchedSetApplicationMenu = function(menu) {
				console.log('[Frame Fix] Intercepting setApplicationMenu');
				originalSetAppMenu(menu);
				if (process.platform === 'linux') {
					for (const win of PatchedBrowserWindow.getAllWindows()) {
						if (win.isDestroyed()) continue;
						win.setMenuBarVisibility(false);
					}
					console.log('[Frame Fix] Menu bar hidden on all windows');
				}
			};

			// Intercept Tray to support dark mode icons on Linux
			if (OriginalTray) {
				const activeTrays = new Set();

				const shouldUseDarkTrayIcon = () => {
					const env = (process.env.FIGMA_TRAY_THEME || '').toLowerCase().trim();
					if (env === 'dark') return true;
					if (env === 'light') return false;
					try {
						return !!(result.nativeTheme && result.nativeTheme.shouldUseDarkColors);
					} catch (_e) {
						return false;
					}
				};

				const resolveTrayIcon = (iconPath) => {
					if (typeof iconPath !== 'string') return iconPath;

					const wantDark = shouldUseDarkTrayIcon();
					let candidate = iconPath;
					if (wantDark) {
						if (candidate.includes('iconWithIndicatorLight')) {
							candidate = candidate.replace('iconWithIndicatorLight', 'iconWithIndicatorDark');
						} else if (candidate.includes('iconLight')) {
							candidate = candidate.replace('iconLight', 'iconDark');
						}
					} else {
						if (candidate.includes('iconWithIndicatorDark')) {
							candidate = candidate.replace('iconWithIndicatorDark', 'iconWithIndicatorLight');
						} else if (candidate.includes('iconDark')) {
							candidate = candidate.replace('iconDark', 'iconLight');
						}
					}

					if (candidate !== iconPath) {
						try {
							if (fs.existsSync(candidate)) return candidate;
							if (fs.existsSync(iconPath)) return iconPath;
						} catch (_e) {
							return candidate;
						}
					}
					return candidate;
				};

				PatchedTray = class TrayWithTheme extends OriginalTray {
					constructor(image, guid) {
						const rawImage = image;
						const resolvedImage = process.platform === 'linux' ? resolveTrayIcon(image) : image;
						super(resolvedImage, guid);
						this._rawIconPath = rawImage;
						this._appliedIconPath = resolvedImage;
						if (process.platform === 'linux') {
							activeTrays.add(this);
							console.log(`[Frame Fix] Linux Tray initialized: ${resolvedImage} (darkTheme=${shouldUseDarkTrayIcon()})`);
						}
					}

					setImage(image) {
						this._rawIconPath = image;
						const resolvedImage = process.platform === 'linux' ? resolveTrayIcon(image) : image;
						this._appliedIconPath = resolvedImage;
						return super.setImage(resolvedImage);
					}

					popUpContextMenu(menu, position) {
						if (process.platform === 'linux' && menu && typeof this.setContextMenu === 'function') {
							try {
								this.setContextMenu(menu);
								console.log('[Frame Fix] Tray context menu applied via popUpContextMenu');
							} catch (err) {
								console.error('[Frame Fix] Error setting context menu from popUpContextMenu:', err);
							}
						}
						if (typeof super.popUpContextMenu === 'function') {
							return super.popUpContextMenu(menu, position);
						}
					}

					destroy() {
						activeTrays.delete(this);
						return super.destroy();
					}
				};

				for (const key of Object.getOwnPropertyNames(OriginalTray)) {
					if (key !== 'prototype' && key !== 'length' && key !== 'name') {
						try {
							const descriptor = Object.getOwnPropertyDescriptor(OriginalTray, key);
							if (descriptor) {
								Object.defineProperty(PatchedTray, key, descriptor);
							}
						} catch (_e) {
							// Ignore non-configurable properties
						}
					}
				}

				if (process.platform === 'linux' && result.nativeTheme && typeof result.nativeTheme.on === 'function') {
					result.nativeTheme.on('updated', () => {
						const isDark = shouldUseDarkTrayIcon();
						console.log(`[Frame Fix] nativeTheme updated: shouldUseDarkColors=${result.nativeTheme.shouldUseDarkColors}, trayDark=${isDark}`);
						for (const tray of activeTrays) {
							try {
								if (tray.isDestroyed && tray.isDestroyed()) {
									activeTrays.delete(tray);
									continue;
								}
								if (tray._rawIconPath) {
									const targetIcon = resolveTrayIcon(tray._rawIconPath);
									if (targetIcon !== tray._appliedIconPath) {
										console.log(`[Frame Fix] Theme changed, switching tray icon to: ${targetIcon}`);
										tray._appliedIconPath = targetIcon;
										OriginalTray.prototype.setImage.call(tray, targetIcon);
									}
								}
							} catch (err) {
								console.error('[Frame Fix] Error updating tray icon on theme change:', err);
							}
						}
					});
				}
			}

			console.log('[Frame Fix] Patches built successfully');
		}

		// Return a Proxy that intercepts property access on the electron module.
		// This is needed because electron's exports use non-configurable getters,
		// so we cannot directly reassign module.BrowserWindow.
		return new Proxy(result, {
			get(target, prop, receiver) {
				if (prop === 'BrowserWindow') return PatchedBrowserWindow;
				if (prop === 'WebContentsView' && PatchedWebContentsView) return PatchedWebContentsView;
				if (prop === 'BrowserView' && PatchedBrowserView) return PatchedBrowserView;
				if (prop === 'Tray') return PatchedTray || target.Tray;
				if (prop === 'Menu') {
					// Return a proxy for Menu that intercepts setApplicationMenu
					const originalMenu = target.Menu;
					return new Proxy(originalMenu, {
						get(menuTarget, menuProp) {
							if (menuProp === 'setApplicationMenu') return patchedSetApplicationMenu;
							return Reflect.get(menuTarget, menuProp);
						}
					});
				}
				return Reflect.get(target, prop, receiver);
			}
		});
	}

	return result;
};
