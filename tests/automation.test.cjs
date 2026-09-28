const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname,'../src/Planner.Windows/Assets/automation.js'),'utf8');
const cases = require('./automation-cases.json');
const fixture = `
var config={name:'Test Participant',auto:true,end:Date.now()+90000,token:'test'};
var clicked=[],messages=[];
var window={chrome:{webview:{postMessage:m=>messages.push(m)}}}; window.top=window;
var navigator={mediaDevices:{}};
var location={hostname:'telemost.360.yandex.ru',protocol:'https:',pathname:'/j/123'};
function setInterval(){}
function Event(type){this.type=type;}
class HTMLInputElement {
 constructor(v){this._value=v;this.tagName='INPUT';this.type='text';this.offsetWidth=10;this.labels=[];}
 get value(){return this._value;} set value(v){this._value=v;}
 getAttribute(){return '';}
 focus(){} blur(){} dispatchEvent(){}
}
function button(text){return {innerText:text,offsetWidth:10,getAttribute:()=>'',click:()=>clicked.push(text)};}
var controls=[],fields=[];
var document={body:{innerText:''},querySelectorAll:q=>q.startsWith('button')?controls:fields,getElementById:()=>null,addEventListener:()=>{}};
`;
for(const [name,setup,check] of cases){
 const c=vm.createContext({DOMException});vm.runInContext(fixture+script+'\n'+setup+'\nvar result=step();',c);
 assert.equal(vm.runInContext(check,c),true,name);console.log('PASS: '+name);
}
(async()=>{
 const c=vm.createContext({DOMException});vm.runInContext(fixture+script,c);
 await assert.rejects(vm.runInContext('navigator.mediaDevices.getUserMedia({audio:true})',c),{name:'NotAllowedError'});
 await assert.rejects(vm.runInContext('navigator.mediaDevices.getDisplayMedia({video:true})',c),{name:'NotAllowedError'});
 vm.runInContext("config.end=Date.now()-1;controls=[button('Подключиться')];fields=[new HTMLInputElement('Test Participant')];advance();",c);
 assert.equal(vm.runInContext('clicked.length',c),0,'no actions after end');
 vm.runInContext("config.end=Date.now()+90000;config.auto=false;advance();",c);
 assert.equal(vm.runInContext('clicked.length',c),0,'preview does not join');
 vm.runInContext("config.auto=true;location.hostname='evil.test';advance();",c);
 assert.equal(vm.runInContext('clicked.length',c),0,'foreign origin rejected');
 console.log('PASS: capture denied, expired task, preview, foreign origin');
})().catch(e=>{console.error(e);process.exitCode=1;});
