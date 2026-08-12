/*
 * 보안 트랙 인터랙티브 퀴즈
 *
 * partials/nrp-assets.adoc 이 <script> 블록 안으로 이 파일을 include 합니다.
 * 페이지의 .nrp-quiz 블록을 찾아 라디오 버튼 채점기를 붙이며,
 * 정답은 각 블록의 data-answer 속성에 있습니다.
 *
 * 점진적 향상(progressive enhancement):
 *   - 아래 첫 줄이 <html> 에 nrp-js 클래스를 붙입니다. 이 스크립트는 퀴즈 마크업보다
 *     앞쪽에서 실행되므로 해설이 잠깐 보였다 사라지는 현상이 없습니다.
 *   - 그 클래스가 있을 때만 CSS 가 해설을 숨깁니다.
 *   - 따라서 JS 가 실패하면 해설이 그냥 펼쳐진 채로 보입니다(내용 손실 없음).
 */
(function () {
  'use strict';

  document.documentElement.classList.add('nrp-js');

  var CORRECT = '정답입니다';
  var WRONG = '아쉽습니다';

  function setup(quiz) {
    var answer = (quiz.getAttribute('data-answer') || '').trim().toUpperCase();
    var button = quiz.querySelector('.nrp-quiz-check');
    var result = quiz.querySelector('.nrp-quiz-result');
    var options = quiz.querySelectorAll('.nrp-opt');
    var inputs = quiz.querySelectorAll('.nrp-opt input[type="radio"]');

    if (!answer || !button || !result || !inputs.length) return;

    function clearMarks() {
      Array.prototype.forEach.call(options, function (option) {
        option.classList.remove('is-correct', 'is-wrong');
      });
      quiz.classList.remove('is-prompt', 'is-answered');
      result.textContent = '';
    }

    // 다른 보기를 고르면 채점 결과를 지우고 다시 풀 수 있게 합니다.
    Array.prototype.forEach.call(inputs, function (input) {
      input.addEventListener('change', clearMarks);
    });

    button.addEventListener('click', function () {
      var checked = quiz.querySelector('.nrp-opt input[type="radio"]:checked');

      if (!checked) {
        quiz.classList.remove('is-answered');
        quiz.classList.add('is-prompt');
        result.className = 'nrp-quiz-result is-prompt-msg';
        result.textContent = '보기를 하나 선택한 뒤 확인해 주십시오.';
        return;
      }

      var picked = checked.value.trim().toUpperCase();
      var isCorrect = picked === answer;

      Array.prototype.forEach.call(options, function (option) {
        var input = option.querySelector('input[type="radio"]');
        if (!input) return;
        var value = input.value.trim().toUpperCase();
        option.classList.toggle('is-correct', value === answer);
        option.classList.toggle('is-wrong', !isCorrect && value === picked);
      });

      quiz.classList.remove('is-prompt');
      quiz.classList.add('is-answered');
      result.className = 'nrp-quiz-result ' + (isCorrect ? 'is-correct-msg' : 'is-wrong-msg');
      result.textContent = isCorrect
        ? CORRECT + ' — (' + answer + ')'
        : WRONG + ' — 정답은 (' + answer + ') 입니다. 아래 해설을 확인해 보십시오.';
    });
  }

  function init() {
    Array.prototype.forEach.call(document.querySelectorAll('.nrp-quiz'), setup);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
