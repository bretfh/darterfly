/* Qualify the actual upstream GIO library against the shared runtime. */
#include <gio/gio.h>
#include <gio/gunixconnection.h>
#include <arpa/inet.h>
#include <resolv.h>
#include <fnmatch.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>

static void failed(const char *stage, GError *error)
{
    fprintf(stderr, "GIO FAIL %s: %s\n", stage, error ? error->message : "contract mismatch");
}
#define CHECK(test, stage) do { if (!(test)) { failed(stage,error); return 1; } } while (0)
static GMainLoop *loop;
static int async_ok;
static GSocketConnection *async_connection;
static GError *connect_error;
static void connected(GObject *source, GAsyncResult *result, gpointer unused)
{
    (void)unused;
    async_connection=g_socket_client_connect_to_host_finish(G_SOCKET_CLIENT(source),result,&connect_error);
    g_main_loop_quit(loop);
}
static void resolved(GObject *source, GAsyncResult *result, gpointer unused)
{
    GError *error = NULL;
    GList *addresses = g_resolver_lookup_by_name_finish(G_RESOLVER(source), result, &error);
    (void)unused;
    async_ok = addresses != NULL && error == NULL;
    if (!async_ok) failed("async DNS", error);
    g_clear_error(&error);
    g_resolver_free_addresses(addresses);
    g_main_loop_quit(loop);
}
int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "--child")) {
        if (argc != 4 || fcntl(atoi(argv[2]), F_GETFD) != -1 || errno != EBADF)
            return 3;
        char first;
        if (read(atoi(argv[3]), &first, 1) != 1 || first != 'd') return 4;
        char line[80];
        if (!fgets(line,sizeof line,stdin)) return 2;
        printf("child:%s",line);
        fprintf(stderr,"child-stderr\n");
        return 0;
    }
    GError *error = NULL;
    puts("GIO upstream 2.86.0 native world");
    unsigned char address[16]; char text[80];
    CHECK(inet_pton(AF_INET6,"2001:db8::1234",address)==1,"inet6 parse");
    CHECK(inet_ntop(AF_INET6,address,text,sizeof text) && !strcmp(text,"2001:db8::1234"),"inet6 format");
    CHECK(inet_pton(AF_INET6,"::ffff:192.0.2.1",address)==1,"inet6 mapped");
    CHECK(inet_ntop(AF_INET6,address,text,sizeof text) && !strcmp(text,"::ffff:192.0.2.1"),"inet6 mapped format");
    CHECK(inet_pton(AF_INET,"256.1.2.3",address)==0,"invalid IPv4");
    CHECK(inet_pton(AF_INET6,"1::2::3",address)==0,"invalid IPv6");
    CHECK(fnmatch("*.c","probe.c",0)==0 && fnmatch("[a-z][[:digit:]]?","a7x",0)==0 &&
          fnmatch("*",".hidden",FNM_PERIOD)==FNM_NOMATCH,"filename glob");
    unsigned char packet[]={3,'w','w','w',7,'e','x','a','m','p','l','e',3,'c','o','m',0,0xc0,0};
    CHECK(dn_expand(packet,packet+sizeof packet,packet+17,text,sizeof text)==2 &&
          !strcmp(text,"www.example.com"),"compressed DNS name");
    unsigned char bad[]={0xc0,0};
    CHECK(dn_expand(bad,bad+2,bad,text,sizeof text)==-1,"DNS pointer cycle");
    CHECK(dn_expand(packet,packet+sizeof packet,packet,text,4)==-1,"DNS small buffer");
    GInetAddress *ip=g_inet_address_new_from_string("::1");
    CHECK(ip && g_inet_address_get_is_loopback(ip),"GInetAddress");
    g_object_unref(ip);
    int listener=socket(AF_INET,SOCK_STREAM,0), accepting=-1;
    socklen_t option_size=sizeof accepting;
    CHECK(listener>=0 && getsockopt(listener,SOL_SOCKET,SO_ACCEPTCONN,&accepting,&option_size)==0 && accepting==0,"new socket is not listening");
    struct sockaddr_in bind_address={0};
    bind_address.sin_family=AF_INET; bind_address.sin_port=htons(19001);
    CHECK(bind(listener,(struct sockaddr *)&bind_address,sizeof bind_address)==0 && listen(listener,2)==0,"native TCP listen");
    CHECK(getsockopt(listener,SOL_SOCKET,SO_ACCEPTCONN,&accepting,&option_size)==0 && accepting==1,"listening socket option");
    close(listener);
    puts("GIO address and resolver primitives PASS");

    GFile *file=g_file_new_for_path("/tmp/gio-document.txt");
    CHECK(g_file_replace_contents(file,"darterfly gio\n",13,NULL,FALSE,
                                 G_FILE_CREATE_NONE,NULL,NULL,&error),"replace file");
    char *contents=NULL; gsize length=0;
    CHECK(g_file_load_contents(file,NULL,&contents,&length,NULL,&error) &&
          length==13 && !memcmp(contents,"darterfly gio\n",13),"load file");
    g_free(contents);
    GFileInfo *info=g_file_query_info(file,"standard::size",G_FILE_QUERY_INFO_NONE,NULL,&error);
    CHECK(info && g_file_info_get_size(info)==13,"file metadata");
    g_object_unref(info); g_object_unref(file);
    puts("GIO file streams PASS");

    int inherited=open("/tmp/gio-document.txt",O_RDONLY);
    CHECK(inherited>=3,"parent descriptor");
    struct flock unsupported_lock={0};
    unsupported_lock.l_type=F_WRLCK;
    CHECK(fcntl(inherited,F_SETLK,&unsupported_lock)==-1 && errno==EINVAL,
          "unsupported record lock must fail");
    char inherited_text[24]; snprintf(inherited_text,sizeof inherited_text,"%d",inherited);
    GSubprocessLauncher *launcher=g_subprocess_launcher_new(
        G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE |
        G_SUBPROCESS_FLAGS_STDERR_PIPE);
    g_subprocess_launcher_take_fd(launcher,dup(inherited),17);
    GSubprocess *child=g_subprocess_launcher_spawn(launcher,&error,
        argv[0],"--child",inherited_text,"17",NULL);
    g_object_unref(launcher);
    CHECK(child,"spawn");
    char *out=NULL,*err=NULL;
    CHECK(g_subprocess_communicate_utf8(child,"hello\n",NULL,&out,&err,&error),"communicate");
    CHECK(g_subprocess_get_successful(child) && !strcmp(out,"child:hello\n") &&
          !strcmp(err,"child-stderr\n"),"child status and pipes");
    g_free(out);g_free(err);g_object_unref(child);
    CHECK(fcntl(inherited,F_GETFD)>=0,"parent descriptor preserved");
    close(inherited);
    puts("GIO subprocess communication PASS");

    GResolver *resolver=g_resolver_get_default();
    GList *addresses=g_resolver_lookup_by_name(resolver,"example.com",NULL,&error);
    CHECK(addresses,"DNS A/AAAA");
    g_resolver_free_addresses(addresses);
    GList *records=g_resolver_lookup_records(resolver,"example.com",G_RESOLVER_RECORD_NS,NULL,&error);
    CHECK(records,"DNS NS records");
    g_list_free_full(records,(GDestroyNotify)g_variant_unref);
    loop=g_main_loop_new(NULL,FALSE);
    g_resolver_lookup_by_name_async(resolver,"example.com",NULL,resolved,NULL);
    g_main_loop_run(loop);
    CHECK(async_ok,"async resolver");
    g_main_loop_unref(loop);g_object_unref(resolver);
    puts("GIO DNS records and asynchronous lookup PASS");

    GSocketClient *client=g_socket_client_new();
    g_socket_client_set_enable_proxy(client,FALSE);
    g_socket_client_set_timeout(client,10);
    loop=g_main_loop_new(NULL,FALSE);
    g_socket_client_connect_to_host_async(client,"10.0.2.2",18765,NULL,connected,NULL);
    g_main_loop_run(loop);
    GSocketConnection *connection=async_connection;
    if (connect_error) error=connect_error;
    CHECK(connection,"asynchronous TCP connect");
    g_main_loop_unref(loop);
    const char *request="GET / HTTP/1.0\r\nHost: darterfly-test\r\n\r\n";
    GOutputStream *output=g_io_stream_get_output_stream(G_IO_STREAM(connection));
    CHECK(g_output_stream_write_all(output,request,strlen(request),NULL,NULL,&error),"HTTP write");
    GInputStream *input=g_io_stream_get_input_stream(G_IO_STREAM(connection));
    char response[2048]; gsize used=0;
    for (;;) {
        gssize n=g_input_stream_read(input,response+used,sizeof response-1-used,NULL,&error);
        CHECK(n>=0,"HTTP read");
        if (!n) break;
        used+=(gsize)n;
        CHECK(used<sizeof response-1,"HTTP response size");
    }
    response[used]=0;
    CHECK(strstr(response,"200 OK") && strstr(response,"DARTERFLY-GIO-HTTP"),"HTTP response");
    g_io_stream_close(G_IO_STREAM(connection),NULL,NULL);
    g_object_unref(connection);g_object_unref(client);
    puts("GIO PASS files subprocess pipes DNS async TCP HTTP");
    return 0;
}
