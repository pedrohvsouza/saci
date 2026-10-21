/*
 * Saci Stimulus (vendored, dependency-free, no npm).
 *
 * A deliberately small subset of Hotwire Stimulus:
 *   - scans `data-controller="hello world"` and instantiates registered classes
 *   - resolves unregistered identifiers from `window.__SACI_STIMULUS_MODULES__`
 *     (identifier => ES module specifier) using dynamic `import()`
 *   - binds `data-action="click->hello#greet"` (also `keydown.esc->...`,
 *     `.prevent`, `.stop`, `.self`, `.once`, `.capture`, `.passive`)
 *   - provides `this.targets.find/findAll/has` over
 *     `data-hello-target="name"` elements
 *   - provides `this.values.get/has/set` over
 *     `data-hello-url-value` attributes (JSON parsed, strings accepted)
 *   - calls connect()/disconnect() and dispatches nothing implicitly
 *   - re-scans after `turbo:load` and watches for added/removed DOM nodes
 *
 * Controllers may extend `window.SaciStimulus.Controller` and export a
 * default class, or be registered explicitly:
 *
 *   SaciStimulus.register("hello", class extends SaciStimulus.Controller {
 *     connect() { this.element.textContent = "hi" }
 *   })
 */
(function () {
  "use strict";

  var modules = Object.assign({}, window.__SACI_STIMULUS_MODULES__ || {});
  var registry = new Map();
  var instances = new WeakMap();       // Element -> Map(identifier -> instance)
  var loading = new Map();             // identifier -> Promise
  var started = false;
  var observer = null;

  function keyFor(name) {
    return String(name)
      .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
      .replace(/_/g, "-")
      .toLowerCase();
  }

  class Targets {
    constructor(controller) {
      this.controller = controller;
    }

    selector(name) {
      return "[data-" + keyFor(this.controller.identifier) + "-target~=\"" + String(name) + "\"]";
    }

    find(name) {
      return this.controller.element.querySelector(this.selector(name));
    }

    findAll(name) {
      return Array.prototype.slice.call(this.controller.element.querySelectorAll(this.selector(name)));
    }

    has(name) {
      return !!this.find(name);
    }
  }

  class Values {
    constructor(controller) {
      this.controller = controller;
    }

    attribute(name) {
      return "data-" + keyFor(this.controller.identifier) + "-" + keyFor(name) + "-value";
    }

    has(name) {
      return this.controller.element.hasAttribute(this.attribute(name));
    }

    get(name, defaultValue) {
      var raw = this.controller.element.getAttribute(this.attribute(name));
      if (raw === null) return defaultValue;
      try {
        return JSON.parse(raw);
      } catch (_error) {
        return raw;
      }
    }

    set(name, value) {
      this.controller.element.setAttribute(this.attribute(name), JSON.stringify(value));
    }
  }

  class Controller {
    constructor(context) {
      this.element = context.element;
      this.identifier = context.identifier;
      this.targets = new Targets(this);
      this.values = new Values(this);
      this.__saciStimulusBindings = [];
    }

    connect() {}

    disconnect() {}

    dispatch(name, options) {
      options = options || {};
      var event = new CustomEvent(name, {
        bubbles: options.bubbles !== false,
        cancelable: options.cancelable !== false,
        detail: options.detail || {}
      });
      this.element.dispatchEvent(event);
      return !event.defaultPrevented;
    }
  }

  function mapFor(element) {
    var map = instances.get(element);
    if (!map) {
      map = new Map();
      instances.set(element, map);
    }
    return map;
  }

  function keyMatches(event, key) {
    var expected = key.toLowerCase();
    var actual = String(event.key || "").toLowerCase();
    if (expected === actual) return true;
    if (expected === "esc" && actual === "escape") return true;
    if (expected === "space" && actual === " ") return true;
    if (expected === "up" && actual === "arrowup") return true;
    if (expected === "down" && actual === "arrowdown") return true;
    if (expected === "left" && actual === "arrowleft") return true;
    if (expected === "right" && actual === "arrowright") return true;
    return false;
  }

  function parseAction(token) {
    var eventPart = "click";
    var methodPart = token;
    var arrow = token.indexOf("->");
    if (arrow !== -1) {
      eventPart = token.slice(0, arrow).trim();
      methodPart = token.slice(arrow + 2).trim();
    }
    var hash = methodPart.lastIndexOf("#");
    if (hash === -1) return null;
    var parts = eventPart.split(".");
    var eventName = parts.shift() || "click";
    return {
      identifier: methodPart.slice(0, hash).trim(),
      method: methodPart.slice(hash + 1).trim(),
      eventName: eventName,
      options: parts
    };
  }

  function bindActions(element, identifier, instance) {
    var nodes = [];
    if (element.hasAttribute("data-action")) nodes.push(element);
    element.querySelectorAll("[data-action]").forEach(function (node) { nodes.push(node); });

    nodes.forEach(function (node) {
      var tokens = (node.getAttribute("data-action") || "").split(/\s+/);
      tokens.forEach(function (token) {
        var parsed = parseAction(token);
        if (!parsed || parsed.identifier !== identifier) return;

        var listener = function (event) {
          if (parsed.options.indexOf("self") !== -1 && event.target !== node) return;
          var keyFilter = parsed.options.find(function (option) {
            return ["prevent", "stop", "self", "once", "capture", "passive"].indexOf(option) === -1;
          });
          if (keyFilter && event instanceof KeyboardEvent && !keyMatches(event, keyFilter)) return;

          if (parsed.options.indexOf("stop") !== -1) event.stopPropagation();
          if (parsed.options.indexOf("prevent") !== -1) event.preventDefault();

          var method = instance[parsed.method];
          if (typeof method !== "function") {
            console.warn("Saci Stimulus: " + identifier + "#" + parsed.method + " is not defined");
            return;
          }
          var result = method.call(instance, event);
          if (result === false) event.preventDefault();
        };

        var capture = parsed.options.indexOf("capture") !== -1;
        var options = {
          capture: capture,
          once: parsed.options.indexOf("once") !== -1,
          passive: parsed.options.indexOf("passive") !== -1
        };
        node.addEventListener(parsed.eventName, listener, options);
        instance.__saciStimulusBindings.push({
          node: node,
          eventName: parsed.eventName,
          listener: listener,
          capture: capture
        });
      });
    });
  }

  function disconnectIdentifier(element, identifier) {
    var map = instances.get(element);
    if (!map) return;
    var instance = map.get(identifier);
    if (!instance) return;
    try {
      if (typeof instance.disconnect === "function") instance.disconnect();
    } catch (error) {
      console.error("Saci Stimulus: disconnect failed for " + identifier, error);
    }
    (instance.__saciStimulusBindings || []).forEach(function (binding) {
      binding.node.removeEventListener(binding.eventName, binding.listener, binding.capture);
    });
    map.delete(identifier);
    if (map.size === 0) instances.delete(element);
  }

  function disconnectWithin(root) {
    if (!root || root.nodeType !== 1) return;
    var elements = [root];
    root.querySelectorAll("[data-controller]").forEach(function (element) { elements.push(element); });
    elements.forEach(function (element) {
      var map = instances.get(element);
      if (!map) return;
      Array.from(map.keys()).forEach(function (identifier) {
        disconnectIdentifier(element, identifier);
      });
    });
  }

  function instantiate(element, identifier, ControllerClass) {
    var context = { element: element, identifier: identifier, application: api };
    var instance;
    try {
      instance = new ControllerClass(context);
    } catch (error) {
      console.error("Saci Stimulus: failed to instantiate " + identifier, error);
      return;
    }
    mapFor(element).set(identifier, instance);
    bindActions(element, identifier, instance);
    try {
      if (typeof instance.connect === "function") instance.connect();
    } catch (error) {
      console.error("Saci Stimulus: connect failed for " + identifier, error);
    }
  }

  function connectIdentifier(element, identifier) {
    var map = instances.get(element);
    if (map && map.has(identifier)) return;

    var ControllerClass = registry.get(identifier);
    if (ControllerClass) {
      instantiate(element, identifier, ControllerClass);
      return;
    }

    var specifier = modules[identifier];
    if (!specifier) return;

    var pending = loading.get(identifier);
    if (!pending) {
      pending = import(specifier)
        .then(function (module) {
          var klass = module.default || module.Controller;
          if (typeof klass === "function") registry.set(identifier, klass);
        })
        .catch(function (error) {
          console.warn("Saci Stimulus: could not import " + specifier, error);
        })
        .finally(function () {
          loading.delete(identifier);
        });
      loading.set(identifier, pending);
    }

    pending.then(function () {
      if (!element.isConnected) return;
      if (registry.has(identifier)) connectIdentifier(element, identifier);
    });
  }

  function scan(root) {
    if (!started || !root) return;
    if (root.nodeType === 1 && root.hasAttribute("data-controller")) {
      scanElement(root);
    }
    if (root.querySelectorAll) {
      root.querySelectorAll("[data-controller]").forEach(scanElement);
    }
  }

  function scanElement(element) {
    (element.getAttribute("data-controller") || "").split(/\s+/).forEach(function (identifier) {
      if (identifier) connectIdentifier(element, identifier);
    });
  }

  function start() {
    if (started) return api;
    started = true;
    scan(document);
    observer = new MutationObserver(function (records) {
      records.forEach(function (record) {
        record.removedNodes.forEach(function (node) {
          if (node.nodeType === 1) disconnectWithin(node);
        });
        record.addedNodes.forEach(function (node) {
          if (node.nodeType === 1) scan(node);
        });
      });
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    return api;
  }

  function stop() {
    started = false;
    if (observer) observer.disconnect();
    observer = null;
    disconnectWithin(document.documentElement);
    return api;
  }

  var api = {
    Controller: Controller,
    register: function (identifier, ControllerClass) {
      registry.set(identifier, ControllerClass);
      if (started) scan(document);
      return ControllerClass;
    },
    unregister: function (identifier) {
      registry.delete(identifier);
      return api;
    },
    getControllerForElementAndIdentifier: function (element, identifier) {
      var map = instances.get(element);
      return map ? map.get(identifier) : undefined;
    },
    start: start,
    stop: stop,
    modules: modules
  };

  window.SaciStimulus = api;

  document.addEventListener("turbo:load", function () {
    if (started) scan(document);
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
