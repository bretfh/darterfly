/* Nyxt's WPE transport. Only this process owns GLib/WebKit objects.
 * All children use Darterfly's existing native process and shared libsa ABI. */
#include <wtf/MainThread.h>
#include <wpe/webkit.h>
#include <wpe/wpe-platform.h>
#include <wpe/headless/wpe-headless.h>
#include <xkbcommon/xkbcommon.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <unordered_map>
extern "C" void darter_register_openssl(void);
struct Header { uint32_t op,id,seq,a,b,n; };
static constexpr unsigned limit=16*1024*1024;
static int connection=-1;
static bool running=true;
static bool trace=false;
// World RPC cancellation cannot undo an already consumed stream transfer.
// Defer signals only during short nonblocking I/O, not while waiting for space.
static ssize_t wireIO(bool writing,void* data,size_t size) {
    sigset_t blocked,previous;sigfillset(&blocked);
    int error=pthread_sigmask(SIG_BLOCK,&blocked,&previous);
    if(error){errno=error;return -1;}
    auto n=writing?write(connection,data,size):read(connection,data,size);
    error=errno;pthread_sigmask(SIG_SETMASK,&previous,nullptr);errno=error;return n;
}
static void transfer(const void* data,size_t size) {
    auto p=static_cast<const char*>(data);
    while(size) { auto n=wireIO(true,const_cast<char*>(p),size>32768?32768:size);
        if(n<0 && errno==EINTR)continue;
        if(n<0 && errno==EAGAIN){usleep(1000);continue;}
        if(n<=0){running=false;return;} p+=n;size-=n; }
}
static void send(unsigned op,unsigned id,unsigned seq=0,unsigned a=0,unsigned b=0,
                 const void* bytes=nullptr,size_t size=0) {
    static bool sending=false;
    if(sending){fprintf(stderr,"NYXT REENTRANT SEND op=%u\n",op);abort();}
    sending=true;
    Header h{op,id,seq,a,b,static_cast<uint32_t>(size)};
    if(trace)fprintf(stderr,"NYXT send %u id=%u seq=%u bytes=%zu\n",op,id,seq,size);
    transfer(&h,sizeof h);if(size)transfer(bytes,size);sending=false;
}
static void text(unsigned op,unsigned id,unsigned seq,const char* s) {
    if(!s)s="";send(op,id,seq,0,0,s,strlen(s));
}
typedef struct { WPEDisplay parent; } NyxtDisplay;
typedef struct { WPEDisplayClass parent; } NyxtDisplayClass;
G_DEFINE_TYPE(NyxtDisplay,nyxt_display,WPE_TYPE_DISPLAY)
static void nyxt_display_init(NyxtDisplay*) {}
static void nyxt_display_class_init(NyxtDisplayClass* c) {
    auto d=WPE_DISPLAY_CLASS(c);
    d->connect=[](WPEDisplay*,GError**)->gboolean{return TRUE;};
    d->create_view=[](WPEDisplay*d)->WPEView*{
        return WPE_VIEW(g_object_new(WPE_TYPE_VIEW_HEADLESS,"display",d,nullptr));};
    d->create_toplevel=[](WPEDisplay*d,guint)->WPEToplevel*{
        return WPE_TOPLEVEL(g_object_new(WPE_TYPE_TOPLEVEL_HEADLESS,"display",d,nullptr));};
}
struct Page { unsigned id; WebKitWebView* web; WPEToplevel* top; bool chrome; };
static std::unordered_map<unsigned,Page*> pages;
static std::unordered_map<unsigned,WebKitURISchemeRequest*> requests;
static unsigned nextRequest;
static WPEDisplay* display;
static WebKitWebContext* context;
static WebKitNetworkSession* session;
static void frame(WPEView*,WPEBuffer* buffer,gpointer data) {
    static unsigned count; if(trace && count++<12)fprintf(stderr,"NYXT frame %u\n",count);
    if(!WPE_IS_BUFFER_SHM(buffer))return;
    auto p=static_cast<Page*>(data);auto shm=WPE_BUFFER_SHM(buffer);
    unsigned w=wpe_buffer_get_width(buffer),h=wpe_buffer_get_height(buffer);
    gsize n;auto bytes=static_cast<const char*>(g_bytes_get_data(wpe_buffer_shm_get_data(shm),&n));
    size_t stride=wpe_buffer_shm_get_stride(shm);
    if(!w||!h||w>2048||h>2048||stride<w*4||n<stride*h)return;
    std::vector<char> packed(w*h*4);
    for(unsigned y=0;y<h;++y)memcpy(packed.data()+y*w*4,bytes+y*stride,w*4);
    send(1100,p->id,0,w,h,packed.data(),packed.size());
}
static void destroy(Page* p) {
    g_signal_handlers_disconnect_by_data(p->web,p);
    auto view=webkit_web_view_get_wpe_view(p->web);
    g_signal_handlers_disconnect_by_data(view,p);wpe_view_set_toplevel(view,nullptr);
    g_object_unref(p->web);g_object_unref(p->top);delete p;
}
static Page* create(unsigned id,unsigned w,unsigned h,bool chrome) {
    if(!id||pages.count(id)||!w||!h||w>2048||h>2048)return nullptr;
    WebKitWebView* related=nullptr;
    if(chrome)for(auto pair:pages)if(pair.second->chrome){related=pair.second->web;break;}
    auto web=related?WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,
        "related-view",related,nullptr)):
        WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW,"web-context",context,
        "network-session",session,"display",display,nullptr));
    auto top=wpe_display_create_toplevel(display,1);
    auto p=new Page{id,web,top,chrome};pages[id]=p;
    auto view=webkit_web_view_get_wpe_view(web);
    wpe_toplevel_resize(top,w,h);wpe_view_set_toplevel(view,top);wpe_view_focus_in(view);
    g_signal_connect(view,"buffer-rendered",G_CALLBACK(frame),p);
    g_signal_connect(web,"load-changed",G_CALLBACK(+[](WebKitWebView*v,WebKitLoadEvent e,gpointer d){
        auto p=static_cast<Page*>(d);auto uri=webkit_web_view_get_uri(v);
        if(trace)fprintf(stderr,"NYXT load %u event=%d uri=%s\n",p->id,e,uri?uri:"");
        send(1101,p->id,0,e,0,uri,uri?strlen(uri):0);}),p);
    g_signal_connect(web,"notify::title",G_CALLBACK(+[](GObject*v,GParamSpec*,gpointer d){
        text(1102,static_cast<Page*>(d)->id,0,webkit_web_view_get_title(WEBKIT_WEB_VIEW(v)));}),p);
    g_signal_connect(web,"notify::uri",G_CALLBACK(+[](GObject*v,GParamSpec*,gpointer d){
        text(1103,static_cast<Page*>(d)->id,0,webkit_web_view_get_uri(WEBKIT_WEB_VIEW(v)));}),p);
    g_signal_connect(web,"load-failed-with-tls-errors",G_CALLBACK(+[](WebKitWebView*,const char* uri,GTlsCertificate*,GTlsCertificateFlags flags,gpointer)->gboolean{
        fprintf(stderr,"NYXT TLS rejection uri=%s flags=%u\n",uri,flags);return FALSE;}),p);
    g_signal_connect(web,"load-failed",G_CALLBACK(+[](WebKitWebView*,WebKitLoadEvent,const char*,GError*e,gpointer d)->gboolean{
        if(!g_error_matches(e,WEBKIT_NETWORK_ERROR,WEBKIT_NETWORK_ERROR_CANCELLED))
            text(1105,static_cast<Page*>(d)->id,0,e->message);
        return FALSE;}),p);
    g_signal_connect(web,"web-process-terminated",G_CALLBACK(+[](WebKitWebView*,WebKitWebProcessTerminationReason,gpointer d){
        text(1105,static_cast<Page*>(d)->id,0,"Web process terminated");}),p);
    return p;
}
static void command(Header h,char* data) {
    if(trace)fprintf(stderr,"NYXT command %u id=%u seq=%u bytes=%u\n",h.op,h.id,h.seq,h.n);
    auto p=pages.count(h.id)?pages[h.id]:nullptr;
    if(h.op==1){if(trace)fprintf(stderr,"NYXT create view %u %ux%u\n",h.id,h.a,h.b);if(!create(h.id,h.a,h.b,h.n&&data[0]==1)){text(1001,h.id,h.seq,"Invalid view");return;}}
    else if(h.op==9){running=false;}
    else if(h.op==11){
        // Match upstream Nyxt's WebKit scheme policy. Marking every scheme
        // local prevents the UI from fetching its own Lisp callback URLs.
        auto security=webkit_web_context_get_security_manager(context);
        if(!strcmp(data,"nyxt-resource"))
            webkit_security_manager_register_uri_scheme_as_secure(security,data);
        else if(!strcmp(data,"lisp"))
            webkit_security_manager_register_uri_scheme_as_cors_enabled(security,data);
        else if(!strcmp(data,"view-source"))
            webkit_security_manager_register_uri_scheme_as_no_access(security,data);
        webkit_web_context_register_uri_scheme(context,data,+[](WebKitURISchemeRequest*r,gpointer){
            auto n=++nextRequest;requests[n]=WEBKIT_URI_SCHEME_REQUEST(g_object_ref(r));
            auto web=webkit_uri_scheme_request_get_web_view(r);unsigned id=0;
            for(auto pair:pages)if(pair.second->web==web)id=pair.first;
            text(1104,id,n,webkit_uri_scheme_request_get_uri(r));},nullptr,nullptr);
    } else if(h.op==10) {
        auto it=requests.find(h.seq);if(it==requests.end())return;
        auto split=static_cast<char*>(memchr(data,'\n',h.n));
        if(!split)return;
        *split=0;auto body=split+1;auto size=h.n-(body-data);
        auto stream=g_memory_input_stream_new_from_data(g_memdup2(body,size),size,g_free);
        // Errors are returned as a failed resource, not successful privileged HTML.
        if(h.a>=400){auto e=g_error_new_literal(G_IO_ERROR,G_IO_ERROR_FAILED,body);
            webkit_uri_scheme_request_finish_error(it->second,e);g_error_free(e);}
        else webkit_uri_scheme_request_finish(it->second,stream,size,data);
        g_object_unref(stream);g_object_unref(it->second);requests.erase(it);return;
    } else if(!p){text(1001,h.id,h.seq,"Unknown view");return;}
    else {auto view=webkit_web_view_get_wpe_view(p->web);
        switch(h.op) {
        case 2:webkit_web_view_load_uri(p->web,data);break;
        case 3:webkit_web_view_load_html(p->web,data,"nyxt:blank");break;
        case 4:{auto token=new Header(h);
            std::string script(data,h.n);
            // Fire-and-forget evaluation must not serialize a Promise or DOM
            // object as a result. JavaScript exceptions still reach the caller.
            if(!h.seq)script+="\n;void 0;";
            webkit_web_view_evaluate_javascript(p->web,script.c_str(),script.size(),nullptr,nullptr,nullptr,
                +[](GObject*o,GAsyncResult*r,gpointer d){auto h=static_cast<Header*>(d);GError*e=nullptr;
                    auto v=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(o),r,&e);
                    if(e){text(1001,h->id,h->seq,e->message);g_error_free(e);}
                    else {auto json=v?jsc_value_to_json(v,0):nullptr;text(1000,h->id,h->seq,json?json:"null");g_free(json);}
                    if(v)g_object_unref(v);delete h;},token);return;}
        case 5:if(h.a&&h.b&&h.a<=2048&&h.b<=2048)wpe_toplevel_resize(p->top,h.a,h.b);break;
        case 6:{ // a: evdev code; b: Unicode or XKB keysym. Payload: modifiers.
            unsigned mods=0;if(h.n==4)memcpy(&mods,data,4);
            auto key=h.b>=0xff00?h.b:xkb_utf32_to_keysym(h.b);
            for(auto type:{WPE_EVENT_KEYBOARD_KEY_DOWN,WPE_EVENT_KEYBOARD_KEY_UP}){
                auto e=wpe_event_keyboard_new(type,view,WPE_INPUT_SOURCE_KEYBOARD,
                    g_get_monotonic_time()/1000,static_cast<WPEModifiers>(mods),h.a+8,key);
                wpe_view_event(view,e);wpe_event_unref(e);}break;}
        case 7:{unsigned kind=0;if(h.n==4)memcpy(&kind,data,4);
            auto e=wpe_event_pointer_button_new(kind?WPE_EVENT_POINTER_DOWN:WPE_EVENT_POINTER_UP,
                view,WPE_INPUT_SOURCE_MOUSE,g_get_monotonic_time()/1000,
                static_cast<WPEModifiers>(0),1,h.a,h.b,kind?1:0);
            wpe_view_focus_in(view);wpe_view_event(view,e);wpe_event_unref(e);break;}
        case 8:destroy(p);pages.erase(h.id);break;
        case 12:webkit_web_view_reload(p->web);break;
        case 13:webkit_web_view_go_back(p->web);break;
        case 14:webkit_web_view_go_forward(p->web);break;
        case 15:webkit_web_view_set_zoom_level(p->web,h.a/1000.0);break;
        default:text(1001,h.id,h.seq,"Unsupported engine operation");return;
        }
    }
    if(h.seq)send(1000,h.id,h.seq);
}
int main(int argc,char**argv) {
    if(argc!=2||strlen(argv[1])>=sizeof(sockaddr_un::sun_path))return 2;
    int listener=socket(AF_UNIX,SOCK_STREAM,0);sockaddr_un addr{};
    addr.sun_family=AF_UNIX;strcpy(addr.sun_path,argv[1]);
    if(listener<0||bind(listener,reinterpret_cast<sockaddr*>(&addr),sizeof addr)||listen(listener,1))return 3;
    connection=accept(listener,nullptr,nullptr);close(listener);unlink(argv[1]);if(connection<0)return 4;
    if(fcntl(connection,F_SETFL,O_NONBLOCK))return 4;
    trace=getenv("DARTER_NYXT_TRACE")!=nullptr;
    WTF::initializeMainThread();darter_register_openssl();
    context=webkit_web_context_new();session=webkit_network_session_new_ephemeral();
    display=WPE_DISPLAY(g_object_new(nyxt_display_get_type(),nullptr));
    GError* error=nullptr;if(!wpe_display_connect(display,&error))return 5;
    std::vector<char> input;send(1000,0);
    while(running){
        // Interleave commands with every GLib turn. Animated UI panels may
        // keep the context continuously ready; draining dozens of turns first
        // makes input and synchronous JavaScript wait behind full-frame copies.
        g_main_context_iteration(nullptr,FALSE);
        // Read only when ready: the shared socket API does not implement
        // per-call MSG_DONTWAIT. Never park GLib's event loop in recv().
        pollfd ready{connection,POLLIN,0};
        if(poll(&ready,1,0)>0){
            char chunk[16384];auto n=wireIO(false,chunk,sizeof chunk);
            if(n==0)break;
            if(n<0&&errno!=EAGAIN&&errno!=EINTR)break;
            if(n>0)input.insert(input.end(),chunk,chunk+n);
        }
        while(input.size()>=sizeof(Header)){
            Header h;memcpy(&h,input.data(),sizeof h);
            if(h.n>limit){running=false;break;}
            if(input.size()<sizeof h+h.n)break;
            std::vector<char> body(input.begin()+sizeof h,input.begin()+sizeof h+h.n);body.push_back(0);
            input.erase(input.begin(),input.begin()+sizeof h+h.n);command(h,body.data());
        }
        usleep(1000);
    }
    for(auto pair:requests){auto e=g_error_new_literal(G_IO_ERROR,G_IO_ERROR_CANCELLED,"Browser closed");
        webkit_uri_scheme_request_finish_error(pair.second,e);g_error_free(e);g_object_unref(pair.second);}
    for(auto pair:pages)destroy(pair.second);
    g_object_unref(session);g_object_unref(context);g_object_unref(display);close(connection);
    puts("NYXT ENGINE EXIT");return 0;
}
