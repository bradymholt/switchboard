enum Scripts {
    /// Injected into every frame at document start. Replaces the Notification API (which WKWebView
    /// doesn't provide) and the Badging API so pages report to the native side.
    static let bridge = """
    (() => {
      if (window.__switchboardInstalled) return;
      window.__switchboardInstalled = true;
      const post = (msg) => { try { window.webkit.messageHandlers.switchboard.postMessage(msg); } catch (_) {} };
      const newId = () => Math.random().toString(36).slice(2) + Date.now().toString(36);
      const live = new Map();

      class SwitchboardNotification extends EventTarget {
        constructor(title, options = {}) {
          super();
          this.title = String(title);
          this.body = options.body ? String(options.body) : '';
          this.tag = options.tag ? String(options.tag) : '';
          this.icon = options.icon || '';
          this.data = options.data ?? null;
          this.silent = !!options.silent;
          this.onclick = this.onshow = this.onclose = this.onerror = null;
          this._id = newId();
          live.set(this._id, this);
          if (live.size > 100) live.delete(live.keys().next().value);
          post({ type: 'notification', id: this._id, title: this.title, body: this.body, silent: this.silent });
          setTimeout(() => this._fire('show'), 0);
        }
        _fire(name) {
          const event = new Event(name);
          this.dispatchEvent(event);
          const handler = this['on' + name];
          if (typeof handler === 'function') handler.call(this, event);
        }
        close() { if (live.delete(this._id)) this._fire('close'); }
        static get permission() { return 'granted'; }
        static requestPermission(callback) {
          if (typeof callback === 'function') callback('granted');
          return Promise.resolve('granted');
        }
      }
      SwitchboardNotification.maxActions = 0;
      Object.defineProperty(window, 'Notification', { value: SwitchboardNotification, writable: true, configurable: true });
      window.__switchboardNotificationClicked = (id) => { const n = live.get(id); if (n) n._fire('click'); };

      if (window.ServiceWorkerRegistration) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options = {}) {
          post({ type: 'notification', id: newId(), title: String(title), body: options.body ? String(options.body) : '', silent: !!options.silent });
          return Promise.resolve();
        };
        ServiceWorkerRegistration.prototype.getNotifications = () => Promise.resolve([]);
      }

      if (navigator.permissions && navigator.permissions.query) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (desc) => desc && desc.name === 'notifications'
          ? Promise.resolve({ state: 'granted', status: 'granted', onchange: null, addEventListener() {}, removeEventListener() {} })
          : query(desc);
      }

      const open = window.open;
      // Slack calls open('', 'main') to focus its main window, which an embedded view doesn't have.
      window.open = function (url, target, features) {
        if (!url && target && target !== '_blank' && !features) { window.focus(); return window; }
        return open.apply(this, arguments);
      };

      if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
        const enumerate = navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);
        let primed = false;
        // WebKit hides device IDs until capture is granted; Slack huddles give up instead of asking.
        navigator.mediaDevices.enumerateDevices = async () => {
          const devices = await enumerate();
          if (primed || !devices.some((d) => !d.deviceId) || !(navigator.userActivation && navigator.userActivation.isActive)) return devices;
          primed = true;
          try {
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            stream.getTracks().forEach((t) => t.stop());
          } catch (_) {
            return devices;
          }
          return enumerate();
        };
      }

      navigator.setAppBadge = (count) => { post({ type: 'badge', count: count === undefined ? -1 : Number(count) }); return Promise.resolve(); };
      navigator.clearAppBadge = () => { post({ type: 'badge', count: 0 }); return Promise.resolve(); };
    })();
    """

    /// Async function body: returns candidate icon URLs, best first.
    static let iconCandidates = """
    const found = [];
    const add = (href, score) => { try { found.push({ href: new URL(href, document.baseURI).href, score }); } catch (_) {} };
    const sizeOf = (s) => Math.max(0, ...String(s || '').split(/\\s+/).map((p) => p === 'any' ? 256 : parseInt(p, 10) || 0));
    const manifest = document.querySelector('link[rel="manifest"]');
    if (manifest) {
      try {
        const json = await (await fetch(manifest.href, { credentials: 'include' })).json();
        for (const icon of json.icons || []) {
          const purpose = String(icon.purpose || 'any');
          if (/monochrome/.test(purpose)) continue;
          const penalty = /any/.test(purpose) ? 0 : 1000;
          add(new URL(icon.src, manifest.href).href, sizeOf(icon.sizes) - penalty);
        }
      } catch (_) {}
    }
    for (const link of document.querySelectorAll('link[rel~="icon"], link[rel~="apple-touch-icon"], link[rel~="apple-touch-icon-precomposed"]')) {
      const touch = /apple-touch-icon/.test(link.rel);
      add(link.href, sizeOf(link.getAttribute('sizes')) || (touch ? 180 : 16));
    }
    add('/apple-touch-icon.png', -2000);
    add('/favicon.ico', -2001);
    found.sort((a, b) => b.score - a.score);
    return [...new Set(found.map((f) => f.href))];
    """
}
