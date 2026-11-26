// Excalidraw for Artel: the editor (React component) and the SVG exporter in one ES module, loaded lazily by
// Resources/DocsRenderer from artel-res://local/ext/excalidraw/. Fonts are served from the same folder
// (window.EXCALIDRAW_ASSET_PATH), so nothing is fetched from the network.
import { createElement as h } from 'react';
import { createRoot } from 'react-dom/client';
import { Excalidraw, exportToSvg, getSceneVersion, restore, serializeAsJSON } from '@excalidraw/excalidraw';
import '@excalidraw/excalidraw/index.css';

/// The scene as a .excalidraw file. `source` would be the page's origin (artel-res://local): name Artel instead.
const serialize = (elements, appState, files) => {
  const scene = JSON.parse(serializeAsJSON(elements, appState, files, 'local'));
  scene.source = 'artel';
  return JSON.stringify(scene, null, 2);
};

const parse = (json) => {
  if (!json || !json.trim()) return null;
  return restore(JSON.parse(json), null, null, { refreshDimensions: false, repairBindings: true });
};

/// Mounts the editor into `container`. `onChange(json)` gets the scene as a .excalidraw file whenever the drawing
/// (not the viewport) changes.
export function mountEditor(container, { json, theme = 'light', onChange, onReady }) {
  const data = parse(json);
  let api = null;
  let lastVersion = data ? getSceneVersion(data.elements) : 0;
  let lastFiles = data ? Object.keys(data.files || {}).length : 0;
  let lastBackground = data && data.appState ? data.appState.viewBackgroundColor : undefined;
  const root = createRoot(container);
  root.render(h(Excalidraw, {
    initialData: {
      elements: data ? data.elements : [],
      appState: { ...(data ? data.appState : {}), theme },
      files: data ? data.files : undefined,
      scrollToContent: true,
    },
    theme,
    langCode: 'en',
    // One editor per page: shortcuts work wherever the focus is in it.
    handleKeyboardGlobally: true,
    // The API also hangs on the container, for debugging (Artel's webEval debug step).
    excalidrawAPI: (a) => { api = a; container.excalidrawAPI = a; if (onReady) onReady(); },
    UIOptions: {
      canvasActions: { loadScene: false, saveToActiveFile: false, saveAsImage: true, export: false, toggleTheme: false },
    },
    onChange: (elements, appState, files) => {
      const version = getSceneVersion(elements);
      const fileCount = Object.keys(files || {}).length;
      const background = appState.viewBackgroundColor;
      if (version === lastVersion && fileCount === lastFiles && background === lastBackground) return;
      lastVersion = version;
      lastFiles = fileCount;
      lastBackground = background;
      if (onChange) onChange(serialize(elements, appState, files));
    },
  }));
  return {
    setTheme(t) { if (api) api.updateScene({ appState: { theme: t } }); },
    json() {
      if (!api) return json;
      return serialize(api.getSceneElements(), api.getAppState(), api.getFiles());
    },
    unmount() { root.unmount(); },
  };
}

/// A .excalidraw scene as an SVG element, in Excalidraw's own rendering.
export async function sceneToSvg(json, theme = 'light') {
  const data = parse(json);
  if (!data) throw new Error('not an Excalidraw scene');
  return exportToSvg({
    elements: data.elements.filter((e) => !e.isDeleted),
    appState: { ...data.appState, exportBackground: true, exportWithDarkMode: theme === 'dark' },
    files: data.files || null,
    exportPadding: 16,
    skipInliningFonts: true,
  });
}

/// An empty drawing, as written for "New Diagram".
export const emptyScene = () => serialize([], { viewBackgroundColor: '#ffffff' }, {});
