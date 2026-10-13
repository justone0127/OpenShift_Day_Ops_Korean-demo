/*
 * Interactive quiz for the security track
 *
 * partials/nrp-assets.adoc includes this file inside a <script> block.
 * It finds the .nrp-quiz blocks on the page and attaches a radio-button grader;
 * the correct answer is in each block's data-answer attribute.
 *
 * Progressive enhancement:
 *   - The first line below adds the nrp-js class to <html>. This script runs before the
 *     quiz markup, so explanations never flash on screen and then disappear.
 *   - CSS hides the explanations only when that class is present.
 *   - So if JS fails, the explanations are simply shown expanded (no content is lost).
 */
(function () {
  'use strict';

  document.documentElement.classList.add('nrp-js');

  var CORRECT = 'Correct';
  var WRONG = 'Not quite';

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

    // Picking a different option clears the result so the quiz can be retried.
    Array.prototype.forEach.call(inputs, function (input) {
      input.addEventListener('change', clearMarks);
    });

    button.addEventListener('click', function () {
      var checked = quiz.querySelector('.nrp-opt input[type="radio"]:checked');

      if (!checked) {
        quiz.classList.remove('is-answered');
        quiz.classList.add('is-prompt');
        result.className = 'nrp-quiz-result is-prompt-msg';
        result.textContent = 'Please select an option, then check your answer.';
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
        : WRONG + ' — the answer is (' + answer + '). See the explanation below.';
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
