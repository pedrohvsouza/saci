/*
 * Saci Turbo Drive (vendored, dependency-free, no npm).
 *
 * This is a deliberately small subset of Hotwire Turbo Drive:
 *   - intercepts same-origin links and GET/POST form submissions
 *   - fetches the response and swaps <body> + <title> via DOMParser
 *   - updates history with pushState/replaceState and handles popstate
 *   - preserves scroll positions per history entry
 *   - dispatches `turbo:before-fetch-request`, `turbo:before-render`,
 *     `turbo:render` and `turbo:load` CustomEvents on `document`
 *   - falls back to normal browser navigation on any failure
 *
 * Opt out per element with `data-turbo="false"` (on the link/form or any
 * ancestor). Cross-origin links, downloads, target=_blank, modified clicks
 * and non-HTML responses are never intercepted.
 *
 * Inline <script> elements inside the new <body> are re-created so they run
 * after a swap. There is no prefetch cache and no morphing: the entire body
 * is replaced, which is the documented G70 subset.
 */
(function () {
  "use strict";

  var currentScript = document.currentScript;
  var lastUrl = window.location.href;
  var inFlight = false;

  function enabled() {
    if (document.documentElement.getAttribute("data-turbo") === "false") return false;
    return document.documentElement.getAttribute("data-turbo-drive") !== "false";
  }

  function sameOrigin(url) {
    try {
      return new URL(url, window.location.href).origin === window.location.origin;
    } catch (_error) {
      return false;
    }
  }

  function dispatch(name, detail) {
    var event = new CustomEvent("turbo:" + name, {
      bubbles: true,
      cancelable: name === "before-fetch-request" || name === "before-render",
      detail: detail || {}
    });
    document.dispatchEvent(event);
    return !event.defaultPrevented;
  }

  function rememberScroll() {
    try {
      var state = Object.assign({}, window.history.state || {}, {
        turboDrive: true,
        scrollY: window.scrollY
      });
      window.history.replaceState(state, "", window.location.href);
    } catch (_error) {
      /* history is unavailable in some embedded webviews; ignore */
    }
  }

  function pushOrReplace(action, url, scrollY) {
    if (action === "none" || !action) return;
    var state = { turboDrive: true, scrollY: scrollY };
    try {
      if (action === "replace") {
        window.history.replaceState(state, "", url);
      } else {
        window.history.pushState(state, "", url);
      }
    } catch (_error) {
      /* fall back to navigation if the URL cannot be pushed */
      window.location.assign(url);
    }
  }

  function fetchPage(url, fetchOptions) {
    var options = Object.assign(
      {
        credentials: "same-origin",
        redirect: "follow",
        headers: { Accept: "text/html, application/xhtml+xml" }
      },
      fetchOptions || {}
    );

    if (!dispatch("before-fetch-request", { url: url, fetchOptions: options })) {
      return Promise.resolve({ cancelled: true });
    }

    return fetch(url, options)
      .then(function (response) {
        var type = response.headers.get("content-type") || "";
        if (!response.ok || type.toLowerCase().indexOf("text/html") === -1) {
          return { failed: true, status: response.status };
        }
        return response.text().then(function (html) {
          return { html: html, url: response.url || url };
        });
      })
      .catch(function () {
        return { failed: true };
      });
  }

  function activateScripts(root) {
    var scripts = root.querySelectorAll("script");
    for (var i = 0; i < scripts.length; i++) {
      var oldScript = scripts[i];
      var script = document.createElement("script");
      for (var j = 0; j < oldScript.attributes.length; j++) {
        script.setAttribute(oldScript.attributes[j].name, oldScript.attributes[j].value);
      }
      script.textContent = oldScript.textContent;
      oldScript.replaceWith(script);
    }
  }

  function scrollToPosition(position, url) {
    var hash = "";
    try {
      hash = new URL(url, window.location.href).hash;
    } catch (_error) {
      hash = "";
    }
    if (hash) {
      var target = document.getElementById(decodeURIComponent(hash.slice(1)));
      if (target) {
        target.scrollIntoView();
        return;
      }
    }
    window.scrollTo(0, typeof position === "number" ? position : 0);
  }

  function renderPage(html, url, action, restoreScroll) {
    var parsed = new DOMParser().parseFromString(html, "text/html");
    if (!parsed || !parsed.body) return false;

    if (!dispatch("before-render", { newBody: parsed.body, url: url, action: action })) {
      return false;
    }

    var title = parsed.querySelector("title");
    if (title) document.title = title.textContent || "";

    var newBody = document.importNode(parsed.body, true);
    document.body.replaceWith(newBody);
    activateScripts(document.body);

    lastUrl = window.location.href;
    dispatch("render", { url: url, action: action });
    dispatch("load", { url: url, action: action });

    var position = typeof restoreScroll === "number" ? restoreScroll : null;
    window.requestAnimationFrame(function () {
      scrollToPosition(position, url);
    });
    return true;
  }

  function fallback(url, form) {
    if (form) {
      form.submit();
    } else {
      window.location.assign(url);
    }
  }

  function visit(url, options) {
    options = options || {};
    if (!enabled()) {
      fallback(url, options.form);
      return;
    }
    if (inFlight) return;
    inFlight = true;

    var action = options.historyAction || "push";
    if (action === "push") rememberScroll();

    fetchPage(url, options.fetchOptions)
      .then(function (result) {
        if (result.cancelled) return;
        if (result.failed || !result.html) {
          fallback(url, options.form);
          return;
        }

        var finalUrl = result.url || url;
        if (!sameOrigin(finalUrl)) {
          fallback(url, options.form);
          return;
        }
        // Push before rendering so `turbo:load` listeners observe the new URL.
        pushOrReplace(action, finalUrl, action === "replace" ? null : 0);
        if (!renderPage(result.html, finalUrl, action, options.restoreScroll)) {
          // A before-render listener cancelled the swap; keep the old page.
          if (action === "push" || action === "replace") {
            window.history.replaceState({ turboDrive: true, scrollY: window.scrollY }, "", lastUrl);
          }
        }
      })
      .finally(function () {
        inFlight = false;
      });
  }

  function linkUrl(link) {
    var raw = link.getAttribute("href");
    if (!raw || raw.charAt(0) === "#") return null;
    if (/^(mailto:|tel:|javascript:|data:|blob:)/i.test(raw)) return null;
    if (link.hasAttribute("download")) return null;
    if (link.target && link.target !== "_self") return null;
    if (link.closest('[data-turbo="false"]')) return null;
    var url = new URL(raw, window.location.href);
    if (url.origin !== window.location.origin) return null;
    if (url.href === window.location.href) return null;
    // Same document anchor: let the browser scroll natively.
    if (url.pathname === window.location.pathname &&
        url.search === window.location.search &&
        url.hash) return null;
    return url.href;
  }

  document.addEventListener("click", function (event) {
    if (!enabled() || event.defaultPrevented) return;
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    var link = event.target instanceof Element ? event.target.closest("a[href]") : null;
    if (!link) return;
    var url = linkUrl(link);
    if (!url) return;
    event.preventDefault();
    visit(url, { historyAction: "push" });
  });

  function formUrl(form, submitter) {
    var rawAction = (submitter && submitter.getAttribute("formaction")) ||
      form.getAttribute("action") || window.location.href;
    var url = new URL(rawAction, window.location.href);
    if (url.origin !== window.location.origin) return null;
    return url;
  }

  document.addEventListener("submit", function (event) {
    if (!enabled() || event.defaultPrevented) return;
    var form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (form.target && form.target !== "_self") return;
    if (form.closest('[data-turbo="false"]')) return;
    if ((form.getAttribute("method") || "get").toLowerCase() === "dialog") return;

    var submitter = event.submitter;
    var url = formUrl(form, submitter);
    if (!url) return;

    var method = ((submitter && submitter.getAttribute("formmethod")) ||
      form.getAttribute("method") || "get").toUpperCase();

    if (method === "GET") {
      var params = new URLSearchParams();
      new FormData(form).forEach(function (value, key) {
        if (typeof value === "string") params.append(key, value);
      });
      url.search = params.toString();
      event.preventDefault();
      visit(url.href, { historyAction: "push" });
    } else {
      var body = new FormData(form);
      event.preventDefault();
      visit(url.href, {
        historyAction: "replace",
        fetchOptions: { method: method, body: body },
        form: form
      });
    }
  });

  window.addEventListener("popstate", function (event) {
    if (!enabled()) return;
    if (!event.state || !event.state.turboDrive) return;
    visit(window.location.href, {
      historyAction: "none",
      restoreScroll: event.state.scrollY,
      form: null
    });
  });

  function boot() {
    if (!enabled()) return;
    try {
      var state = Object.assign({}, window.history.state || {}, {
        turboDrive: true,
        scrollY: window.scrollY
      });
      window.history.replaceState(state, "", window.location.href);
    } catch (_error) {
      /* ignore */
    }
    dispatch("load", { url: window.location.href, action: "load" });
  }

  window.SaciTurboDrive = {
    visit: function (url) { visit(url, { historyAction: "push" }); },
    enabled: enabled,
    version: "vendored-1"
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  if (currentScript) currentScript.setAttribute("data-turbo-drive-ready", "true");
})();
