/*
 * "Copy" buttons for the security track
 *
 * partials/nrp-assets.adoc includes this file inside a <script> block.
 * Clicking a .nrp-copy-btn button copies its data-copy attribute value to the clipboard.
 *
 * Progressive enhancement: buttons are shown only when html.nrp-js is set (nrp-quiz.js adds the class),
 * and if JS fails the values remain on screen so they can be selected and copied by hand.
 */
(function () {
  'use strict';

  document.documentElement.classList.add('nrp-js');

  var DONE = 'Copied ✓';
  var FAIL = 'Copy failed';

  // Fallback for environments where navigator.clipboard is unavailable (insecure context, iframe permissions, etc.)
  function fallbackCopy(text) {
    var area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.style.position = 'fixed';
    area.style.top = '-1000px';
    document.body.appendChild(area);
    area.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(area);
    return ok;
  }

  function copy(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(
        function () { return true; },
        function () { return fallbackCopy(text); }
      );
    }
    return Promise.resolve(fallbackCopy(text));
  }

  function setup(button) {
    var label = button.textContent;
    var timer = null;
    button.addEventListener('click', function () {
      copy(button.getAttribute('data-copy') || '').then(function (ok) {
        button.textContent = ok ? DONE : FAIL;
        button.classList.toggle('is-done', ok);
        clearTimeout(timer);
        timer = setTimeout(function () {
          button.textContent = label;
          button.classList.remove('is-done');
        }, 1500);
      });
    });
  }

  function init() {
    Array.prototype.forEach.call(document.querySelectorAll('.nrp-copy-btn'), setup);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
