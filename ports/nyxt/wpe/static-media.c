/* Upstream GStreamer codecs, using the shared libsa PCM descriptor. */
#include <gst/gst.h>
#include <gst/audio/gstaudiosink.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>

typedef struct {
    GstAudioSink parent;
    GMutex lock;
    int fd;
    unsigned epoch;
} DarterAudioSink;
typedef GstAudioSinkClass DarterAudioSinkClass;
G_DEFINE_TYPE(DarterAudioSink, darter_audio_sink, GST_TYPE_AUDIO_SINK)

static GstStaticPadTemplate pcm_pad = GST_STATIC_PAD_TEMPLATE("sink",
    GST_PAD_SINK, GST_PAD_ALWAYS,
    GST_STATIC_CAPS("audio/x-raw, format=(string)S16LE, layout=(string)interleaved, "
                    "rate=(int)48000, channels=(int)2"));

static gboolean audio_open(GstAudioSink *sink) {
    DarterAudioSink *s = (DarterAudioSink *)sink;
    s->fd = open("/dev/audio", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (s->fd < 0) {
        GST_ELEMENT_ERROR(s, RESOURCE, OPEN_WRITE,
            ("Cannot open Darterfly audio output"), ("errno %d", errno));
        return FALSE;
    }
    return TRUE;
}
static gboolean audio_close(GstAudioSink *sink) {
    DarterAudioSink *s = (DarterAudioSink *)sink;
    g_mutex_lock(&s->lock);
    ++s->epoch;
    if (s->fd >= 0) close(s->fd);
    s->fd = -1;
    g_mutex_unlock(&s->lock);
    return TRUE;
}
static gboolean audio_prepare(GstAudioSink *sink, GstAudioRingBufferSpec *spec) {
    DarterAudioSink *s = (DarterAudioSink *)sink;
    if (GST_AUDIO_INFO_FORMAT(&spec->info) != GST_AUDIO_FORMAT_S16LE ||
        GST_AUDIO_INFO_RATE(&spec->info) != 48000 ||
        GST_AUDIO_INFO_CHANNELS(&spec->info) != 2) return FALSE;
    /* Live sources must schedule ahead of ALL device buffering, including
     * the shared PCM queue and the HDA ring. Under-reporting this latency
     * makes the ringbuffer discard valid live samples as already played. */
    unsigned char status[8];
    if (read(s->fd, status, sizeof status) != sizeof status) return FALSE;
    guint max_frames = status[4] | (status[5]<<8) | (status[6]<<16) |
                       ((guint)status[7]<<24);
    if (!max_frames || max_frames > 48000) return FALSE;
    spec->segsize = 4096;
    spec->segtotal = (max_frames * 4 + spec->segsize - 1) / spec->segsize + 2;
    return TRUE;
}
static gboolean audio_unprepare(GstAudioSink *sink) { (void)sink; return TRUE; }
static void audio_reset(GstAudioSink *sink) {
    DarterAudioSink *s = (DarterAudioSink *)sink;
    g_mutex_lock(&s->lock);
    ++s->epoch;
    if (s->fd >= 0) {
        close(s->fd);
        s->fd = open("/dev/audio", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    }
    g_mutex_unlock(&s->lock);
}
static gint audio_write(GstAudioSink *sink, gpointer data, guint length) {
    DarterAudioSink *s = (DarterAudioSink *)sink;
    g_mutex_lock(&s->lock);
    unsigned epoch = s->epoch;
    for (;;) {
        if (epoch != s->epoch) { g_mutex_unlock(&s->lock); return length; }
        if (s->fd < 0) { g_mutex_unlock(&s->lock); return -1; }
        int n = write(s->fd, data, length);
        int error = errno;
        if (n >= 0) { g_mutex_unlock(&s->lock); return n; }
        if (error != EAGAIN && error != EINTR) {
            g_mutex_unlock(&s->lock);
            GST_ELEMENT_ERROR(s, RESOURCE, WRITE, ("Audio output failed"), ("errno %d", error));
            return -1;
        }
        /* Bound cancellation latency; never hold the sink lock while waiting. */
        struct pollfd p = { s->fd, POLLOUT, 0 };
        g_mutex_unlock(&s->lock);
        poll(&p, 1, 10);
        g_mutex_lock(&s->lock);
    }
}
static guint audio_delay(GstAudioSink *sink) {
    DarterAudioSink *s = (DarterAudioSink *)sink;
    unsigned char data[4];
    guint frames = 0;
    g_mutex_lock(&s->lock);
    if (s->fd >= 0 && read(s->fd, data, sizeof data) == sizeof data)
        frames = data[0] | (data[1]<<8) | (data[2]<<16) | ((guint)data[3]<<24);
    g_mutex_unlock(&s->lock);
    return frames;
}
static void audio_finalize(GObject *object) {
    g_mutex_clear(&((DarterAudioSink *)object)->lock);
    G_OBJECT_CLASS(darter_audio_sink_parent_class)->finalize(object);
}
static void darter_audio_sink_class_init(DarterAudioSinkClass *klass) {
    GObjectClass *object = G_OBJECT_CLASS(klass);
    GstElementClass *element = GST_ELEMENT_CLASS(klass);
    object->finalize = audio_finalize;
    gst_element_class_set_static_metadata(element, "Darterfly audio output",
        "Sink/Audio", "PCM output through Darterfly's shared mixer", "Darterfly");
    gst_element_class_add_static_pad_template(element, &pcm_pad);
    klass->open=audio_open; klass->close=audio_close;
    klass->prepare=audio_prepare; klass->unprepare=audio_unprepare;
    klass->write=audio_write; klass->delay=audio_delay; klass->reset=audio_reset;
}
static void darter_audio_sink_init(DarterAudioSink *s) {
    s->fd=-1; s->epoch=0; g_mutex_init(&s->lock);
}

/* Web Audio asks GstDeviceMonitor for channel capabilities. Advertise the
 * actual native output only when the shared audio service can open it. */
typedef GstDevice DarterAudioDevice;
typedef GstDeviceClass DarterAudioDeviceClass;
G_DEFINE_TYPE(DarterAudioDevice, darter_audio_device, GST_TYPE_DEVICE)
static GstElement *device_element(GstDevice *device, const gchar *name) {
    (void)device;
    return gst_element_factory_make("darteraudiosink", name);
}
static void darter_audio_device_class_init(DarterAudioDeviceClass *klass) {
    klass->create_element = device_element;
}
static void darter_audio_device_init(DarterAudioDevice *device) { (void)device; }

typedef GstDeviceProvider DarterAudioProvider;
typedef GstDeviceProviderClass DarterAudioProviderClass;
G_DEFINE_TYPE(DarterAudioProvider, darter_audio_provider, GST_TYPE_DEVICE_PROVIDER)
static GList *audio_devices(GstDeviceProvider *provider) {
    (void)provider;
    int fd = open("/dev/audio", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return NULL;
    close(fd);
    GstCaps *caps = gst_static_caps_get(&pcm_pad.static_caps);
    GstDevice *device = g_object_new(darter_audio_device_get_type(),
        "display-name", "Darterfly default output", "device-class", "Audio/Sink",
        "caps", caps, NULL);
    gst_caps_unref(caps);
    return g_list_append(NULL, device);
}
static void darter_audio_provider_class_init(DarterAudioProviderClass *klass) {
    klass->probe = audio_devices;
    gst_device_provider_class_set_static_metadata(klass, "Darterfly audio",
        "Audio/Sink", "Shared native audio output", "Darterfly");
}
static void darter_audio_provider_init(DarterAudioProvider *provider) { (void)provider; }

#define PLUGINS(X) \
    X(coreelements) X(app) X(audioconvert) X(audioresample) X(audiotestsrc) \
    X(playback) X(rawparse) X(subparse) X(typefindfunctions) \
    X(videoconvertscale) X(videotestsrc) X(volume) X(ogg) X(opus) X(vorbis) \
    X(autodetect) X(matroska) X(isomp4) X(vpx) X(wavparse) X(audioparsers) \
    X(videoparsersbad) X(opusparse) X(subenc) X(interleave) X(audiofx)
#define DECLARE(name) GST_PLUGIN_STATIC_DECLARE(name);
PLUGINS(DECLARE)
void darter_register_media(void) {
    gst_init(NULL, NULL);
#define REGISTER(name) GST_PLUGIN_STATIC_REGISTER(name);
    PLUGINS(REGISTER)
    gst_element_register(NULL, "darteraudiosink", GST_RANK_PRIMARY + 100,
                         darter_audio_sink_get_type());
    gst_device_provider_register(NULL, "darteraudiodeviceprovider", GST_RANK_PRIMARY,
                                 darter_audio_provider_get_type());
}
