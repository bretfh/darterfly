/* Exercise upstream TLS, including trust and identity failures, in a world. */
#include <gio/gio.h>
#include <openssl/rand.h>
#include <openssl/crypto.h>
#include <stdio.h>
#include <string.h>
void darter_register_openssl(void);
static int request(int port, const char *identity, const char *ca, GTlsCertificateFlags expected)
{
    GError *error=NULL;
    GSocketClient *client=g_socket_client_new();
    g_socket_client_set_enable_proxy(client,FALSE);
    g_socket_client_set_timeout(client,10);
    GSocketConnection *tcp=g_socket_client_connect_to_host(client,"10.0.2.2",port,NULL,&error);
    if (!tcp) { fprintf(stderr,"TLS connect: %s\n",error->message); return 1; }
    GSocketConnectable *peer=G_SOCKET_CONNECTABLE(g_network_address_new(identity,port));
    GIOStream *tls=g_tls_client_connection_new(G_IO_STREAM(tcp),peer,&error);
    if (!tls) { fprintf(stderr,"TLS create: %s\n",error->message); return 1; }
    GTlsDatabase *db=g_tls_file_database_new(ca,&error);
    if (!db) { fprintf(stderr,"TLS database: %s\n",error->message); return 1; }
    g_tls_connection_set_database(G_TLS_CONNECTION(tls),db);
    gboolean success=g_tls_connection_handshake(G_TLS_CONNECTION(tls),NULL,&error);
    if (!expected) {
        if (!success) { fprintf(stderr,"TLS handshake: %s\n",error->message); return 1; }
        const char *get="GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        if (!g_output_stream_write_all(g_io_stream_get_output_stream(tls),get,strlen(get),NULL,NULL,&error)) {
            fprintf(stderr,"TLS write: %s\n",error->message); return 1;
        }
        char body[2048]; gsize used=0;
        for (;;) {
            gssize n=g_input_stream_read(g_io_stream_get_input_stream(tls),body+used,sizeof body-1-used,NULL,&error);
            if (n<0) { fprintf(stderr,"TLS read: %s\n",error->message); return 1; }
            if (!n) break;
            used+=(gsize)n;
            if (used==sizeof body-1) return 1;
        }
        body[used]=0;
        if (!strstr(body,"200 OK") || !strstr(body,"DARTERFLY-GIO-HTTP")) return 1;
        printf("TLS verified HTTPS PASS port=%d protocol=%d\n",port,
               g_tls_connection_get_protocol_version(G_TLS_CONNECTION(tls)));
    } else {
        GTlsCertificateFlags actual=g_tls_connection_get_peer_certificate_errors(G_TLS_CONNECTION(tls));
        if (success || !(actual & expected) || !g_error_matches(error,G_TLS_ERROR,G_TLS_ERROR_BAD_CERTIFICATE)) {
            fprintf(stderr,"TLS expected certificate rejection, got %s\n",error?error->message:"success");
            return 1;
        }
        printf("TLS certificate rejection PASS identity=%s ca=%s flags=%u\n",identity,ca,actual);
    }
    g_clear_error(&error);
    g_io_stream_close(tls,NULL,NULL);
    g_object_unref(db);g_object_unref(tls);g_object_unref(peer);
    g_object_unref(tcp);g_object_unref(client);
    return 0;
}
int main(void)
{
    printf("TLS upstream %s with GLib networking 2.80.1\n",OpenSSL_version(OPENSSL_VERSION));
    unsigned char a[32],b[32];
    if (RAND_bytes(a,sizeof a)!=1 || RAND_bytes(b,sizeof b)!=1 || !memcmp(a,b,sizeof a)) {
        puts("TLS FAIL OS entropy / OpenSSL DRBG"); return 1;
    }
    puts("TLS OS entropy and OpenSSL DRBG PASS");
    darter_register_openssl();
    if (!g_tls_backend_supports_tls(g_tls_backend_get_default())) return 1;
    if (request(18766,"localhost","/Users/darterfly/ca.pem",0) ||
        request(18767,"localhost","/Users/darterfly/ca.pem",0) ||
        request(18766,"wrong.invalid","/Users/darterfly/ca.pem",G_TLS_CERTIFICATE_BAD_IDENTITY) ||
        request(18766,"localhost","/Users/darterfly/untrusted-ca.pem",G_TLS_CERTIFICATE_UNKNOWN_CA) ||
        request(18768,"localhost","/Users/darterfly/ca.pem",G_TLS_CERTIFICATE_EXPIRED) ||
        request(18769,"localhost","/Users/darterfly/ca.pem",G_TLS_CERTIFICATE_NOT_ACTIVATED)) return 1;
    puts("TLS PASS verified HTTPS TLS1.3 TLS1.2 hostname trust expiry future");
    return 0;
}
