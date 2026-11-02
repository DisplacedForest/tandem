from pathlib import Path
import json

root=Path(__file__).resolve().parent
spec=json.loads((root/'motion.json').read_text())
(root/'svg').mkdir(exist_ok=True)
master=(root/'logo-master.svg').read_text()
defs=master.split('<defs>')[1].split('</defs>')[0].split('<clipPath')[0]

def svg(seq):
    frames=seq['frames']
    times=';'.join(str(f[0]) for f in frames)
    splines=';'.join(['0.333333 0 0.666667 1']*(len(frames)-1))
    repeat='indefinite' if seq['loop'] else '1'
    def anim(attr,vals,kind=None):
        tag='animateTransform' if kind else 'animate'
        extra=f' type="{kind}"' if kind else ''
        return f'<{tag} attributeName="{attr}"{extra} values="{vals}" keyTimes="{times}" keySplines="{splines}" calcMode="spline" dur="{seq["duration"]}s" repeatCount="{repeat}" fill="freeze"/>'
    def circle(side,fill):
        offset=1 if side=='left' else 4
        cx=128 if side=='left' else 282
        attrs=[('cx',[cx+f[offset] for f in frames]),('cy',[128+f[offset+1] for f in frames]),('r',[128*f[offset+2] for f in frames])]
        return '<circle cx="'+str(attrs[0][1][0])+'" cy="'+str(attrs[1][1][0])+'" r="'+str(attrs[2][1][0])+'" fill="'+fill+'">'+''.join(anim(a,';'.join(str(x) for x in vals)) for a,vals in attrs)+'</circle>'
    clip=circle('left','black')
    left=circle('left','url(#left-shading)')
    right=circle('right','url(#right-shading)')
    lens=circle('right','url(#overlap-shading)')
    rotate=anim('transform',';'.join(str(f[7]) for f in frames),'rotate')
    scale=anim('transform',';'.join(str(f[8]) for f in frames),'scale')
    static='<circle cx="128" cy="128" r="128" fill="url(#left-shading)"/><circle cx="282" cy="128" r="128" fill="url(#right-shading)"/><g clip-path="url(#static-left)"><circle cx="282" cy="128" r="128" fill="url(#overlap-shading)"/></g>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="-65 -105 540 466" role="img" aria-label="Tandem {seq['name']} animation">
