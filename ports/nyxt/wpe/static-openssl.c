/* Upstream supports NULL GTypeModule for statically linked TLS backends. */
#include <gio/gio.h>
extern void g_io_openssl_load(GIOModule *module);
void darter_register_openssl(void)
{
    static gsize initialized;
    if (g_once_init_enter(&initialized)) {
        g_io_openssl_load(NULL);
        g_once_init_leave(&initialized,1);
    }
}
