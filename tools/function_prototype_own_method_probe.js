var checks=0;
function check(v){if(!v)throw new Error("function prototype own method check "+checks);checks++;}
var call=Object.getOwnPropertyDescriptor(Function.prototype,"call").value;
var apply=Object.getOwnPropertyDescriptor(Function.prototype,"apply").value;
var bind=Object.getOwnPropertyDescriptor(Function.prototype,"bind").value;
for(var key of ["call","apply","bind"]){
  for(var kind of ["data","accessor","wrapper"]){
    var receiver={n:3}, touched=0;
    var target=function(x){return this.n+x;};
    if(kind==="accessor")Object.defineProperty(target,key,{configurable:true,get:function(){touched++;throw 17;}});
    else target[key]=kind==="data"?0:function(){return 99;};
    check(Reflect.apply(call,target,[receiver,4])===7);
    check(Reflect.apply(apply,target,[receiver,{0:4,length:1}])===7);
    check(Reflect.apply(bind,target,[receiver,4])()===7);
    check(touched===0);
  }
}
var error={},throwing=function(){throw error;};throwing.call=0;
try{Reflect.apply(call,throwing,[]);check(false);}catch(e){check(e===error);}
var side=[];var list={get length(){side.push("length");return 1;},get 0(){side.push("zero");return 4;}};
function listTarget(x){side.push("target");return this.n+x;}listTarget.apply=0;
check(Reflect.apply(apply,listTarget,[{n:3},list])===7);check(side.join(",")==="length,zero,target");
var proxy=new Proxy(listTarget,{apply:function(t,receiver,args){return receiver.n+args[0]+10;},getOwnPropertyDescriptor:function(){throw 41;}});
check(Reflect.apply(call,proxy,[{n:3},4])===17);
return checks;
