import Foundation

/// Injected at document start into Streamora's page. It stands in for Capacitor: the site only uses
/// `Capacitor.isNativePlatform()` and `Capacitor.Plugins.StreamoraPlayer` (methods return promises,
/// `addListener(event, fn)` resolves to a handle with `remove()`), so the live site runs unchanged.
/// It also reports HTML <video> playback (mp4 files play in the page) so music pauses for the movie.
enum StreamoraBridgeScript {
    static let source = #"""
(() => {
  if (window.__duet) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.duet;
  if (!handler) return;
  const listeners = new Map();
  const post = msg => { try { return handler.postMessage(msg); } catch (e) { return Promise.reject(e); } };
  const plugin = new Proxy({}, {
    get(_, name) {
      if (typeof name !== 'string' || name === 'then' || name === 'toJSON') return undefined;
      if (name === 'addListener') return (event, fn) => {
        if (!listeners.has(event)) listeners.set(event, new Set());
        listeners.get(event).add(fn);
        return Promise.resolve({ remove: () => { const set = listeners.get(event); if (set) set.delete(fn); return Promise.resolve(); } });
      };
      if (name === 'removeAllListeners') return () => { listeners.clear(); return Promise.resolve(); };
      return options => post({ kind: 'call', method: name, options: options || {} });
    }
  });
  window.__duet = {
    emit(event, data) {
      const set = listeners.get(event);
      if (!set) return;
      for (const fn of [...set]) { try { fn(data); } catch (e) { console.error(e); } }
    }
  };
  window.Capacitor = {
    platform: 'ios', isNative: true, duet: true,
    getPlatform: () => 'ios',
    isNativePlatform: () => true,
    isPluginAvailable: name => name === 'StreamoraPlayer',
    Plugins: { StreamoraPlayer: plugin }
  };

  let watching = false;
  const audible = v => v instanceof HTMLVideoElement && !v.muted && v.volume > 0;
  const stop = () => { if (watching) { watching = false; post({ kind: 'media', active: false }).catch(() => {}); } };
  document.addEventListener('playing', e => {
    if (!audible(e.target)) return;
    watching = true;
    post({ kind: 'media', active: true }).catch(() => {});
  }, true);
  document.addEventListener('ended', e => { if (e.target instanceof HTMLVideoElement) stop(); }, true);
  addEventListener('hashchange', () => { if (!location.hash.startsWith('#/watch/')) stop(); });
  addEventListener('pagehide', stop);
})();
"""#
}
