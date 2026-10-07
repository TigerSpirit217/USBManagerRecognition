#include <jni.h>
#include <linux/usb/functionfs.h>
#include <pthread.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

static int ep0 = -1, ep_out = -1, ep_in = -1;
static atomic_long generation_value = 0;
static atomic_int enabled = 0;

static void throw_io(JNIEnv *env, const char *operation) {
    char message[256];
    snprintf(message, sizeof(message), "%s: %s", operation, strerror(errno));
    jclass cls = (*env)->FindClass(env, "java/io/IOException");
    (*env)->ThrowNew(env, cls, message);
}

static int write_array(JNIEnv *env, int fd, jbyteArray bytes) {
    jsize length = (*env)->GetArrayLength(env, bytes);
    jbyte *data = (*env)->GetByteArrayElements(env, bytes, NULL);
    ssize_t written = write(fd, data, (size_t) length);
    (*env)->ReleaseByteArrayElements(env, bytes, data, JNI_ABORT);
    return written == length;
}

static void *read_events(void *unused) {
    (void) unused;
    struct usb_functionfs_event events[4];
    for (;;) {
        ssize_t count = read(ep0, events, sizeof(events));
        if (count < 0) {
            if (errno == EINTR) continue;
            usleep(200000);
            continue;
        }
        for (size_t i = 0; i < (size_t) count / sizeof(events[0]); i++) {
            if (events[i].type == FUNCTIONFS_ENABLE) atomic_store(&enabled, 1);
            if (events[i].type == FUNCTIONFS_DISABLE || events[i].type == FUNCTIONFS_UNBIND) {
                atomic_store(&enabled, 0);
                atomic_fetch_add(&generation_value, 1);
            }
            if (events[i].type == FUNCTIONFS_SETUP) {
                char ignored = 0;
                if (events[i].u.setup.bRequestType & USB_DIR_IN) (void) read(ep0, &ignored, 0);
                else (void) write(ep0, &ignored, 0);
            }
        }
    }
    return NULL;
}

JNIEXPORT void JNICALL
Java_com_tiger_usbmanager_auth_UsbAuthDaemon_nativeOpen(
        JNIEnv *env, jclass type, jstring mount, jbyteArray descriptors, jbyteArray strings) {
    (void) type;
    const char *base = (*env)->GetStringUTFChars(env, mount, NULL);
    char path[256];
    snprintf(path, sizeof(path), "%s/ep0", base);
    ep0 = open(path, O_RDWR | O_CLOEXEC);
    if (ep0 < 0 || !write_array(env, ep0, descriptors) || !write_array(env, ep0, strings)) {
        throw_io(env, "initialize FunctionFS ep0");
        goto done;
    }
    snprintf(path, sizeof(path), "%s/ep1", base);
    ep_out = open(path, O_RDWR | O_CLOEXEC);
    snprintf(path, sizeof(path), "%s/ep2", base);
    ep_in = open(path, O_RDWR | O_CLOEXEC);
    if (ep_out < 0 || ep_in < 0) {
        throw_io(env, "open FunctionFS bulk endpoints");
        goto done;
    }
    pthread_t thread;
    int result = pthread_create(&thread, NULL, read_events, NULL);
    if (result != 0) {
        errno = result;
        throw_io(env, "create FunctionFS event thread");
    } else {
        pthread_detach(thread);
    }
done:
    (*env)->ReleaseStringUTFChars(env, mount, base);
}

JNIEXPORT jlong JNICALL
Java_com_tiger_usbmanager_auth_UsbAuthDaemon_nativeGeneration(JNIEnv *env, jclass type) {
    (void) env; (void) type;
    return atomic_load(&generation_value);
}

JNIEXPORT jbyteArray JNICALL
Java_com_tiger_usbmanager_auth_UsbAuthDaemon_nativeReceive(JNIEnv *env, jclass type) {
    (void) type;
    char buffer[4096];
    size_t position = 0;
    long started = atomic_load(&generation_value);
    if (!atomic_load(&enabled)) {
        errno = EAGAIN;
        throw_io(env, "FunctionFS endpoint not enabled");
        return NULL;
    }
    while (position < sizeof(buffer)) {
        ssize_t count = read(ep_out, buffer + position, sizeof(buffer) - position);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || started != atomic_load(&generation_value)) {
            throw_io(env, "FunctionFS bulk read/disconnect");
            return NULL;
        }
        position += (size_t) count;
    }
    jbyteArray result = (*env)->NewByteArray(env, sizeof(buffer));
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, sizeof(buffer), (jbyte *) buffer);
    return result;
}

JNIEXPORT void JNICALL
Java_com_tiger_usbmanager_auth_UsbAuthDaemon_nativeSend(JNIEnv *env, jclass type, jbyteArray bytes) {
    (void) type;
    if (!write_array(env, ep_in, bytes)) throw_io(env, "FunctionFS bulk write");
}
