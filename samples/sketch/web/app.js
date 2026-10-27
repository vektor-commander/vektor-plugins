// Sketch — the page of a web view sample. It talks only to its own plugin, through the `vektor` object Vektor defines
// before this script runs:
//
//   vektor.post(message)        send a JSON value to the plugin (it receives `web/message`)
//   vektor.onmessage = (m) =>   receive what the plugin sends with `web/post`
//
// There is no network and no file access here: the drawing is kept by the plugin, in its data folder.

const canvas = document.getElementById('canvas');
const context = canvas.getContext('2d');
const status = document.getElementById('status');
let strokes = [];
let current = null;
let role = 'accent';

// A stroke stores its colour *role*, never a colour: redrawn after a theme change it takes the new theme's colour.
const colourOf = (name) => getComputedStyle(document.documentElement).getPropertyValue('--vektor-role-' + name + '-mark').trim() || '#888';

function resize() {
  const ratio = window.devicePixelRatio || 1;
  const box = canvas.getBoundingClientRect();
  canvas.width = Math.max(1, Math.round(box.width * ratio));
  canvas.height = Math.max(1, Math.round(box.height * ratio));
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  draw();
}

function draw() {
  const box = canvas.getBoundingClientRect();
  context.clearRect(0, 0, box.width, box.height);
  context.lineCap = 'round';
  context.lineJoin = 'round';
  context.lineWidth = 3;
  for (const stroke of strokes.concat(current ? [current] : [])) {
    if (!stroke.points || stroke.points.length === 0) continue;
    context.strokeStyle = colourOf(stroke.role || 'accent');
    context.beginPath();
    stroke.points.forEach(([x, y], index) => (index === 0 ? context.moveTo(x, y) : context.lineTo(x, y)));
    context.stroke();
  }
}

function point(event) {
  const box = canvas.getBoundingClientRect();
  return [Math.round(event.clientX - box.left), Math.round(event.clientY - box.top)];
}

canvas.addEventListener('pointerdown', (event) => {
  canvas.setPointerCapture(event.pointerId);
  current = { role, points: [point(event)] };
});
canvas.addEventListener('pointermove', (event) => {
  if (!current) return;
  current.points.push(point(event));
  draw();
});
canvas.addEventListener('pointerup', () => {
  if (!current) return;
  strokes.push(current);
  current = null;
  save();
});

document.getElementById('clear').addEventListener('click', () => {
  strokes = [];
  draw();
  save();
});

for (const swatch of document.querySelectorAll('.swatch')) {
  swatch.style.background = `var(--vektor-role-${swatch.dataset.role}-mark)`;
  swatch.setAttribute('aria-pressed', String(swatch.dataset.role === role));
  swatch.addEventListener('click', () => {
    role = swatch.dataset.role;
    for (const other of document.querySelectorAll('.swatch')) other.setAttribute('aria-pressed', String(other === swatch));
  });
}

function save() {
  vektor.post({ type: 'save', strokes });
  status.textContent = strokes.length === 1 ? '1 stroke' : `${strokes.length} strokes`;
}

vektor.onmessage = (message) => {
  if (message && message.type === 'strokes' && Array.isArray(message.strokes)) {
    strokes = message.strokes;
    status.textContent = strokes.length === 1 ? '1 stroke' : `${strokes.length} strokes`;
    draw();
  }
};

// The theme changed (or the accent): redraw with the new colours.
window.addEventListener('vektor-theme', draw);
window.addEventListener('resize', resize);
resize();
vektor.post({ type: 'load' });
