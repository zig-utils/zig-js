#include "c_api_reentrant_support.h"

int main(void)
{
    const struct {
        const char* source;
        const char* completion;
        const char* after;
        const char* checkpoint;
    } cases[] = {
        {
            "var trace=[];Promise.resolve().then(()=>trace.push('job'));trace.push('before');"
            "hostScript(\"trace.push('nested')\");trace.push('after');trace.join(',')",
            "before,nested,after", "trace.join(',')", "before,nested,after,job"
        },
        {
            "var trace=[],token={};Promise.resolve().then(()=>trace.push('outer-job'));"
            "try{hostScript(\"trace.push('inner');Promise.resolve().then(()=>trace.push('inner-job'));throw token\")}"
            "catch(error){if(error!==token)throw Error('throw identity');trace.push('caught')}"
            "trace.push('after');trace.join(',')",
            "inner,caught,after", "trace.join(',')", "inner,caught,after,outer-job,inner-job"
        },
        {
            "var trace=[];Promise.resolve().then(()=>trace.push('job0'));"
            "hostScript(\"trace.push('one');hostScript(\\\"trace.push('two');Promise.resolve().then(()=>trace.push('job2'))\\\");trace.push('one-end')\");"
            "trace.push('outer-end');trace.join(',')",
            "one,two,one-end,outer-end", "trace.join(',')", "one,two,one-end,outer-end,job0,job2"
        },
        {
            "var trace=[];Promise.resolve().then(()=>{trace.push('reaction-start');"
            "hostScript(\"trace.push('inner');Promise.resolve().then(()=>trace.push('inner-job'))\");trace.push('reaction-end')});"
            "Promise.resolve().then(()=>trace.push('peer'));'scheduled'",
            "scheduled", "trace.join(',')", "reaction-start,inner,reaction-end,peer,inner-job"
        },
        {
            "var seen=(function(){let callerOnly=1;return hostScript(\"let scriptLexical=12;var scriptGlobal=4;typeof callerOnly\")})();"
            "seen+':'+hostScript('scriptLexical+scriptGlobal')",
            "undefined:16", "hostScript('scriptLexical')", "12"
        },
        {
            "var untouched=0,syntax=false;try{hostScript('untouched=1;let = ;')}catch(error){syntax=error.name==='SyntaxError'}"
            "String(untouched)+':'+syntax",
            "0:true", "hostScript('2+5')", "7"
        },
    };
    unsigned passed = 0;
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        JSGlobalContextRef context = JSGlobalContextCreate(NULL);
        if (!context || !install_script(context, "hostScript", host_script)) return 1;
        int completion = expect_script(context, cases[index].source, cases[index].completion);
        int checkpoint = expect_script(context, cases[index].after, cases[index].checkpoint);
        if (completion && checkpoint) ++passed;
        JSGlobalContextRelease(context);
    }
    printf("reentrant Script public boundary: %u/6 cases passed\n", passed);
    return passed == 6 ? 0 : 1;
}
