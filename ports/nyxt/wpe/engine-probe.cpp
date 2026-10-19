/* First page proof: upstream WPE WebKit, its real processes and CPU pixels.
 * This offscreen harness is not the Nyxt UI or Darterfly window adapter. */
#include <wtf/MainThread.h>
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <utility>
#include <initializer_list>
#include <cerrno>
extern "C" void darter_register_openssl(void);

typedef struct { WPEDisplay parent; } DarterPageDisplay;
typedef struct { WPEDisplayClass parent; } DarterPageDisplayClass;
G_DEFINE_TYPE(DarterPageDisplay, darter_page_display, WPE_TYPE_DISPLAY)
static void darter_page_display_init(DarterPageDisplay *) { }
static void darter_page_display_class_init(DarterPageDisplayClass *klass) {
    auto *display=WPE_DISPLAY_CLASS(klass);
    display->connect=[](WPEDisplay *,GError **) -> gboolean { return TRUE; };
    display->create_view=[](WPEDisplay *d) -> WPEView * {
        return WPE_VIEW(g_object_new(WPE_TYPE_VIEW_HEADLESS,"display",d,nullptr));
    };
    display->create_toplevel=[](WPEDisplay *d,guint) -> WPEToplevel * {
        return WPE_TOPLEVEL(g_object_new(WPE_TYPE_TOPLEVEL_HEADLESS,"display",d,nullptr));
    };
}
static void check(const char *name,bool ok) {
    printf("ENGINE %s %s\n",ok?"PASS":"FAIL",name);fflush(stdout);
    if(!ok)exit(1);
}
static bool javascriptDone,pixelsDone,finished,tlsRejected;
static GTlsCertificateFlags expectedTlsErrors;
static char expectedTlsURI[96];
static unsigned frames;
static void frame(WPEView *,WPEBuffer *buffer,gpointer) {
    ++frames;
    if(!WPE_IS_BUFFER_SHM(buffer)) return;
    auto *shm=WPE_BUFFER_SHM(buffer);
    if(wpe_buffer_get_width(buffer)!=128 || wpe_buffer_get_height(buffer)!=96) return;
    gsize size=0;
    auto *bytes=static_cast<const unsigned char *>(g_bytes_get_data(wpe_buffer_shm_get_data(shm),&size));
    size_t stride=wpe_buffer_shm_get_stride(shm);
    if(stride<128*4 || size<stride*96) return;
    uint32_t background=0,box=0;
    memcpy(&background,bytes+4*stride+4*4,4);
    memcpy(&box,bytes+24*stride+24*4,4);
    if(background==0xff203040u && box==0xffef7d27u) pixelsDone=true;
}
static void loaded(WebKitWebView *view,WebKitLoadEvent event,gpointer) {
    printf("ENGINE load-event=%d uri=%s\n",event,webkit_web_view_get_uri(view) ? webkit_web_view_get_uri(view) : "(null)");fflush(stdout);
    if(event!=WEBKIT_LOAD_FINISHED || finished || expectedTlsErrors)return;
    finished=true;
    printf("ENGINE load-finished uri=%s title=%s\n",
        webkit_web_view_get_uri(view) ? webkit_web_view_get_uri(view) : "(null)",
        webkit_web_view_get_title(view) ? webkit_web_view_get_title(view) : "(null)");
    fflush(stdout);
    webkit_web_view_evaluate_javascript(view,
        "document.querySelector('#box').dataset.answer === '42' && "
        "getComputedStyle(document.querySelector('#box')).backgroundColor === 'rgb(239, 125, 39)'",
        -1,nullptr,nullptr,nullptr,
        +[](GObject *source,GAsyncResult *result,gpointer) {
            GError *error=nullptr;
            JSCValue *value=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(source),result,&error);
            if(error)fprintf(stderr,"ENGINE JavaScript: %s\n",error->message);
            check("javascript-dom",value && !error && jsc_value_to_boolean(value));
            g_clear_object(&value);g_clear_error(&error);javascriptDone=true;
        },nullptr);
}
static void stdioLines() {
    const char *path="/tmp/engine-lines";
    const char data[]="abc\ndefghijkl\nlast";
    FILE *file=fopen(path,"w+");check("stdio-open",file);
    check("stdio-write",fwrite(data,1,sizeof(data)-1,file)==sizeof(data)-1);
    rewind(file);char line[64]{};
    check("stdio-first-line",fgets(line,sizeof line,file) && !strcmp(line,"abc\n") && ftell(file)==4);
    check("stdio-next-byte",fgetc(file)=='d' && ungetc('X',file)=='X');
    check("stdio-pushback",fgets(line,4,file) && !strcmp(line,"Xef") && ftell(file)==7);
    check("stdio-short-line",fgets(line,4,file) && !strcmp(line,"ghi") && ftell(file)==10);
    check("stdio-seek-back",fseek(file,-6,SEEK_CUR)==0 && fgetc(file)=='d');
    check("stdio-next-line",fgets(line,sizeof line,file) && !strcmp(line,"efghijkl\n") && ftell(file)==14);
    check("stdio-last-line",fgets(line,sizeof line,file) && !strcmp(line,"last") && feof(file));
    check("stdio-eof",!fgets(line,sizeof line,file) && feof(file) && !ferror(file));
    rewind(file);check("stdio-rewind",!feof(file) && fgets(line,sizeof line,file) && !strcmp(line,"abc\n"));
    fclose(file);unlink(path);
    int ends[2];check("stdio-pipe",pipe(ends)==0 && write(ends[1],"a\nb\n",4)==4);
    close(ends[1]);file=fdopen(ends[0],"r");check("stdio-fdopen",file);
    errno=0;check("stdio-pipe-first",fgets(line,sizeof line,file) && !strcmp(line,"a\n") && errno==0);
    check("stdio-pipe-second",fgets(line,sizeof line,file) && !strcmp(line,"b\n"));
    check("stdio-pipe-eof",!fgets(line,sizeof line,file) && feof(file) && !ferror(file));
    fclose(file);
}
int main() {
    stdioLines();
    WTF::initializeMainThread();
    darter_register_openssl();
    WebKitWebContext *context=webkit_web_context_new();
    webkit_web_context_set_cache_model(context,WEBKIT_CACHE_MODEL_DOCUMENT_VIEWER);
    WebKitNetworkSession *session=webkit_network_session_new_ephemeral();
    check("ephemeral-session",webkit_network_session_is_ephemeral(session));
    WPEDisplay *display=WPE_DISPLAY(g_object_new(darter_page_display_get_type(),nullptr));
    GError *error=nullptr;
    check("display",wpe_display_connect(display,&error) && !error);
    WebKitWebView *web=WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
        "web-context",context,"network-session",session,"display",display,nullptr));
    WPEView *view=webkit_web_view_get_wpe_view(web);
    WPEToplevel *top=wpe_display_create_toplevel(display,1);
    check("web-view",web && view && top);
    wpe_toplevel_resize(top,128,96);wpe_view_set_toplevel(view,top);wpe_view_focus_in(view);
    g_signal_connect(view,"buffer-rendered",G_CALLBACK(frame),nullptr);
    g_signal_connect(web,"load-changed",G_CALLBACK(loaded),nullptr);
    g_signal_connect(web,"load-failed",G_CALLBACK(+[](WebKitWebView *,WebKitLoadEvent,const char *uri,GError *e,gpointer) -> gboolean {
        if(g_error_matches(e,WEBKIT_NETWORK_ERROR,WEBKIT_NETWORK_ERROR_CANCELLED) ||
           g_error_matches(e,G_IO_ERROR,G_IO_ERROR_CANCELLED)) {
            printf("ENGINE navigation-cancelled %s\n",uri);return TRUE;
        }
        fprintf(stderr,"ENGINE load failed %s: %s\n",uri,e->message);exit(2);
    }),nullptr);
    g_signal_connect(web,"web-process-terminated",G_CALLBACK(+[](WebKitWebView *,WebKitWebProcessTerminationReason reason,gpointer) {
        fprintf(stderr,"ENGINE WebProcess terminated: %d\n",reason);exit(3);
    }),nullptr);
    webkit_web_view_load_html(web,
        "<!doctype html><meta charset=utf-8><title>Loading</title>"
        "<style>html,body{margin:0;background:#203040;overflow:hidden}"
        "#box{position:absolute;left:16px;top:16px;width:64px;height:32px}</style>"
        "<div id=box></div><script>const box=document.querySelector('#box');"
        "box.dataset.answer=String(6*7);box.style.backgroundColor='#ef7d27';"
        "document.title='Darterfly '+box.dataset.answer;</script>","about:blank");
    auto waitPage=[&] {
        auto deadline=g_get_monotonic_time()+60000000;
        while(!(javascriptDone && pixelsDone && webkit_web_view_get_title(web) &&
                !strcmp(webkit_web_view_get_title(web),"Darterfly 42")) &&
              g_get_monotonic_time()<deadline) {
            while(g_main_context_iteration(nullptr,FALSE)) { }
            usleep(1000);
        }
        printf("ENGINE frames=%u\n",frames);
        check("load-finished",finished);
        const char *title=webkit_web_view_get_title(web);
        check("document-title",title && !strcmp(title,"Darterfly 42"));
        check("javascript-completed",javascriptDone);
        check("html-css-js-pixels",pixelsDone);
    };
    waitPage();
    check("local-page",true);
    check("tls-policy-fail",webkit_network_session_get_tls_errors_policy(session)==WEBKIT_TLS_ERRORS_POLICY_FAIL);
    g_signal_connect(web,"load-failed-with-tls-errors",G_CALLBACK(+[](WebKitWebView *,const char *uri,GTlsCertificate *certificate,GTlsCertificateFlags errors,gpointer) -> gboolean {
        printf("ENGINE TLS rejection uri=%s flags=%u expected=%u\n",uri,errors,expectedTlsErrors);
        check("tls-rejection",expectedTlsErrors && certificate && (errors&expectedTlsErrors) && !strcmp(uri,expectedTlsURI));
        tlsRejected=true;return TRUE;
    }),nullptr);
    auto remotePage=[&](const char *uri) {
        javascriptDone=pixelsDone=finished=false;
        webkit_web_view_load_uri(web,uri);
        waitPage();
        if(strncmp(uri,"https:",6)) { check("http-page",true);return; }
        GTlsCertificate *certificate=nullptr;GTlsCertificateFlags errors{};
        check("https-verified",webkit_web_view_get_tls_info(web,&certificate,&errors) && certificate && !errors);
    };
    remotePage("http://10.0.2.2:18765/page");
    remotePage("https://10.0.2.2:18766/page");
    remotePage("https://10.0.2.2:18767/page");
    for(unsigned round=0;round<4;++round)
    for(auto test : {std::pair{18768,G_TLS_CERTIFICATE_EXPIRED},
                     std::pair{18769,G_TLS_CERTIFICATE_NOT_ACTIVATED},
                     std::pair{18770,G_TLS_CERTIFICATE_BAD_IDENTITY},
                     std::pair{18771,G_TLS_CERTIFICATE_UNKNOWN_CA}}) {
        expectedTlsErrors=test.second;tlsRejected=false;
        snprintf(expectedTlsURI,sizeof expectedTlsURI,"https://10.0.2.2:%d/page",test.first);
        webkit_web_view_load_uri(web,expectedTlsURI);
        auto deadline=g_get_monotonic_time()+30000000;
        while((!tlsRejected || webkit_web_view_is_loading(web)) && g_get_monotonic_time()<deadline) {
            while(g_main_context_iteration(nullptr,FALSE)) { }
            usleep(1000);
        }
        check("certificate-rejected",tlsRejected && !webkit_web_view_is_loading(web));
    }
    expectedTlsErrors=static_cast<GTlsCertificateFlags>(0);
    remotePage("https://10.0.2.2:18766/page");
    check("https-recovery",true);
    g_signal_handlers_disconnect_by_data(web,nullptr);
    wpe_view_set_toplevel(view,nullptr);
    g_object_unref(web);g_object_unref(top);g_object_unref(display);
    g_object_unref(session);g_object_unref(context);
    puts("ENGINE PASS COMPLETE");return 0;
}
