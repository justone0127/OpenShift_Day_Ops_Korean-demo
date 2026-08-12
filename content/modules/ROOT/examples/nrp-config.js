/*
 * 실습 계정 입력 위젯
 *
 * 참가자가 가이드 상단에서 계정과 비밀번호를 한 번 입력하면,
 * 페이지의 명령어 블록에 있는 __USER__ / __PASSWORD__ 자리표시자가 그 값으로 바뀝니다.
 * 클릭 실행(재생 버튼)이 바뀐 텍스트를 그대로 보내므로 손으로 고칠 필요가 없습니다.
 *
 * 값은 브라우저 localStorage 에 저장되어 다른 모듈 페이지로 넘어가도 유지됩니다.
 * 서버로 전송되지 않습니다.
 *
 * JS 가 동작하지 않아도 자리표시자가 그대로 보이므로, 참가자가 직접 고쳐 쓰면 됩니다.
 */
(function () {
  'use strict';

  var KEY_USER = 'nrp.labUser';
  var KEY_PASS = 'nrp.labPassword';
  var PH_USER = '__USER__';
  var PH_PASS = '__PASSWORD__';

  function read(key) {
    try { return window.localStorage.getItem(key) || ''; } catch (e) { return ''; }
  }
  function write(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* 저장 실패는 무시 */ }
  }

  // 자리표시자를 값으로 바꿉니다. 원본은 data 속성에 보관해 두어 다시 바꿀 수 있게 합니다.
  function applyTo(el, user, pass) {
    if (!el.hasAttribute('data-nrp-template')) {
      if (el.textContent.indexOf(PH_USER) === -1 && el.textContent.indexOf(PH_PASS) === -1) return;
      el.setAttribute('data-nrp-template', el.textContent);
    }
    var tpl = el.getAttribute('data-nrp-template');
    el.textContent = tpl
      .split(PH_USER).join(user || PH_USER)
      .split(PH_PASS).join(pass || PH_PASS);
  }

  function applyAll(user, pass) {
    var nodes = document.querySelectorAll('.doc pre code, .doc code, .doc .nrp-echo');
    Array.prototype.forEach.call(nodes, function (el) { applyTo(el, user, pass); });
  }

  function setup() {
    var form = document.querySelector('.nrp-config');
    var user = read(KEY_USER);
    var pass = read(KEY_PASS);

    // 위젯이 없는 페이지(모듈 2·3 등)에서도 저장된 값으로 치환합니다.
    applyAll(user, pass);
    if (!form) return;

    var inUser = form.querySelector('.nrp-config-user');
    var inPass = form.querySelector('.nrp-config-pass');
    var btn = form.querySelector('.nrp-config-apply');
    var msg = form.querySelector('.nrp-config-msg');
    if (!inUser || !inPass || !btn) return;

    inUser.value = user;
    inPass.value = pass;

    function apply() {
      var u = inUser.value.trim();
      var p = inPass.value;
      write(KEY_USER, u);
      write(KEY_PASS, p);
      applyAll(u, p);
      if (msg) {
        msg.textContent = u
          ? '적용되었습니다. 아래 명령들이 ' + u + ' 계정으로 바뀌었습니다.'
          : '계정을 입력하면 아래 명령에 반영됩니다.';
        msg.className = 'nrp-config-msg' + (u ? ' is-ok' : '');
      }
    }

    btn.addEventListener('click', apply);
    inUser.addEventListener('keydown', function (e) { if (e.key === 'Enter') apply(); });
    inPass.addEventListener('keydown', function (e) { if (e.key === 'Enter') apply(); });

    if (user && msg) {
      msg.textContent = '저장된 계정 ' + user + ' 이(가) 적용되어 있습니다.';
      msg.className = 'nrp-config-msg is-ok';
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', setup);
  } else {
    setup();
  }
})();
