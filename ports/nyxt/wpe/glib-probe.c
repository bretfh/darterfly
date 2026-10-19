/* Executes upstream GLib/GObject; no replacement GLib implementation. */
#include <glib.h>
#include <glib-object.h>
#include <glib-unix.h>
#include <unistd.h>
#include <sys/wait.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "GLIB FAIL %d: %s\n", __LINE__, #x); return 1; } } while (0)
static GMutex mutex;
static GCond condition;
static gboolean ready;
static gpointer worker(gpointer p)
{
    (void)p;
    g_usleep(20000);
    g_mutex_lock(&mutex);
    ready = TRUE;
    g_cond_signal(&condition);
    g_mutex_unlock(&mutex);
    return NULL;
}
static void notified(GObject *object, gchar *text, gpointer p)
{
    (void)object;
    if (!strcmp(text, "native")) ++*(int *)p;
}
static GMainLoop *loop;
static int child_ok, pipe_ok, expired;
static void child_done(GPid pid, gint status, gpointer p)
{
    (void)p;
    child_ok = WIFEXITED(status) && WEXITSTATUS(status) == 7;
    g_spawn_close_pid(pid);
    if (pipe_ok) g_main_loop_quit(loop);
}
static gboolean pipe_ready(gint fd, GIOCondition events, gpointer p)
{
    (void)p;
    char c;
    pipe_ok = (events & G_IO_IN) && read(fd, &c, 1) == 1 && c == 'W';
    if (child_ok) g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}
static gboolean timeout(gpointer p)
{
    (void)p;
    expired = 1;
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}
int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "child")) {
        g_usleep(100000);
        return 7;
    }
    printf("GLIB upstream %u.%u.%u native world\n",
           glib_major_version, glib_minor_version, glib_micro_version);
    puts("GLIB stage memory");
    CHECK(memmem("ab\0cd", 5, "\0c", 2) != NULL);
    CHECK(memmem("ab", 2, "abc", 3) == NULL);
    char temporary[] = "/tmp/glib-XXXXXX";
    int tempfd = mkostemp(temporary, O_CLOEXEC);
    CHECK(tempfd >= 0 && (fcntl(tempfd, F_GETFD) & FD_CLOEXEC));
    close(tempfd); unlink(temporary);
    puts("GLIB stage directory");
    GError *error = NULL;
    GDir *directory = g_dir_open("/Users/darterfly", 0, &error);
    CHECK(directory && !error);
    char *first = g_strdup(g_dir_read_name(directory));
    CHECK(first);
    g_dir_rewind(directory);
    CHECK(!strcmp(first, g_dir_read_name(directory)));
    g_free(first); g_dir_close(directory);
    puts("GLIB stage unicode");
    gchar *normal = g_utf8_normalize("e\314\201", -1, G_NORMALIZE_NFC);
    CHECK(normal && !strcmp(normal, "\303\251"));
    g_free(normal);
    puts("GLIB stage regex");
    GRegex *regex = g_regex_new("^darter[[:alpha:]]+$", 0, 0, &error);
    CHECK(regex && !error && g_regex_match(regex, "darterfly", 0, NULL));
    g_regex_unref(regex);
    puts("GLIB stage variant");
    GVariant *value = g_variant_ref_sink(g_variant_new("(si)", "world", 42));
    const gchar *name;
    gint number;
    g_variant_get(value, "(&si)", &name, &number);
    CHECK(!strcmp(name, "world") && number == 42);
    g_variant_unref(value);
    puts("GLIB stage rwlock");
    GRWLock rw = {0};
    CHECK(g_rw_lock_reader_trylock(&rw));
    CHECK(!g_rw_lock_writer_trylock(&rw));
    g_rw_lock_reader_unlock(&rw);
    CHECK(g_rw_lock_writer_trylock(&rw));
    CHECK(!g_rw_lock_reader_trylock(&rw));
    g_rw_lock_writer_unlock(&rw);
    g_rw_lock_clear(&rw);
    puts("GLIB stage threads");
    g_mutex_init(&mutex);
    g_cond_init(&condition);
    GThread *thread = g_thread_new("glib-worker", worker, NULL);
    g_mutex_lock(&mutex);
    gint64 deadline = g_get_monotonic_time() + 2000000;
    while (!ready && g_cond_wait_until(&condition, &mutex, deadline)) {}
    g_mutex_unlock(&mutex);
    CHECK(ready);
    g_thread_join(thread);
    g_cond_clear(&condition);
    g_mutex_clear(&mutex);
    puts("GLIB stage gobject");
    int count = 0;
    guint sig = g_signal_new("darter-probe", G_TYPE_OBJECT, G_SIGNAL_RUN_LAST,
                            0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_STRING);
    GObject *object = g_object_new(G_TYPE_OBJECT, NULL);
    g_signal_connect(object, "darter-probe", G_CALLBACK(notified), &count);
    g_signal_emit(object, sig, 0, "native");
    CHECK(count == 1);
    g_object_unref(object);
    puts("GLIB stage event-loop");
    loop = g_main_loop_new(NULL, FALSE);
    int fds[2];
    CHECK(pipe(fds) == 0);
    g_unix_fd_add(fds[0], G_IO_IN, pipe_ready, NULL);
    CHECK(write(fds[1], "W", 1) == 1);
    GPid child;
    gchar *args[] = {argv[0], "child", NULL};
    puts("GLIB stage spawn");
    CHECK(g_spawn_async(NULL, args, NULL,
                        G_SPAWN_DO_NOT_REAP_CHILD |
                        G_SPAWN_LEAVE_DESCRIPTORS_OPEN |
                        G_SPAWN_CHILD_INHERITS_STDIN,
                        NULL, NULL, &child, &error));
    puts("GLIB stage childwatch");
    g_child_watch_add(child, child_done, NULL);
    guint timer = g_timeout_add(5000, timeout, NULL);
    puts("GLIB stage dispatch");
    g_main_loop_run(loop);
    if (!expired) g_source_remove(timer);
    CHECK(!expired && child_ok && pipe_ok);
    close(fds[0]); close(fds[1]);
    g_main_loop_unref(loop);
    puts("GLIB PASS unicode regex variant threads rwlock gobject poll spawn childwatch");
    return 0;
}
