const { test } = require('node:test');
const assert = require('node:assert/strict');
const EventEmitter = require('node:events');
const Module = require('node:module');
const path = require('node:path');

// Mock Electron before loading the wrapper
class MockTray extends EventEmitter {
  constructor(image, guid) {
    super();
    this.image = image;
    this.guid = guid;
    this.destroyed = false;
  }
  setImage(image) {
    this.image = image;
  }
  destroy() {
    this.destroyed = true;
  }
  isDestroyed() {
    return this.destroyed;
  }
}

class MockBrowserWindow {
  constructor() {
    this.webContents = { setUserAgent() {} };
  }
  setMenuBarVisibility() {}
  on() {}
  once() {}
  getSize() { return [800, 600]; }
  getContentBounds() { return { x: 0, y: 0, width: 800, height: 600 }; }
  static getAllWindows() { return []; }
}

const mockNativeTheme = new EventEmitter();
mockNativeTheme.shouldUseDarkColors = false;

const origResolve = Module._resolveFilename;
Module._resolveFilename = function(request) {
  if (request === 'electron' || request === 'electron/main') return 'electron';
  return origResolve.apply(this, arguments);
};

require.cache['electron'] = {
  id: 'electron',
  filename: 'electron',
  loaded: true,
  exports: {
    BrowserWindow: MockBrowserWindow,
    Menu: { setApplicationMenu() {} },
    Tray: MockTray,
    nativeTheme: mockNativeTheme,
  },
};

// Load wrapper
const wrapperPath = path.resolve(__dirname, '../frame-fix-wrapper.js');
require(wrapperPath);

const electron = require('electron');

test('Tray translates light icon to dark icon when dark theme is enabled', () => {
  const prevEnv = process.env.FIGMA_TRAY_THEME;
  try {
    delete process.env.FIGMA_TRAY_THEME;
    mockNativeTheme.shouldUseDarkColors = true;

    const tray = new electron.Tray('/assets/tray/iconLight.png');
    assert.match(tray.image, /iconDark\.png$/);

    tray.setImage('/assets/tray/iconWithIndicatorLight.png');
    assert.match(tray.image, /iconWithIndicatorDark\.png$/);

    tray.setImage('/assets/tray/iconLight@2x.png');
    assert.match(tray.image, /iconDark@2x\.png$/);

    tray.destroy();
  } finally {
    process.env.FIGMA_TRAY_THEME = prevEnv;
  }
});

test('Tray translates dark icon to light icon when light theme is active', () => {
  const prevEnv = process.env.FIGMA_TRAY_THEME;
  try {
    delete process.env.FIGMA_TRAY_THEME;
    mockNativeTheme.shouldUseDarkColors = false;

    const tray = new electron.Tray('/assets/tray/iconDark.png');
    assert.match(tray.image, /iconLight\.png$/);

    tray.destroy();
  } finally {
    process.env.FIGMA_TRAY_THEME = prevEnv;
  }
});

test('FIGMA_TRAY_THEME override takes precedence over nativeTheme', () => {
  try {
    // nativeTheme is light, but FIGMA_TRAY_THEME=dark
    mockNativeTheme.shouldUseDarkColors = false;
    process.env.FIGMA_TRAY_THEME = 'dark';

    const trayDark = new electron.Tray('/assets/tray/iconLight.png');
    assert.match(trayDark.image, /iconDark\.png$/);
    trayDark.destroy();

    // nativeTheme is dark, but FIGMA_TRAY_THEME=light
    mockNativeTheme.shouldUseDarkColors = true;
    process.env.FIGMA_TRAY_THEME = 'light';

    const trayLight = new electron.Tray('/assets/tray/iconDark.png');
    assert.match(trayLight.image, /iconLight\.png$/);
    trayLight.destroy();
  } finally {
    delete process.env.FIGMA_TRAY_THEME;
  }
});

test('Tray icon dynamically updates on nativeTheme updated event', () => {
  delete process.env.FIGMA_TRAY_THEME;
  mockNativeTheme.shouldUseDarkColors = false;

  const tray = new electron.Tray('/assets/tray/iconLight.png');
  assert.match(tray.image, /iconLight\.png$/);

  // Switch to dark theme and notify
  mockNativeTheme.shouldUseDarkColors = true;
  mockNativeTheme.emit('updated');

  assert.match(tray.image, /iconDark\.png$/);

  // Switch back to light theme and notify
  mockNativeTheme.shouldUseDarkColors = false;
  mockNativeTheme.emit('updated');

  assert.match(tray.image, /iconLight\.png$/);

  // Destroy tray and verify no further updates
  tray.destroy();
  mockNativeTheme.shouldUseDarkColors = true;
  mockNativeTheme.emit('updated');
  // Since destroyed, should remain what it was before destruction
  assert.equal(tray.destroyed, true);
});
