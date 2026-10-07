/*
 * 보안 트랙 "복사" 버튼
 *
 * partials/nrp-assets.adoc 이 <script> 블록 안으로 이 파일을 include 합니다.
 * 페이지의 .nrp-copy-btn 버튼을 누르면 data-copy 속성 값을 클립보드에 복사합니다.
 *
 * 점진적 향상: 버튼은 html.nrp-js 일 때만 보이며(nrp-quiz.js 가 클래스를 붙임),
 * JS 가 실패해도 값은 화면에 그대로 있어 직접 선택해 복사할 수 있습니다.
 */
(function () {
  'use strict';

  document.documentElement.classList.add('nrp-js');

  var DONE = '복사됨 ✓';
  var FAIL = '복사 실패';

  // navigator.clipboard 를 쓸 수 없는 환경(비보안 컨텍스트, iframe 권한 등)을 위한 대체 경로
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
