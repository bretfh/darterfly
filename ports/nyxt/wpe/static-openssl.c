/* Upstream supports NULL GTypeModule for statically linked TLS backends. */
#include <gio/gio.h>
extern void g_io_openssl_load(GIOModule *module);
void darter_register_openssl(void)
{
    static gsize initialized;
    if (g_once_init_enter(&initialized)) {
        /* SoupSession class initialization references this type while holding
         * GLib's class-init lock. A concurrent D-Bus worker can own the type's
         * once guard and wait for that lock while adding its interface.
         * Register it before WPE starts workers, using the upstream GIO API. */
        g_type_ensure(G_TYPE_INET_SOCKET_ADDRESS);
        g_io_openssl_load(NULL);
        g_once_init_leave(&initialized,1);
    }
}
