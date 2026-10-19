/* Upstream WPE networking libraries exercised inside an isolated world. */
#include <libsoup/soup.h>
#include <stdio.h>
#include <string.h>
void darter_register_openssl(void);
static GMainLoop *loop;
static GBytes *received;
static GError *async_error;
static void finished(GObject *session,GAsyncResult *result,gpointer unused)
{
    (void)unused;
    received=soup_session_send_and_read_finish(SOUP_SESSION(session),result,&async_error);
    g_main_loop_quit(loop);
}
static SoupSession *session(const char *ca)
{
    GError *error=NULL;
    GTlsDatabase *db=g_tls_file_database_new(ca,&error);
    if (!db) { fprintf(stderr,"SOUP database: %s\n",error->message); return NULL; }
    GProxyResolver *direct=G_PROXY_RESOLVER(g_simple_proxy_resolver_new(NULL,NULL));
    SoupSession *s=soup_session_new_with_options("tls-database",db,"proxy-resolver",direct,
                                               "timeout",15,"user-agent","Darterfly qualification",NULL);
    g_object_unref(db); g_object_unref(direct);
    return s;
}
static int request(SoupSession *s,const char *url,const char *want,
                   GTlsCertificateFlags rejected,gboolean async,const char *post)
{
    SoupMessage *message=soup_message_new(post?"POST":"GET",url);
    GError *error=NULL;
    if (post) {
        GBytes *body=g_bytes_new(post,strlen(post));
        soup_message_set_request_body_from_bytes(message,"text/plain",body);
        g_bytes_unref(body);
    }
    GBytes *bytes;
    if (async) {
        received=NULL; async_error=NULL;
        loop=g_main_loop_new(NULL,FALSE);
        soup_session_send_and_read_async(s,message,G_PRIORITY_DEFAULT,NULL,finished,NULL);
        g_main_loop_run(loop);
        g_main_loop_unref(loop);
        bytes=received; error=async_error;
    } else bytes=soup_session_send_and_read(s,message,NULL,&error);
    if (rejected) {
        GTlsCertificateFlags flags=soup_message_get_tls_peer_certificate_errors(message);
        if (bytes || !g_error_matches(error,G_TLS_ERROR,G_TLS_ERROR_BAD_CERTIFICATE) || !(flags&rejected)) {
            fprintf(stderr,"SOUP expected rejection %s: flags=%u error=%s\n",url,flags,error?error->message:"none");
            return 1;
        }
        printf("SOUP certificate rejection PASS %s flags=%u\n",url,flags);
        g_clear_error(&error);
    } else {
        if (!bytes || soup_message_get_status(message)!=200) {
            fprintf(stderr,"SOUP request %s status=%u: %s\n",url,soup_message_get_status(message),error?error->message:"none");
            return 1;
        }
        gsize size; const char *data=g_bytes_get_data(bytes,&size);
        if (!g_strstr_len(data,size,want)) { fprintf(stderr,"SOUP body mismatch %s size=%lu\n",url,(unsigned long)size); return 1; }
        if (g_str_has_prefix(url,"https:") && (!soup_message_get_tls_peer_certificate(message) ||
            soup_message_get_tls_peer_certificate_errors(message))) return 1;
        printf("SOUP HTTP PASS %s bytes=%lu async=%d http-version=%d\n",url,(unsigned long)size,async,soup_message_get_http_version(message));
        g_bytes_unref(bytes);
    }
    g_object_unref(message);
    return 0;
}
int main(void)
{
    printf("SOUP upstream %u.%u.%u native world\n",soup_get_major_version(),soup_get_minor_version(),soup_get_micro_version());
    darter_register_openssl();
    SoupSession *s=session("/Users/darterfly/ca.pem");
    if (!s) return 1;
    SoupCookieJar *jar=soup_cookie_jar_new();
    soup_session_add_feature(s,SOUP_SESSION_FEATURE(jar)); g_object_unref(jar);
    if (!soup_tld_domain_is_public_suffix("co.uk")) return 1;
    GError *error=NULL;
    const char *base=soup_tld_get_base_domain("sub.example.co.uk",&error);
    if (!base || strcmp(base,"example.co.uk")) return 1;
    puts("SOUP public suffix and ICU domain handling PASS");
    if (request(s,"http://10.0.2.2:18765/","DARTERFLY-GIO-HTTP",0,FALSE,NULL) ||
        request(s,"https://10.0.2.2:18766/redirect","COOKIE-PASS",0,TRUE,NULL) ||
        request(s,"https://10.0.2.2:18767/gzip","DARTERFLY-GZIP",0,TRUE,NULL) ||
        request(s,"https://10.0.2.2:18766/chunked","DARTERFLY",0,FALSE,NULL) ||
        request(s,"https://10.0.2.2:18766/post","hello from a native world",0,TRUE,"hello from a native world") ||
        request(s,"https://10.0.2.2:18768/",NULL,G_TLS_CERTIFICATE_EXPIRED,TRUE,NULL) ||
        request(s,"https://10.0.2.2:18769/",NULL,G_TLS_CERTIFICATE_NOT_ACTIVATED,FALSE,NULL)) return 1;
    g_object_unref(s);
    s=session("/Users/darterfly/untrusted-ca.pem");
    if (!s || request(s,"https://10.0.2.2:18766/",NULL,G_TLS_CERTIFICATE_UNKNOWN_CA,TRUE,NULL)) return 1;
    g_object_unref(s);
    puts("SOUP controlled HTTP HTTPS redirects cookies gzip chunked POST validation PASS");
    s=session("/Users/darterfly/public-ca.pem");
    if (!s || request(s,"https://example.com/","Example Domain",0,TRUE,NULL)) return 1;
    g_object_unref(s);
    puts("SOUP PASS native HTTPS public web validated certificates async HTTP");
    return 0;
}
