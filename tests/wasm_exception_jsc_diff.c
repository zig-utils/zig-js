#include <JavaScriptCore/JavaScript.h>

#include <stdio.h>
#include <stdlib.h>

static int evaluate_and_print(JSGlobalContextRef context, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    if (exception || !result)
        return 1;
    JSStringRef text = JSValueToStringCopy(context, result, &exception);
    if (exception || !text)
        return 1;
    size_t capacity = JSStringGetMaximumUTF8CStringSize(text);
    char* bytes = malloc(capacity);
    if (!bytes) {
        JSStringRelease(text);
        return 1;
    }
    JSStringGetUTF8CString(text, bytes, capacity);
    fputs(bytes, stdout);
    fputc('\n', stdout);
    free(bytes);
    JSStringRelease(text);
    return 0;
}

int main(void)
{
    static const char source[] =
        "(()=>{"
        "const rows=[];const errorName=f=>{try{f();return 'none'}catch(e){return e.name}};"
        "rows.push('surface:'+[typeof WebAssembly.Tag,typeof WebAssembly.Exception,typeof WebAssembly.JSTag].join(','));"
        "rows.push('functions:'+[WebAssembly.Tag.name,WebAssembly.Tag.length,WebAssembly.Tag.prototype.type.name,WebAssembly.Tag.prototype.type.length,WebAssembly.Exception.name,WebAssembly.Exception.length,WebAssembly.Exception.prototype.getArg.length,WebAssembly.Exception.prototype.is.length].join(','));"
        "rows.push('prototype:'+[Object.getPrototypeOf(WebAssembly.Tag.prototype)===Object.prototype,Object.getPrototypeOf(WebAssembly.Exception.prototype)===Object.prototype].join(','));"
        "const tag=new WebAssembly.Tag({parameters:['i32','externref']});const other=new WebAssembly.Tag({parameters:['i32','externref']});const marker={value:291};"
        "rows.push('tag:'+[Object.prototype.toString.call(tag),tag.type().parameters.join(','),tag!==other].join('|'));"
        "const exception=new WebAssembly.Exception(tag,[4294967295,marker],{traceStack:true});"
        "rows.push('exception:'+[Object.prototype.toString.call(exception),exception instanceof WebAssembly.Exception,exception instanceof Error,exception.is(tag),exception.is(other),exception.getArg(tag,0),exception.getArg(tag,1)===marker,typeof exception.stack].join(','));"
        "rows.push('errors:'+[errorName(()=>WebAssembly.Tag({parameters:[]})),errorName(()=>new WebAssembly.Tag()),errorName(()=>WebAssembly.Exception(tag,[])),errorName(()=>exception.getArg(other,0)),errorName(()=>exception.getArg(tag,2)),errorName(()=>new WebAssembly.Exception(WebAssembly.JSTag,[{}]))].join(','));"
        "const jt=Object.getOwnPropertyDescriptor(WebAssembly,'JSTag');const tt=Object.getOwnPropertyDescriptor(WebAssembly.Tag.prototype,'type');const ga=Object.getOwnPropertyDescriptor(WebAssembly.Exception.prototype,'getArg');const is=Object.getOwnPropertyDescriptor(WebAssembly.Exception.prototype,'is');"
        "rows.push('reflection:'+[typeof jt.get,typeof jt.set,jt.enumerable,jt.configurable,tt.writable,tt.enumerable,tt.configurable,ga.enumerable,is.enumerable].join(','));"
        "rows.push('jstag:'+[WebAssembly.JSTag===WebAssembly.JSTag,Object.prototype.toString.call(WebAssembly.JSTag),WebAssembly.JSTag.type().parameters.join(',')].join('|'));"
        "let order=[],step=0;const values={[Symbol.iterator](){order.push('iterator');return{next(){order.push('next');if(step++===0)return{value:{toString(){order.push('convert');return'i32'}},done:false};return{value:'bad',done:false}},return(){order.push('return');return{}}}}};"
        "try{new WebAssembly.Tag({get parameters(){order.push('parameters');return values}})}catch(_){}rows.push('order:'+order.join(','));"
        "class DerivedTag extends WebAssembly.Tag{}class DerivedException extends WebAssembly.Exception{}const derivedTag=new DerivedTag({parameters:[]});const derivedException=new DerivedException(derivedTag,[]);"
        "rows.push('derived:'+[derivedTag instanceof DerivedTag,derivedException instanceof DerivedException].join(','));"
        "return rows.join('\\n')"
        "})()";
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    int failed = evaluate_and_print(context, source);
    JSGlobalContextRelease(context);
    return failed;
}