<style>.still{{display:none}}@media(prefers-reduced-motion:reduce){{.moving{{display:none}}.still{{display:inline}}}}</style>
<defs>{defs}<clipPath id="moving-left">{clip}</clipPath><clipPath id="static-left"><circle cx="128" cy="128" r="128"/></clipPath></defs>
<g class="moving"><g transform="translate(205 128)"><g>{rotate}<g>{scale}<g transform="translate(-205 -128)">{left}{right}<g clip-path="url(#moving-left)">{lens}</g></g></g></g></g></g>
<g class="still">{static}</g>
</svg>'''

art={s['name']:svg(s) for s in spec['sequences']}
for name,source in art.items(): (root/'svg'/f'tandem-{name.lower()}.svg').write_text(source+'\n')
html='''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Tandem motion</title>
<style>
:root{color-scheme:dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#171917;color:#f3f4ef}*{box-sizing:border-box}body{margin:0;padding:40px;max-width:1180px;margin-inline:auto}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:28px}h1{font-size:26px;letter-spacing:-.6px;margin:0}a{color:#bbd899}button,select,input{font:inherit}button,select{color:inherit;background:#292d27;border:1px solid #444a3f;border-radius:9px;padding:10px 15px;cursor:pointer}button:hover{background:#353c30}button:focus-visible,select:focus-visible,input:focus-visible,a:focus-visible{outline:3px solid #c5e5a2;outline-offset:4px}.stage{background:#20241e;border:1px solid #383e33;border-radius:22px;min-height:410px;display:grid;place-items:center;overflow:hidden}.stage.light{background:#f1f1ea}.stage svg{display:block;max-width:100%;height:auto}h2{margin:0;font-size:23px}#description{color:#b4bcae;margin:6px 0 0}.caption{display:flex;align-items:center;justify-content:space-between;margin:20px 0 24px}.controls{display:flex;gap:18px;align-items:center;flex-wrap:wrap;margin-bottom:28px}.controls label{display:flex;align-items:center;gap:9px;font-size:14px}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}.choice{text-align:left;padding:16px 18px;background:#20241e}.choice[aria-pressed=true]{border-color:#bddb9c;background:#303b29}.choice strong{display:block;font-size:15px}.choice span{display:block;color:#b4bcae;font-size:12px;margin-top:7px}.footer{color:#adb5a8;font-size:13px;margin-top:28px;line-height:1.6}@media(max-width:700px){body{padding:22px}.grid{grid-template-columns:repeat(2,1fr)}.stage{min-height:300px}.caption{gap:20px}header{gap:20px}header a{font-size:13px}}@media(prefers-reduced-motion:reduce){*{scroll-behavior:auto}}
</style>
<header><h1>Tandem motion</h1><a href="logo-master.svg">Logo master</a></header>
<div class="stage" id="stage" aria-label="Selected logo animation"></div>
<div class="caption"><div><h2 id="name"></h2><p id="description"></p></div><a id="download" download>Download SVG</a></div>
<div class="controls"><button id="replay">Replay</button><button id="pause" aria-pressed="false">Pause</button><label>Speed <select id="speed"><option value=".5">0.5x</option><option selected value="1">1x</option><option value="1.5">1.5x</option><option value="2">2x</option></select></label><label>Size <select id="size"><option value="29">Menu bar</option><option value="47">Small</option><option value="120">Medium</option><option selected value="410">Large</option></select></label><label><input type="checkbox" id="light">Light background</label><label><input type="checkbox" id="reduce">Reduce motion</label></div>
<div class="grid" id="grid" aria-label="Motion sequences"></div>
<p class="footer">Select a sequence to play. The pair always returns to its resting identity. Listening and speaking are motion studies here; the app will use actual capture and playback events.</p>
<script>
const sequences=SEQUENCE_DATA;
const artwork=ARTWORK_DATA;
const stage=document.querySelector('#stage');
const grid=document.querySelector('#grid');
const media=matchMedia('(prefers-reduced-motion: reduce)');
const reduce=document.querySelector('#reduce');
reduce.checked=media.matches;
let selected=sequences[0],elapsed=0,previous=null,paused=false,visible=true,raf=0,animation=null;
function settle(){elapsed=0;previous=null;if(animation)animation.setCurrentTime(0)}
function applyReduction(){const low=reduce.checked||media.matches;stage.querySelector('.moving').style.display=low?'none':'inline';stage.querySelector('.still').style.display=low?'inline':'none';previous=null;schedule()}
function tick(now){raf=0;if(!previous)previous=now;if(!paused&&visible&&!document.hidden&&!reduce.checked&&!media.matches){elapsed+=(now-previous)/1000*Number(document.querySelector('#speed').value);animation.setCurrentTime(selected.loop?elapsed%selected.duration:Math.min(elapsed,selected.duration))}previous=now;schedule()}
function schedule(){if(raf)return;if(paused||!visible||document.hidden||reduce.checked||media.matches)return;if(!selected.loop&&elapsed>=selected.duration)return;raf=requestAnimationFrame(tick)}
function select(name){selected=sequences.find(s=>s.name===name);stage.innerHTML=artwork[name];animation=stage.querySelector('svg');animation.pauseAnimations();animation.style.width=document.querySelector('#size').value+'px';settle();document.querySelector('#name').textContent=name;document.querySelector('#description').textContent=selected.use;document.querySelector('#download').href='svg/tandem-'+name.toLowerCase()+'.svg';grid.querySelectorAll('button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.name===name)));applyReduction()}
for(const s of sequences){const b=document.createElement('button');b.className='choice';b.dataset.name=s.name;b.innerHTML='<strong>'+s.name+'</strong><span>'+s.use+'</span>';b.onclick=()=>select(s.name);grid.append(b)}
document.querySelector('#replay').onclick=()=>{settle();paused=false;document.querySelector('#pause').textContent='Pause';document.querySelector('#pause').setAttribute('aria-pressed','false');schedule()};
document.querySelector('#pause').onclick=e=>{paused=!paused;e.target.textContent=paused?'Resume':'Pause';e.target.setAttribute('aria-pressed',String(paused));previous=null;schedule()};
document.querySelector('#speed').onchange=()=>{previous=null;schedule()};
document.querySelector('#size').onchange=e=>animation.style.width=e.target.value+'px';
document.querySelector('#light').onchange=e=>stage.classList.toggle('light',e.target.checked);
reduce.onchange=applyReduction;media.addEventListener('change',applyReduction);
document.addEventListener('visibilitychange',()=>{previous=null;schedule()});
new IntersectionObserver(entries=>{visible=entries[0].isIntersecting;previous=null;schedule()}).observe(stage);
select('Breathe');
</script></html>'''
html=html.replace('SEQUENCE_DATA',json.dumps(spec['sequences'])).replace('ARTWORK_DATA',json.dumps(art))
(root/'index.html').write_text(html)
print('Built 12 standalone animated SVGs and gallery')
