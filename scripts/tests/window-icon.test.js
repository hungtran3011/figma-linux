const { test } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

test('Window icon and app identity are injected on Linux', () => {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'figma-icon-test-'));
  const dummyIcon = path.join(tempDir, 'icon.png');
  fs.writeFileSync(dummyIcon, 'dummy-png-data');

  const origResourcesPath = process.resourcesPath;
  process.resourcesPath = tempDir;

  let desktopNameSet = null;
  const mockApp = {
    setDesktopName(name) {
      desktopNameSet = name;
    },
  };

  let capturedOptions = null;
  let iconSetOnInstance = null;

  class MockBrowserWindow {
    constructor(options) {
      capturedOptions = options;
      this.webContents = { setUserAgent() {} };
    }
    setMenuBarVisibility() {}
    setIcon(icon) {
      iconSetOnInstance = icon;
    }
    on() {}
    once() {}
    getSize() { return [800, 600]; }
    getContentBounds() { return { x: 0, y: 0, width: 800, height: 600 }; }
    static getAllWindows() { return []; }
  }

  const origResolve = Module._resolveFilename;
  Module._resolveFilename = function(request) {
    if (request === 'electron' || request === 'electron/main') return 'electron-icon-test';
    return origResolve.apply(this, arguments);
  };

  require.cache['electron-icon-test'] = {
    id: 'electron-icon-test',
    filename: 'electron-icon-test',
    loaded: true,
    exports: {
      app: mockApp,
      BrowserWindow: MockBrowserWindow,
      Menu: { setApplicationMenu() {} },
    },
  };

  try {
    const wrapperPath = path.resolve(__dirname, '../frame-fix-wrapper.js');
    delete require.cache[wrapperPath];
    require(wrapperPath);

    const electron = require('electron');

    // Verify desktop name
    assert.equal(desktopNameSet, 'figma-desktop');

    // Create normal window
    const win = new electron.BrowserWindow({ width: 1000, height: 800 });
    assert.ok(capturedOptions.icon);
    assert.equal(capturedOptions.icon, dummyIcon);
    assert.equal(iconSetOnInstance, dummyIcon);

    // Create tray window (should not set window icon)
    capturedOptions = null;
    iconSetOnInstance = null;
    const trayWin = new electron.BrowserWindow({
      webPreferences: { preload: '/path/to/tray_binding_renderer.js' }
    });
    assert.equal(capturedOptions.icon, undefined);
    assert.equal(iconSetOnInstance, null);
  } finally {
    process.resourcesPath = origResourcesPath;
    Module._resolveFilename = origResolve;
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
});
