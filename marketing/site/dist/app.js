const templates = [
  `<div class="waveform" aria-hidden="true">${'<i></i>'.repeat(9)}</div><span class="source">Voice · example</span><h3 style="margin-top:20px">Say what you lifted.</h3><p class="spoken">“Done. Eight reps at eighty pounds.”</p><p class="note">A repetition (rep) is one complete exercise movement. Here, you report eight repetitions at 80 pounds. Setecho records what you say.</p>`,
  `<span class="source">You said</span><h3 style="margin-top:20px">Set logged.</h3><p>Incline dumbbell press · set 1</p><div class="big-value">80 <small>lb</small> × 8 <small>reps</small></div><div class="demo-row"><span>Next set</span><strong>65 lb × 8–10 reps<small>From the coach’s program</small></strong></div><p class="note">The record keeps its source. If you misspoke, say “that was seven” to correct it.</p>`,
  `<h3>Your progress update, partly filled.</h3><div class="demo-row"><span>Average daily steps</span><strong>8,420<small>Apple Health</small></strong></div><div class="demo-row"><span>Average sleep</span><strong>7.4 hours<small>Apple Health</small></strong></div><div class="demo-row"><span>Training completed</span><strong>4 of 4 sessions<small>Training log</small></strong></div><p class="note">This progress update is your check-in. Answer the remaining questions out loud, then review the message and photos before sending them to your coach on WhatsApp.</p>`,
  `<span class="source">Coach’s words · example</span><h3 style="margin-top:20px">Review your coach’s change.</h3><p class="quote">“Use 85 pounds for the first set of incline dumbbell presses next week.”</p><p>Incline dumbbell press · first set</p><div class="diff"><del>80 lb</del><span aria-hidden="true">→</span><strong>85 lb</strong></div><span class="waiting">Waiting for your approval</span><p class="note">The plan has not changed. The coach’s exact words stay beside the proposed edit.</p>`,
  `<span class="source">Approved by you · example</span><h3 style="margin-top:20px">The plan is up to date.</h3><p>Incline dumbbell press · first set · from next week</p><div class="diff"><del>80 lb</del><span aria-hidden="true">→</span><strong>85 lb</strong></div><p class="approved">Change applied to the example plan.</p><p class="note">In the app, History keeps the change and lets you undo the latest plan update. Your human coach decides what to change; you approve it.</p>`
];
const labels = ['Log this example set', 'Prepare the progress update', 'Read the coach’s reply', 'Approve this example change', 'Replay the walkthrough'];
let step = 0;
let approved = false;
const stage = document.querySelector('#demo-content');
const advance = document.querySelector('#advance');
function show(next) {
  // A direct click on Plan update must still go through the approval step.
  step = next === 4 && !approved ? 3 : next;
  stage.innerHTML = `<div class="enter">${templates[step]}</div>`;
  advance.textContent = labels[step];
  document.querySelectorAll('[data-step]').forEach(button => {
    if (Number(button.dataset.step) === step) {
      button.setAttribute('aria-current', 'step');
      const strip = document.querySelector('#steps');
      strip.scrollLeft = button.offsetLeft - strip.offsetLeft - 8;
    }
    else button.removeAttribute('aria-current');
  });
}
document.querySelectorAll('[data-step]').forEach(button => button.addEventListener('click', () => show(Number(button.dataset.step))));
advance.addEventListener('click', () => {
  if (step === 3) approved = true;
  if (step === 4) { approved = false; show(0); }
  else show(step + 1);
});
document.querySelector('#replay').addEventListener('click', () => { approved = false; show(0); });
document.querySelector('a[href="#privacy"]').addEventListener('click', event => {
  event.preventDefault(); document.querySelector('#privacy').showModal();
});
show(0);
