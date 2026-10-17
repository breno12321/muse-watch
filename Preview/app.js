'use strict';
const paths = {
 mic:'<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8"/>',
 arrow:'<path d="M7 17 17 7M7 7h10v10"/>',
 chat:'<path d="M21 11a9 9 0 0 1-9 9H8l-5 2 1-6a9 9 0 1 1 17-5Z"/>',
 sparkle:'<path d="m12 3 2.6 6.4L21 12l-6.4 2.6L12 21l-2.6-6.4L3 12l6.4-2.6Z"/>',
 sun:'<path d="M3 17h18M7 17a5 5 0 0 1 10 0M12 3v3M4 8l2 2M20 8l-2 2M6 21h12"/>',
 idea:'<path d="M9 18v-3a6 6 0 1 1 6 0v3M9 18h6M10 22h4"/>',
 goals:'<rect x="3" y="3" width="18" height="18" rx="5"/><path d="m7 12 3 3 7-7"/>',
 library:'<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
 feed:'<rect x="5" y="3" width="16" height="17" rx="3"/><path d="M2 7v13a3 3 0 0 0 3 3h12M9 8h8M9 12h8M9 16h5"/>',
 chevron:'<path d="m9 5 7 7-7 7"/>', back:'<path d="m15 5-7 7 7 7"/>',
 bookmark:'<path d="M6 3h12v19l-6-4-6 4Z"/>', play:'<path d="m8 4 12 8-12 8Z"/>',
 pause:'<path d="M8 4v16M16 4v16"/>', stop:'<rect x="5" y="5" width="14" height="14" rx="2"/>',
 up:'<path d="M12 20V4m-7 7 7-7 7 7"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.sparkle}</svg>`;
const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const uid = () => crypto.randomUUID();
const time = seconds => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
const avatar = (className='') => `<img class="avatar ${className}" src="../MuseWatch/Assets.xcassets/CalAvatar.imageset/avatar.jpg" alt="Cal · sample Muse avatar">`;
const message = (role,text, extra={}) => ({id:uid(),role,text,date:new Date().toISOString(),saved:false,...extra});
const initialState = () => ({
 chats:[{id:'cal',title:'Cal',symbol:'sparkle',messages:[message('muse','Hey, Breno. A little room for whatever’s on your mind.'),message('user','Let’s make a little space for a walk today.'),message('muse','A good idea. Start with ten minutes, leave your phone in your pocket, and see where you end up.')]},
 {id:'weekend',title:'Weekend ideas',symbol:'sun',messages:[message('user','Something simple for the weekend?'),message('muse','Coffee, a slow morning, and a new place to wander. We can keep the rest open.')]},
 {id:'inspiration',title:'A little inspiration',symbol:'idea',messages:[message('muse','Keep a tiny collection of things that catch your eye. A sentence, a color, a thought. It all counts.')]}],
 goals:[{title:'Make room to move',detail:'Take a ten-minute walk',complete:false},{title:'Stay curious',detail:'Save one idea each day',complete:false},{title:'Find a little quiet',detail:'Five minutes just for you',complete:false}],draft:null
});
let state;
try { state=JSON.parse(localStorage.getItem('muse-watch-v1')) || initialState(); } catch { state=initialState(); }
let page=0, route=null, activeChat='cal', section=null, recording=false, requesting=false, mediaRecorder=null, stream=null, chunks=[], startTime=0, timer=null, error='', pending=new Set(), audio=null, playingID=null, greeting=false, returnChat=false;
const screen=document.querySelector('#screen');
const heading=document.querySelector('#watch-heading');
let dbPromise;
function db(){
 if(!dbPromise) dbPromise=new Promise((resolve,reject)=>{const request=indexedDB.open('muse-watch-audio',1);request.onupgradeneeded=()=>request.result.createObjectStore('clips');request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
 return dbPromise;
}
async function clip(action,key,value){const database=await db();return new Promise((resolve,reject)=>{const tx=database.transaction('clips',action==='get'?'readonly':'readwrite');const store=tx.objectStore('clips');const request=action==='put'?store.put(value,key):store[action](key);let result;request.onsuccess=()=>{result=request.result};tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(tx.error);});}
function persist(){try{localStorage.setItem('muse-watch-v1',JSON.stringify(state));return true}catch{error='Your device couldn’t save this change. Please make some space and try again.';return false}}
function current(){return state.chats.find(c=>c.id===activeChat)}
function watchButton(label,action,name='mic',kind=''){return `<button class="watch-btn ${kind}" data-action="${action}">${icon(name)}${label}</button>`}
function row(title,subtitle,symbol,action,value=''){return `<button class="row" data-action="${action}" data-value="${escapeHTML(value)}"><span class="icon">${icon(symbol)}</span><div><strong>${escapeHTML(title)}</strong><small>${escapeHTML(subtitle)}</small></div><span class="chevron">${icon('chevron')}</span></button>`}
function back(label='Back'){return `<button class="back" data-action="back">${icon('back')}${label}</button>`}
function goPage(next){if(recording||requesting){error='Finish your voice note first.';render();return}stopPlayback();page=next;route=null;section=null;error='';render();screen.scrollTop=0;}
function home(){return `<div class="home"><div class="demo-tag">YOUR MUSE, A LITTLE CLOSER</div><button class="avatar-button" data-action="hello" aria-label="Say hello to Cal">${avatar()}</button><h2>Hey, Breno.</h2><p>${greeting?'Always happy to see you.':'Here for the little things.'}</p>${watchButton(state.draft?'Review voice note':'Talk to Cal','record',state.draft?'play':'mic')}<button class="continue" data-action="chat" data-value="cal">Continue chat ${icon('arrow')}</button></div>`}
function chats(){return `<p class="list-intro">Pick up where you left off.</p>${state.chats.map(c=>row(c.title,c.messages.at(-1)?.text||'Start a conversation',c.symbol,'chat',c.id)).join('')}<div class="demo-tag" style="text-align:center;margin-top:15px">DEMO CONVERSATIONS</div>`}
function sections(){return `<p class="list-intro">A little space for your world.</p>${[['Feed','A little update','feed'],['Ideas','A spark for your next thought','idea'],['Goals','Small steps, your pace','goals'],['Library','Things worth keeping','library']].map(([t,s,i])=>row(t,s,i,'section',t)).join('')}`}
function bubble(m,chatID){return `<article class="bubble ${m.role==='user'?'user':''}"><div class="bubble-head"><span>${m.role==='user'?'YOU':'CAL · DEMO'}</span><button class="save ${m.saved?'saved':''}" data-action="save" data-value="${m.id}" data-chat="${chatID}" aria-label="${m.saved?'Unsave message':'Save message to Library'}">${icon('bookmark')}</button></div>${m.audioID?`<button class="voice-play" data-action="play-message" data-value="${m.id}" data-chat="${chatID}" ${m.sample?'disabled':''}>${icon(playingID===m.audioID?'pause':'play')}<span>▂ ▅ ▃ ▆ ▄ ▂</span> ${time(m.duration)} ${m.sample?'<small>sample</small>':''}</button>`:`<p>${escapeHTML(m.text)}</p>`}<div class="timestamp">${new Date(m.date).toLocaleTimeString([],{hour:'numeric',minute:'2-digit'})}</div></article>`}
function chat(){const c=current();return `${back('Chats')}<div class="chat-avatar">${avatar()}<span>Cal</span></div><div class="chat-note">Demo conversation · saved on this device</div>${c.messages.map(m=>bubble(m,c.id)).join('')}${pending.has(c.id)?'<div class="thinking">Cal is thinking…</div>':''}<form class="composer-bar" id="message-form"><input id="message-input" placeholder="Message" aria-label="Message Cal" autocomplete="off"><button class="circle-btn" type="submit" aria-label="Send message">${icon('up')}</button><button class="circle-btn" type="button" data-action="record" aria-label="Record a voice note">${icon('mic')}</button></form>`}
function card(title,text,symbol){return `<div class="detail-card"><span class="icon">${icon(symbol)}</span><h2>${title}</h2><p>${text}</p></div>`}
function sectionView(){let content='';
 if(section==='Feed')content=card('A little room for you','Your watch is a place for quick thoughts, small check-ins, and picking up a conversation with Cal.','sparkle')+watchButton('Check in with Cal','feed-chat','chat','secondary');
 if(section==='Ideas')content=card('Take the scenic route','Notice three things you usually walk right past. A color, a sound, a tiny detail. What catches your eye?','sun')+watchButton('Explore with Cal','idea-chat','arrow','secondary');
 if(section==='Goals')content=`<p class="list-intro">${state.goals.filter(g=>g.complete).length} of ${state.goals.length} little steps</p>`+state.goals.map((g,i)=>`<button class="row ${g.complete?'completed':''}" data-action="goal" data-value="${i}" aria-label="${escapeHTML(g.title)}, ${g.complete?'completed':'incomplete'}"><span class="goal-check">${g.complete?'✓':''}</span><div><strong>${escapeHTML(g.title)}</strong><small>${escapeHTML(g.detail)}</small></div></button>`).join('');
 if(section==='Library'){const saved=state.chats.flatMap(c=>c.messages.filter(m=>m.saved).map(m=>bubble(m,c.id)));content=saved.length?saved.join(''):card('Keep a little something','Tap the bookmark beside any message in a chat. You’ll find your saved moments here.','bookmark')}
 return back('Your Muse')+`<div class="demo-tag" style="margin-bottom:12px">LOCAL PROTOTYPE</div>`+content;
}
function recordingView(){
 if(route==='sent')return `<div class="record">${avatar()}<div class="success-mark">✓</div><h2>Saved in chat.</h2><p>Your demo reply is ready.</p>${watchButton('Read reply','read-reply','chat')}<p class="demo-tag">Audio stays on this device.</p></div>`;
 const d=state.draft;
 if(d)return `${back('Cancel')}<div class="record">${avatar()}<h2>Ready when you are.</h2><p>${d.sample?'Sample voice note · no microphone used':escapeHTML('Voice note for '+(state.chats.find(c=>c.id===d.chatID)?.title||'Cal'))}</p><div class="waveform static-wave">${'<i></i>'.repeat(19)}</div><div class="timer">${time(d.duration)}</div>${d.sample?'':watchButton(playingID===d.id?'Pause preview':'Preview voice note','play-draft',playingID===d.id?'pause':'play','secondary')}${watchButton('Send voice note','send-voice','up')}<button class="watch-btn ghost" data-action="discard">Discard</button><p class="demo-tag">Demo · nothing is uploaded</p></div>`;
 return `${!recording&&!requesting?back('Cancel'):''}<div class="record">${avatar()}<h2>${recording?'I’m listening.':requesting?'One moment…':'What’s on your mind?'}</h2>${recording?`<div class="waveform">${'<i></i>'.repeat(19)}</div><div class="timer" id="record-timer">0:00</div>`:'<p>A thought, an idea, anything.</p>'}${error?`<div role="alert" class="error">${escapeHTML(error)}</div>`:''}${recording?watchButton('Stop recording','stop','stop'):watchButton(requesting?'Requesting microphone…':'Start recording','start','mic')}${!recording&&!requesting?'<button class="sample-link" data-action="sample">Try a sample voice note</button>':''}<p class="demo-tag">${recording?'Up to 60 seconds. Review before sending.':'Demo · audio stays on this device'}</p></div>`;
}
function render(){
 heading.textContent=route==='chat'?current().title:route==='section'?section:route==='record'?'Voice note':route==='sent'?'Sent':['muse','Chats','Your Muse'][page];
 document.querySelectorAll('.preview-controls button').forEach((b,i)=>{b.classList.toggle('active',page===i);b.setAttribute('aria-pressed',String(page===i))});
 document.querySelector('.watch-dots').innerHTML=[0,1,2].map(i=>`<button class="${page===i?'active':''}" data-page="${i}" aria-label="${['Your Muse','Chats','Sections'][i]}"></button>`).join('');
 screen.innerHTML=route==='chat'?chat():route==='section'?sectionView():route==='record'||route==='sent'?recordingView():[home,chats,sections][page]();
 const details=[['sparkle','Your familiar face.','A little hello from Cal, right on your wrist.'],['chat','Pick up the conversation.','Your thoughts and Cal’s replies, always within reach.'],['goals','Small steps. Your pace.','Feed, ideas, goals, and the things worth keeping.']][page];
 document.querySelector('#feature-icon').innerHTML=icon(details[0]);document.querySelector('#feature-title').textContent=details[1];document.querySelector('#feature-description').textContent=details[2];
 document.querySelector('.native-link>span:first-child').textContent=`0${page+1} — 03`;
 if(requesting)screen.querySelector('[data-action="start"]')?.setAttribute('disabled','');
 if(error&&route!=='record')screen.insertAdjacentHTML('afterbegin',`<div class="error" role="alert">${escapeHTML(error)}</div>`);
}
function openChat(id){stopPlayback();activeChat=id;page=1;route='chat';error='';render();screen.scrollTop=screen.scrollHeight}
function openRecord(){returnChat=route==='chat';if(!returnChat)activeChat='cal';route='record';error='';render();screen.scrollTop=0}
async function startRecording(){
 if(requesting||recording)return;requesting=true;error='';render();
 try{
  if(!navigator.mediaDevices?.getUserMedia||!window.MediaRecorder)throw new Error('unsupported');
  stream=await navigator.mediaDevices.getUserMedia({audio:true});
  const options=MediaRecorder.isTypeSupported('audio/webm;codecs=opus')?{mimeType:'audio/webm;codecs=opus'}:{};
  mediaRecorder=new MediaRecorder(stream,options);chunks=[];
  mediaRecorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data)};
  mediaRecorder.onstop=async()=>{
   clearInterval(timer);recording=false;stream?.getTracks().forEach(t=>t.stop());
   const duration=Math.min(60,(Date.now()-startTime)/1000);
   if(duration<.3){error='That was a little short. Try recording for a moment.';render();return}
   const id=uid(),blob=new Blob(chunks,{type:mediaRecorder.mimeType});
   try{await clip('put',id,blob);state.draft={id,duration,chatID:activeChat,sample:false};persist()}catch{error='Couldn’t save your recording on this device. Please try again.'}
   render();screen.scrollTop=0;
  };
  mediaRecorder.onerror=()=>{error='Recording was interrupted. Please try again.';stopRecording()};
  startTime=Date.now();mediaRecorder.start();recording=true;requesting=false;render();
  timer=setInterval(()=>{const seconds=(Date.now()-startTime)/1000;const el=document.querySelector('#record-timer');if(el)el.textContent=time(seconds);if(seconds>=60)stopRecording()},100);
 }catch(e){requesting=false;recording=false;stream?.getTracks().forEach(t=>t.stop());error=e.name==='NotAllowedError'?'Microphone access is off. Allow it in your browser’s site settings, or try a sample voice note.':e.message==='unsupported'?'Recording isn’t supported in this browser. Try a sample voice note, or use Chrome.':'Couldn’t open the microphone. Check that a microphone is connected and try again.';render()}
}
function stopRecording(){if(mediaRecorder?.state==='recording')mediaRecorder.stop()}
function stopPlayback(){if(audio){audio.pause();URL.revokeObjectURL(audio.src);audio=null}playingID=null}
async function playClip(id){
 if(playingID===id){stopPlayback();render();return}stopPlayback();
 try{const blob=await clip('get',id);if(!blob)throw Error();audio=new Audio(URL.createObjectURL(blob));audio.onended=()=>{stopPlayback();render()};await audio.play();playingID=id;render()}
 catch{error='This recording couldn’t be played. Please try again.';render()}
}
async function reply(chatID,text){
 pending.add(chatID);if(route==='chat')render();
 await new Promise(r=>setTimeout(r,900));
 state.chats.find(c=>c.id===chatID).messages.push(message('muse',text));pending.delete(chatID);persist();
 if(route==='chat'&&activeChat===chatID){render();screen.scrollTop=screen.scrollHeight}
}
async function sendVoice(){
 if(!state.draft)return;stopPlayback();const d=state.draft;activeChat=d.chatID;
 if(!d.sample&&!await clip('get',d.id)){error='This recording is unavailable. Please discard it and record again.';render();return}
 current().messages.push(message('user','Voice message',{audioID:d.id,duration:d.duration,sample:d.sample}));state.draft=null;persist();route='sent';render();
 await reply(d.chatID,d.sample?'I received your sample voice note. This is a demo reply — try recording a thought of your own next.':`I received your ${time(d.duration)} voice note in this demo. You can replay it here. Live transcription and Muse replies need a connected Muse bridge.`);
}
async function sendText(text){const c=current();if(!text.trim()||pending.has(c.id))return;c.messages.push(message('user',text.trim()));persist();render();screen.scrollTop=screen.scrollHeight;const response=/idea/i.test(text)?'Try a small photo walk: notice three things you usually pass by. Save your favorite here. A little curiosity goes a long way.':/goal/i.test(text)?`You have ${state.goals.filter(g=>!g.complete).length} small goals open in this demo. Pick the easiest one to start. Ten minutes is plenty.`:'I’m here. Take a breath and tell me what’s on your mind. We can work through it one small step at a time.';await reply(c.id,response)}
document.addEventListener('click',async e=>{
 const pageButton=e.target.closest('[data-page]');if(pageButton){goPage(Number(pageButton.dataset.page));return}
 const b=e.target.closest('[data-action]');if(!b)return;const a=b.dataset.action,v=b.dataset.value;
 if(a==='hello'){greeting=!greeting;render()}
 if(a==='chat')openChat(v);
 if(a==='record')openRecord();
 if(a==='back'){stopPlayback();error='';if(route==='record'&&returnChat)openChat(activeChat);else{route=null;render()}}
 if(a==='section'){section=v;route='section';error='';render();screen.scrollTop=0}
 if(a==='goal'){state.goals[Number(v)].complete=!state.goals[Number(v)].complete;persist();render()}
 if(a==='feed-chat')openChat('cal');if(a==='idea-chat')openChat('inspiration');
 if(a==='save'){const c=state.chats.find(c=>c.id===b.dataset.chat);const m=c.messages.find(m=>m.id===v);m.saved=!m.saved;persist();const scroll=screen.scrollTop;render();screen.scrollTop=scroll}
 if(a==='start')await startRecording();if(a==='stop')stopRecording();
 if(a==='sample'){state.draft={id:uid(),duration:8,chatID:activeChat,sample:true};persist();render()}
 if(a==='discard'){stopPlayback();const d=state.draft;if(d&&!d.sample)await clip('delete',d.id);state.draft=null;persist();error='';render()}
 if(a==='play-draft')await playClip(state.draft.id);
 if(a==='send-voice')await sendVoice();
 if(a==='read-reply')openChat(activeChat);
 if(a==='play-message'){const m=state.chats.find(c=>c.id===b.dataset.chat).messages.find(m=>m.id===v);if(!m.sample)await playClip(m.audioID)}
});
screen.addEventListener('submit',e=>{e.preventDefault();sendText(screen.querySelector('#message-input').value)});
window.addEventListener('pagehide',()=>{stopRecording();stopPlayback();stream?.getTracks().forEach(t=>t.stop())});
document.addEventListener('visibilitychange',()=>{if(document.hidden){stopRecording();stopPlayback()}});
let touchX=null;screen.addEventListener('touchstart',e=>{touchX=e.changedTouches[0].clientX},{passive:true});screen.addEventListener('touchend',e=>{if(touchX===null)return;const delta=e.changedTouches[0].clientX-touchX;touchX=null;if(Math.abs(delta)>65&&!route)goPage(Math.max(0,Math.min(2,page+(delta<0?1:-1))))},{passive:true});
document.querySelector('#about-button').onclick=()=>document.querySelector('#about').showModal();document.querySelector('#close-about').onclick=()=>document.querySelector('#about').close();document.querySelector('.wordmark').onclick=e=>{e.preventDefault();goPage(0)};
render();
