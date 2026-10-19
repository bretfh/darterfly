/* Public upstream JavaScriptCore C API in an isolated native world. */
#include <JavaScriptCore/JavaScript.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <sys/ucontext.h>
#include <unistd.h>

static int evaluate(JSGlobalContextRef ctx, const char *source, double expected)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef value = JSEvaluateScript(ctx, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    if (exception) {
        JSStringRef message = JSValueToStringCopy(ctx, exception, NULL);
        char text[512];
        JSStringGetUTF8CString(message, text, sizeof text);
        JSStringRelease(message);
        fprintf(stderr, "JSC exception: %s\n", text);
        return 0;
    }
    return value && JSValueToNumber(ctx, value, NULL) == expected;
}
static void *worker(void *unused)
{
    (void)unused;
    JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
    if (!ctx) return (void *)1;
    int ok = evaluate(ctx,
        "let sum=0; for(let i=0;i<2000;i++){"
        "let x={name:'darterfly'+i,values:[i,i+1]};sum+=x.values[0];}sum",
        1999000);
    JSGarbageCollect(ctx);
    JSGlobalContextRelease(ctx);
    return (void *)(long)!ok;
}
static void fault(int sig, siginfo_t *info, void *context)
{
    (void)info;
    ucontext_t *uc = context;
    dprintf(2, "JSC fault signal=%d rip=%lx trap=%lu rax=%lx rcx=%lx rdx=%lx\n",
            sig, uc->uc_mcontext.rip, uc->uc_mcontext.trapno,
            uc->uc_mcontext.rax, uc->uc_mcontext.rcx, uc->uc_mcontext.rdx);
    _exit(128+sig);
}
int main(void)
{
    struct sigaction action = {0};
    action.sa_sigaction = fault;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGFPE, &action, NULL);
    puts("JSC upstream native world: initialize");
    JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
    if (!ctx) return 1;
    if (!evaluate(ctx, "6*7", 42)) return 2;
    puts("JSC arithmetic PASS");
    if (!evaluate(ctx,
        "(()=>{const a=Array.from({length:10000},(_,i)=>({n:i,s:'darter'+i}));"
        "return a.reduce((n,x)=>n+x.n,0)})()", 49995000)) return 3;
    if (!evaluate(ctx,
        "(()=>{let a=new Uint32Array([1,2,3]);let m=new Map([[1,40]]);"
        "return m.get(1)+a[1]})()", 42)) return 4;
    if (!evaluate(ctx,
        "Number('e\\u0301'.normalize('NFC')==='\\u00e9' && "
        "new Intl.Collator('en').compare('a','z')<0 && "
        "/^darter[a-z]+$/.test('darterfly'))", 1)) return 5;
    puts("JSC objects typed-arrays regex ICU PASS");
    pthread_t threads[2];
    for (int i=0;i<2;i++) if (pthread_create(&threads[i],NULL,worker,NULL)) return 6;
    for (int i=0;i<30;i++) {
        if (!evaluate(ctx,"Array.from({length:1000},(_,i)=>({i})).length",1000)) return 7;
        JSGarbageCollect(ctx);
    }
    for (int i=0;i<2;i++) {
        void *result;
        if (pthread_join(threads[i],&result) || result) return 8;
    }
    JSGlobalContextRelease(ctx);
    puts("JSC PASS interpreter objects ICU threads collection");
    return 0;
}
